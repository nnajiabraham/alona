import Combine
import Foundation
import Observation

@Observable
@MainActor
final class AppState {
    private(set) var isRecording: Bool = false
    private(set) var recordingDuration: TimeInterval = 0
    var meetingTitle: String = AppState.idleMeetingTitle
    var showOnboarding: Bool = true
    var saveDirectory: URL
    var dismissedDetectionIdentifier: String?
    var recordingError: String?
    var notesDraft: String = "" {
        didSet {
            self.scheduleNotesAutosave()
        }
    }

    var notesWindowRequestID: UUID?
    var transcriptionState: TranscriptionState = .idle
    private(set) var transcriptionJobs: [TranscriptionJob] = []
    var captureSystemAudio: Bool = false {
        didSet {
            self.audioRecorder.captureSystemAudio = self.captureSystemAudio
            self.userDefaults.set(self.captureSystemAudio, forKey: Self.captureSystemAudioDefaultsKey)
        }
    }

    private(set) var meetingFileManager: MeetingFileManager
    private let audioRecorder: AudioRecordingController
    private let transcriptionEngine: TranscriptionProcessing
    private let summaryProvider: SummaryProviding
    // Keep Combine subscriptions for external publishers (from NSObject classes)
    @ObservationIgnored private var cancellables: Set<AnyCancellable> = []
    private(set) var currentMeetingDirectory: URL?
    // Notes autosave uses Task-based debouncing instead of Combine
    @ObservationIgnored private var notesAutosaveTask: Task<Void, Never>?
    @ObservationIgnored private var transcriptionProgressCancellable: AnyCancellable?
    @ObservationIgnored private var notificationActionCancellable: AnyCancellable?
    private let notesAutosaveInterval: TimeInterval
    @ObservationIgnored private let notesAutosaveScheduler: DispatchQueue
    private let nowProvider: () -> Date
    @ObservationIgnored private let userDefaults: UserDefaults
    @ObservationIgnored private var activeJobTask: Task<Void, Never>?
    @ObservationIgnored private var activeJobID: UUID?
    @ObservationIgnored private var activeUIJobID: UUID?
    @ObservationIgnored private var lastSavedNotesDraft: String = ""

    init(
        meetingFileManager manager: MeetingFileManager = MeetingFileManager(),
        audioRecorder: AudioRecordingController? = nil,
        transcriptionEngine: TranscriptionProcessing? = nil,
        summaryProvider: SummaryProviding? = nil,
        notesAutosaveInterval: TimeInterval = 2.0,
        notesAutosaveScheduler: DispatchQueue = .main,
        userDefaults: UserDefaults = .standard,
        nowProvider: @escaping () -> Date = Date.init) {
        self.meetingFileManager = manager
        let recorder = audioRecorder ?? AudioRecorder(meetingFileManager: manager)
        self.audioRecorder = recorder
        let transcriptionEngine = transcriptionEngine ?? TranscriptionEngine()
        self.transcriptionEngine = transcriptionEngine
        self.summaryProvider = summaryProvider ?? SummaryManager()
        self.notesAutosaveInterval = notesAutosaveInterval
        self.notesAutosaveScheduler = notesAutosaveScheduler
        self.saveDirectory = manager.baseDirectory
        self.userDefaults = userDefaults
        self.nowProvider = nowProvider

        let storedCapture = userDefaults.object(forKey: Self.captureSystemAudioDefaultsKey) as? Bool ?? false
        self.captureSystemAudio = storedCapture
        recorder.captureSystemAudio = storedCapture

        // Subscribe to external Combine publishers (from NSObject classes that can't use @Observable)
        recorder.isRecordingPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                self?.isRecording = value
            }
            .store(in: &self.cancellables)

        recorder.recordingDurationPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                self?.recordingDuration = value
            }
            .store(in: &self.cancellables)

        self.transcriptionProgressCancellable = transcriptionEngine.progressPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                self?.handleTranscriptionProgress(value)
            }

        // Notes autosave is now handled via didSet + Task-based debouncing (see scheduleNotesAutosave)

        self.notificationActionCancellable = NotificationCenter.default
            .publisher(for: .meetingNotificationStartRecording)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                guard let self, !self.isRecording else { return }
                let title = notification.userInfo?["meetingTitle"] as? String
                Task {
                    await self.startRecording(meetingTitleOverride: title)
                }
            }
    }

    func updateSaveDirectory(_ url: URL) {
        self.meetingFileManager.baseDirectory = url
        self.saveDirectory = url
    }

    func startRecording(meetingTitleOverride: String? = nil) async {
        let title = resolveRecordingTitle(from: meetingTitleOverride ?? self.meetingTitle)
        do {
            let directory = try await audioRecorder.startRecording(meetingTitle: title)
            self.currentMeetingDirectory = directory
            if let draft = meetingFileManager.recoverNotesFromTemp(in: directory) {
                self.notesDraft = draft
            } else {
                self.notesDraft = ""
            }
            self.meetingTitle = title
            persistActiveMeetingTitle()
            self.recordingError = nil
            self.transcriptionState = .idle
            self.notesWindowRequestID = UUID()
        } catch {
            self.recordingError = error.localizedDescription
        }
    }

    func stopRecording() async {
        guard let directory = currentMeetingDirectory else {
            await self.audioRecorder.stopRecording()
            return
        }

        await self.audioRecorder.stopRecording()

        do {
            try self.meetingFileManager.saveNotes(self.notesDraft, to: directory)
        } catch {
            self.recordingError = error.localizedDescription
        }

        let notesCopy = self.notesDraft
        self.notesDraft = ""
        enqueueTranscription(for: directory, notes: notesCopy, source: .automatic, showProgressInMainUI: true)
        self.currentMeetingDirectory = nil
    }

    func updateActiveMeetingTitle(_ title: String) {
        self.meetingTitle = title
        persistActiveMeetingTitle()
    }

    func dismissDetection(identifier: String) {
        self.dismissedDetectionIdentifier = identifier
    }

    func resetDetectionDismissalIfNeeded(for identifier: String) {
        if identifier.isEmpty {
            self.dismissedDetectionIdentifier = nil
        } else if self.dismissedDetectionIdentifier == identifier {
            return
        } else {
            self.dismissedDetectionIdentifier = nil
        }
    }

    func regenerateTranscription(for directory: URL, notes: String) {
        enqueueTranscription(for: directory, notes: notes, source: .manual, showProgressInMainUI: false)
    }

    func isJobActive(for directory: URL) -> Bool {
        self.transcriptionJobs.contains { job in
            job.directory == directory && job.state.isBusy
        }
    }

    func cancelTranscriptionJob(_ job: TranscriptionJob) {
        if self.activeJobID == job.id {
            self.activeJobTask?.cancel()
        } else {
            updateJob(job.id) { current in
                current.state = .cancelled
            }
            processQueue()
        }
    }

    private static let captureSystemAudioDefaultsKey = "AppState.captureSystemAudio"
    private static let idleMeetingTitle = "No meeting detected"
    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d, yyyy 'at' h:mm a"
        return formatter
    }()

    /// Task-based debounced autosave for notes (replaces Combine $notesDraft.debounce)
    private func scheduleNotesAutosave() {
        // Skip if content hasn't actually changed (removeDuplicates equivalent)
        guard self.notesDraft != self.lastSavedNotesDraft else { return }

        // Cancel any pending autosave
        self.notesAutosaveTask?.cancel()

        let interval = self.notesAutosaveInterval
        let textToSave = self.notesDraft

        self.notesAutosaveTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(interval))
                guard let self, !Task.isCancelled else { return }
                self.autosaveNotesDraft(textToSave)
                self.lastSavedNotesDraft = textToSave
            } catch {
                // Task was cancelled - that's fine
            }
        }
    }
}

extension AppState {
    private func resolveRecordingTitle(from override: String?) -> String {
        let trimmed = override?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty, trimmed != Self.idleMeetingTitle {
            return trimmed
        }
        return Self.timestampFormatter.string(from: self.nowProvider())
    }

    private func autosaveNotesDraft(_ text: String) {
        guard let directory = currentMeetingDirectory else { return }
        do {
            try self.meetingFileManager.saveNotesDraft(text, to: directory)
        } catch {
            self.recordingError = error.localizedDescription
        }
    }

    private func enqueueTranscription(
        for directory: URL,
        notes: String?,
        source: TranscriptionJob.Source,
        showProgressInMainUI: Bool) {
        let title = self.meetingFileManager.loadTitle(from: directory) ?? directory.lastPathComponent
        let noteValue = notes ?? self.meetingFileManager.loadNotes(from: directory) ?? ""
        let job = TranscriptionJob(
            id: UUID(),
            directory: directory,
            title: title,
            notes: noteValue,
            requestedAt: Date(),
            state: .pending,
            source: source,
            showProgressInMainUI: showProgressInMainUI)
        self.transcriptionJobs.append(job)
        self.processQueue()
    }

    private func processQueue() {
        guard self.activeJobTask == nil else { return }
        guard let index = transcriptionJobs.firstIndex(where: { $0.state == .pending }) else {
            // No more pending jobs - unload model to free memory
            self.transcriptionEngine.unloadModelIfIdle()
            return
        }
        var job = self.transcriptionJobs[index]
        job.state = .preparing
        self.transcriptionJobs[index] = job

        self.activeJobID = job.id
        if job.showProgressInMainUI {
            self.activeUIJobID = job.id
            self.transcriptionState = .preparing
        }

        self.activeJobTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.runPostProcessing(
                    for: job.directory,
                    notes: job.notes,
                    jobID: job.id,
                    showInMainUI: job.showProgressInMainUI)
                await MainActor.run {
                    self.updateJob(job.id) { current in
                        current.state = .completed(Date())
                    }
                    if self.activeUIJobID == job.id {
                        self.transcriptionState = .completed
                        self.activeUIJobID = nil
                    }
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.updateJob(job.id) { current in
                        current.state = .cancelled
                    }
                    if self.activeUIJobID == job.id {
                        self.transcriptionState = .idle
                        self.activeUIJobID = nil
                    }
                }
            } catch {
                let message = error.localizedDescription
                await MainActor.run {
                    self.updateJob(job.id) { current in
                        current.state = .failed(message)
                    }
                    if self.activeUIJobID == job.id {
                        self.transcriptionState = .failed(message)
                        self.activeUIJobID = nil
                    }
                }
            }

            await MainActor.run {
                self.activeJobTask = nil
                self.activeJobID = nil
                self.processQueue()
            }
        }
    }

    private func updateJob(_ id: UUID, mutate: (inout TranscriptionJob) -> Void) {
        guard let idx = transcriptionJobs.firstIndex(where: { $0.id == id }) else { return }
        var job = self.transcriptionJobs[idx]
        mutate(&job)
        self.transcriptionJobs[idx] = job
    }

    private func handleTranscriptionProgress(_ value: Double) {
        if let jobID = activeJobID {
            self.updateJob(jobID) { current in
                if case .summarizing = current.state {
                    return
                }
                current.state = .processing(value)
            }
        }

        guard self.activeUIJobID != nil else { return }
        if case .summarizing = self.transcriptionState { return }
        self.transcriptionState = .processing(value)
    }

    private func runPostProcessing(for directory: URL, notes: String, jobID: UUID?, showInMainUI: Bool) async throws {
        let monoURL = directory.appendingPathComponent("recording-mono.wav")
        try Task.checkCancellation()
        do {
            let transcription = try await transcriptionEngine.transcribe(audioURL: monoURL)
            try Task.checkCancellation()
            try self.meetingFileManager.saveTranscript(transcription, to: directory)
            if let jobID {
                self.updateJob(jobID) { current in
                    current.state = .summarizing
                }
            }
            if showInMainUI {
                self.transcriptionState = .summarizing
            }
            let summary = try await summaryProvider.generateSummary(transcript: transcription.text, notes: notes)
            try Task.checkCancellation()
            try self.meetingFileManager.saveSummary(summary, to: directory)
        } catch let cancellationError as CancellationError {
            throw cancellationError
        } catch {
            let message = error.localizedDescription
            self.recordingError = message
            throw error
        }
    }

    private func persistActiveMeetingTitle() {
        guard let directory = currentMeetingDirectory else { return }
        do {
            try self.meetingFileManager.saveTitle(self.meetingTitle, to: directory)
        } catch {
            self.recordingError = error.localizedDescription
        }
    }
}

enum TranscriptionState: Equatable {
    case idle
    case preparing
    case processing(Double)
    case summarizing
    case completed
    case failed(String)
}

struct TranscriptionJob: Identifiable, Equatable {
    enum Source {
        case automatic
        case manual
    }

    enum State: Equatable {
        case pending
        case preparing
        case processing(Double)
        case summarizing
        case completed(Date)
        case failed(String)
        case cancelled

        var isBusy: Bool {
            switch self {
            case .pending, .preparing, .processing, .summarizing:
                true
            case .completed, .failed, .cancelled:
                false
            }
        }
    }

    let id: UUID
    let directory: URL
    var title: String
    var notes: String
    let requestedAt: Date
    var state: State
    let source: Source
    let showProgressInMainUI: Bool
}
