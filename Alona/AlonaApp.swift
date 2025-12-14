import SwiftUI

@main
struct AlonaApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var permissionManager = PermissionManager()
    @StateObject private var meetingDetector: MeetingDetector

    init() {
        let detector = MeetingDetector()
        detector.startMonitoring()
        _meetingDetector = StateObject(wrappedValue: detector)
    }

    var body: some Scene {
        WindowGroup(id: "startup") {
            StartupView()
                .environmentObject(appState)
                .environmentObject(permissionManager)
        }
        .windowResizability(.contentSize)

        MenuBarExtra("Alona", systemImage: "note.text") {
            MenuBarView()
                .environmentObject(appState)
                .environmentObject(permissionManager)
                .environmentObject(meetingDetector)
        }
        .menuBarExtraStyle(.window)
        .defaultSize(width: 360, height: 320)

        WindowGroup(id: "onboarding") {
            OnboardingView()
                .environmentObject(permissionManager)
        }
        .windowResizability(.contentSize)

        WindowGroup(id: "meeting-notes") {
            MeetingNotesView()
                .environmentObject(appState)
        }
        .defaultSize(width: 420, height: 380)

        WindowGroup(id: "recordings") {
            RecordingsBrowserView()
                .environmentObject(appState)
        }
        .defaultSize(width: 700, height: 420)

        WindowGroup(id: "settings-window") {
            SettingsView()
                .environmentObject(permissionManager)
                .environmentObject(appState)
        }
        .defaultSize(width: 480, height: 360)

        WindowGroup(id: "transcription-queue") {
            TranscriptionQueueView()
                .environmentObject(appState)
        }
        .defaultSize(width: 480, height: 420)
    }
}
