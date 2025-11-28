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

    private(set) var meetingFileManager: MeetingFileManager
    private let audioRecorder: AudioRecordingController
    private var cancellables: Set<AnyCancellable> = []
    private(set) var currentMeetingDirectory: URL?
    private var notesAutosaveCancellable: AnyCancellable?
    private let notesAutosaveInterval: TimeInterval
    private let notesAutosaveScheduler: DispatchQueue

    init(meetingFileManager manager: MeetingFileManager = MeetingFileManager(),
         audioRecorder: AudioRecordingController? = nil,
         notesAutosaveInterval: TimeInterval = 2.0,
         notesAutosaveScheduler: DispatchQueue = .main)
    {
        meetingFileManager = manager
        let recorder = audioRecorder ?? AudioRecorder(meetingFileManager: manager)
        self.audioRecorder = recorder
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

        notesAutosaveCancellable = $notesDraft
            .removeDuplicates()
            .debounce(for: .seconds(notesAutosaveInterval), scheduler: notesAutosaveScheduler)
            .sink { [weak self] text in
                self?.autosaveNotesDraft(text)
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
            recordingError = nil
            notesWindowRequestID = UUID()
        } catch {
            recordingError = error.localizedDescription
        }
    }

    func stopRecording() async {
        await audioRecorder.stopRecording()
        if let directory = currentMeetingDirectory {
            do {
                try meetingFileManager.saveNotes(notesDraft, to: directory)
            } catch {
                recordingError = error.localizedDescription
            }
        }
        currentMeetingDirectory = nil
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
}
