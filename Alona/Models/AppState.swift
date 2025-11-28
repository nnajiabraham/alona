import Combine
import Foundation

@MainActor
final class AppState: ObservableObject {
    @Published var isRecording: Bool = false
    @Published var meetingTitle: String = "No meeting detected"
    @Published var showOnboarding: Bool = true
    @Published var saveDirectory: URL = MeetingFileManager.defaultBaseDirectory

    func toggleRecording() {
        isRecording.toggle()
    }
}
