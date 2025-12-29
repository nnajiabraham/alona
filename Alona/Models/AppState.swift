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
            scheduleNotesAutosave()
        }
    }

    var notesWindowRequestID: UUID?
    var transcriptionState: TranscriptionState = .idle
    private(set) var transcriptionJobs: [TranscriptionJob] = []
    var captureSystemAudio: Bool = false {
        didSet {
            audioRecorder.captureSystemAudio = captureSystemAudio
            userDefaults.set(captureSystemAudio, forKey: Self.captureSystemAudioDefaultsKey)
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

    init(meetingFileManager manager: MeetingFileManager = MeetingFileManager(),
         audioRecorder: AudioRecordingController? = nil,
         transcriptionEngine: TranscriptionProcessing? = nil,
         summaryProvider: SummaryProviding? = nil,
         notesAutosaveInterval: TimeInterval = 2.0,
         notesAutosaveScheduler: DispatchQueue = .main,
         userDefaults: UserDefaults = .standard,
         nowProvider: @escaping () -> Date = Date.init)
    {
        meetingFileManager = manager
        let recorder = audioRecorder ?? AudioRecorder(meetingFileManager: manager)
        self.audioRecorder = recorder
        let transcriptionEngine = transcriptionEngine ?? TranscriptionEngine()
        self.transcriptionEngine = transcriptionEngine
        self.summaryProvider = summaryProvider ?? SummaryManager()
        self.notesAutosaveInterval = notesAutosaveInterval
        self.notesAutosaveScheduler = notesAutosaveScheduler
        saveDirectory = manager.baseDirectory
        self.userDefaults = userDefaults
        self.nowProvider = nowProvider

        let storedCapture = userDefaults.object(forKey: Self.captureSystemAudioDefaultsKey) as? Bool ?? false
        captureSystemAudio = storedCapture
        recorder.captureSystemAudio = storedCapture

        // Subscribe to external Combine publishers (from NSObject classes that can't use @Observable)
        recorder.isRecordingPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                self?.isRecording = value
            }
            .store(in: &cancellables)

        recorder.recordingDurationPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                self?.recordingDuration = value
            }
            .store(in: &cancellables)

        transcriptionProgressCancellable = transcriptionEngine.progressPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                self?.handleTranscriptionProgress(value)
            }

        // Notes autosave is now handled via didSet + Task-based debouncing (see scheduleNotesAutosave)

        notificationActionCancellable = NotificationCenter.default.publisher(for: .meetingNotificationStartRecording)
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
        meetingFileManager.baseDirectory = url
        saveDirectory = url
    }

    func startRecording(meetingTitleOverride: String? = nil) async {
        let title = resolveRecordingTitle(from: meetingTitleOverride ?? meetingTitle)
        do {
            let directory = try await audioRecorder.startRecording(meetingTitle: title)
            currentMeetingDirectory = directory
            if let draft = meetingFileManager.recoverNotesFromTemp(in: directory) {
                notesDraft = draft
            } else {
                notesDraft = ""
            }
            meetingTitle = title
            persistActiveMeetingTitle()
            recordingError = nil
            transcriptionState = .idle
            notesWindowRequestID = UUID()
        } catch {
            recordingError = error.localizedDescription
        }
    }

    func stopRecording() async {
        guard let directory = currentMeetingDirectory else {
            await audioRecorder.stopRecording()
            return
        }

        await audioRecorder.stopRecording()

        do {
            try meetingFileManager.saveNotes(notesDraft, to: directory)
        } catch {
            recordingError = error.localizedDescription
        }

        let notesCopy = notesDraft
        notesDraft = ""
        enqueueTranscription(for: directory, notes: notesCopy, source: .automatic, showProgressInMainUI: true)
        currentMeetingDirectory = nil
    }

    func updateActiveMeetingTitle(_ title: String) {
        meetingTitle = title
        persistActiveMeetingTitle()
    }

    func dismissDetection(identifier: String) {
        dismissedDetectionIdentifier = identifier
    }

    func resetDetectionDismissalIfNeeded(for identifier: String) {
        if identifier.isEmpty {
            dismissedDetectionIdentifier = nil
        } else if dismissedDetectionIdentifier == identifier {
            return
        } else {
            dismissedDetectionIdentifier = nil
        }
    }

    func regenerateTranscription(for directory: URL, notes: String) {
        enqueueTranscription(for: directory, notes: notes, source: .manual, showProgressInMainUI: false)
    }

    func isJobActive(for directory: URL) -> Bool {
        transcriptionJobs.contains { job in
            job.directory == directory && job.state.isBusy
        }
    }

    func cancelTranscriptionJob(_ job: TranscriptionJob) {
        if activeJobID == job.id {
            activeJobTask?.cancel()
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
        guard notesDraft != lastSavedNotesDraft else { return }

        // Cancel any pending autosave
        notesAutosaveTask?.cancel()

        let interval = notesAutosaveInterval
        let textToSave = notesDraft

        notesAutosaveTask = Task { [weak self] in
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

private extension AppState {
    func resolveRecordingTitle(from override: String?) -> String {
        let trimmed = override?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty, trimmed != Self.idleMeetingTitle {
            return trimmed
        }
        return Self.timestampFormatter.string(from: nowProvider())
    }

    func autosaveNotesDraft(_ text: String) {
        guard let directory = currentMeetingDirectory else { return }
        do {
            try meetingFileManager.saveNotesDraft(text, to: directory)
        } catch {
            recordingError = error.localizedDescription
        }
    }

    func enqueueTranscription(for directory: URL, notes: String?, source: TranscriptionJob.Source, showProgressInMainUI: Bool) {
        let title = meetingFileManager.loadTitle(from: directory) ?? directory.lastPathComponent
        let noteValue = notes ?? meetingFileManager.loadNotes(from: directory) ?? ""
        let job = TranscriptionJob(
            id: UUID(),
            directory: directory,
            title: title,
            notes: noteValue,
            requestedAt: Date(),
            state: .pending,
            source: source,
            showProgressInMainUI: showProgressInMainUI
        )
        transcriptionJobs.append(job)
        processQueue()
    }

    func processQueue() {
        guard activeJobTask == nil else { return }
        guard let index = transcriptionJobs.firstIndex(where: { $0.state == .pending }) else {
            // No more pending jobs - unload model to free memory
            transcriptionEngine.unloadModelIfIdle()
            return
        }
        var job = transcriptionJobs[index]
        job.state = .preparing
        transcriptionJobs[index] = job

        activeJobID = job.id
        if job.showProgressInMainUI {
            activeUIJobID = job.id
            transcriptionState = .preparing
        }

        activeJobTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.runPostProcessing(for: job.directory, notes: job.notes, jobID: job.id, showInMainUI: job.showProgressInMainUI)
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

    func updateJob(_ id: UUID, mutate: (inout TranscriptionJob) -> Void) {
        guard let idx = transcriptionJobs.firstIndex(where: { $0.id == id }) else { return }
        var job = transcriptionJobs[idx]
        mutate(&job)
        transcriptionJobs[idx] = job
    }

    func handleTranscriptionProgress(_ value: Double) {
        if let jobID = activeJobID {
            updateJob(jobID) { current in
                if case .summarizing = current.state {
                    return
                }
                current.state = .processing(value)
            }
        }

        guard activeUIJobID != nil else { return }
        if case .summarizing = transcriptionState { return }
        transcriptionState = .processing(value)
    }

    func runPostProcessing(for directory: URL, notes: String, jobID: UUID?, showInMainUI: Bool) async throws {
        let monoURL = directory.appendingPathComponent("recording-mono.wav")
        try Task.checkCancellation()
        do {
            let transcription = try await transcriptionEngine.transcribe(audioURL: monoURL)
            try Task.checkCancellation()
            try meetingFileManager.saveTranscript(transcription, to: directory)
            if let jobID {
                updateJob(jobID) { current in
                    current.state = .summarizing
                }
            }
            if showInMainUI {
                transcriptionState = .summarizing
            }
            let summary = try await summaryProvider.generateSummary(transcript: transcription.text, notes: notes)
            try Task.checkCancellation()
            try meetingFileManager.saveSummary(summary, to: directory)
        } catch let cancellationError as CancellationError {
            throw cancellationError
        } catch {
            let message = error.localizedDescription
            recordingError = message
            throw error
        }
    }

    func persistActiveMeetingTitle() {
        guard let directory = currentMeetingDirectory else { return }
        do {
            try meetingFileManager.saveTitle(meetingTitle, to: directory)
        } catch {
            recordingError = error.localizedDescription
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
                return true
            case .completed, .failed, .cancelled:
                return false
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
