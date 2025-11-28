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
        MenuBarExtra {
            MenuBarView()
                .environmentObject(appState)
                .environmentObject(permissionManager)
                .environmentObject(meetingDetector)
        } label: {
            Label("Alona", systemImage: appState.isRecording ? "record.circle.fill" : "record.circle")
                .labelStyle(.titleAndIcon)
        }
        .menuBarExtraStyle(.window)
        .defaultSize(width: 360, height: 320)

        Settings {
            SettingsView()
                .environmentObject(permissionManager)
                .environmentObject(appState)
        }

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
    }
}
