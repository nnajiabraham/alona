import Combine
import Foundation

@MainActor
final class AppState: ObservableObject {
    @Published var isRecording: Bool = false
    @Published var meetingTitle: String = "No meeting detected"
    @Published var showOnboarding: Bool = true
    @Published var saveDirectory: URL
    @Published var dismissedDetectionIdentifier: String?

    private(set) var meetingFileManager: MeetingFileManager

    init(meetingFileManager manager: MeetingFileManager = MeetingFileManager()) {
        meetingFileManager = manager
        saveDirectory = manager.baseDirectory
    }

    func toggleRecording() {
        isRecording.toggle()
    }

    func updateSaveDirectory(_ url: URL) {
        meetingFileManager.baseDirectory = url
        saveDirectory = url
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
