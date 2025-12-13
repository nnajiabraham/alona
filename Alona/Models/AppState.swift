import Combine
import Foundation

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var isRecording: Bool = false
    @Published private(set) var recordingDuration: TimeInterval = 0
    @Published var meetingTitle: String = "No meeting detected"
    @Published var showOnboarding: Bool = true
    @Published var saveDirectory: URL
    @Published var dismissedDetectionIdentifier: String?
    @Published var recordingError: String?
    @Published var notesDraft: String = ""
    @Published var notesWindowRequestID: UUID?
    @Published var transcriptionState: TranscriptionState = .idle
    @Published private(set) var transcriptionJobs: [TranscriptionJob] = []

    private(set) var meetingFileManager: MeetingFileManager
    private let audioRecorder: AudioRecordingController
    private let transcriptionEngine: TranscriptionProcessing
    private let summaryProvider: SummaryProviding
    private var cancellables: Set<AnyCancellable> = []
    @Published private(set) var currentMeetingDirectory: URL?
    private var notesAutosaveCancellable: AnyCancellable?
    private var transcriptionProgressCancellable: AnyCancellable?
    private var notificationActionCancellable: AnyCancellable?
    private let notesAutosaveInterval: TimeInterval
    private let notesAutosaveScheduler: DispatchQueue
    private var activeJobTask: Task<Void, Never>?
    private var activeJobID: UUID?
    private var activeUIJobID: UUID?

    init(meetingFileManager manager: MeetingFileManager = MeetingFileManager(),
         audioRecorder: AudioRecordingController? = nil,
         transcriptionEngine: TranscriptionProcessing? = nil,
         summaryProvider: SummaryProviding? = nil,
         notesAutosaveInterval: TimeInterval = 2.0,
         notesAutosaveScheduler: DispatchQueue = .main)
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

        recorder.isRecordingPublisher
            .receive(on: RunLoop.main)
            .assign(to: \.isRecording, onWeak: self)
            .store(in: &cancellables)

        recorder.recordingDurationPublisher
            .receive(on: RunLoop.main)
            .assign(to: \.recordingDuration, onWeak: self)
            .store(in: &cancellables)

        transcriptionProgressCancellable = transcriptionEngine.progressPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                self?.handleTranscriptionProgress(value)
            }

        notesAutosaveCancellable = $notesDraft
            .removeDuplicates()
            .debounce(for: .seconds(notesAutosaveInterval), scheduler: notesAutosaveScheduler)
            .sink { [weak self] text in
                self?.autosaveNotesDraft(text)
            }

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
        let title = meetingTitleOverride?.isEmpty == false ? meetingTitleOverride! : meetingTitle
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
}

private extension Publisher where Failure == Never {
    func assign<T: AnyObject>(to keyPath: ReferenceWritableKeyPath<T, Output>, onWeak object: T?) -> AnyCancellable {
        sink { [weak object] value in
            object?[keyPath: keyPath] = value
        }
    }
}

private extension AppState {
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
        guard let index = transcriptionJobs.firstIndex(where: { $0.state == .pending }) else { return }
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
