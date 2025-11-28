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

    private(set) var meetingFileManager: MeetingFileManager
    private(set) var audioRecorder: AudioRecorder
    private var cancellables: Set<AnyCancellable> = []
    private(set) var currentMeetingDirectory: URL?

    init(meetingFileManager manager: MeetingFileManager = MeetingFileManager(),
         audioRecorder: AudioRecorder? = nil)
    {
        meetingFileManager = manager
        let recorder = audioRecorder ?? AudioRecorder(meetingFileManager: manager)
        self.audioRecorder = recorder
        saveDirectory = manager.baseDirectory

        recorder.$isRecording
            .receive(on: RunLoop.main)
            .assign(to: \.isRecording, onWeak: self)
            .store(in: &cancellables)

        recorder.$recordingDuration
            .receive(on: RunLoop.main)
            .assign(to: \.recordingDuration, onWeak: self)
            .store(in: &cancellables)
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
            meetingTitle = title
            recordingError = nil
        } catch {
            recordingError = error.localizedDescription
        }
    }

    func stopRecording() async {
        await audioRecorder.stopRecording()
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
