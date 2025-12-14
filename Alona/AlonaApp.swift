import SwiftUI

@main
struct AlonaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()
    @StateObject private var permissionManager = PermissionManager()
    @StateObject private var meetingDetector: MeetingDetector
    // Use a State binding to ensure menu bar extra is always visible
    // (Previously @AppStorage could cause the binding to become false unexpectedly)
    @State private var showMenuBarExtra = true
    private let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    init() {
        let detector = MeetingDetector()
        _meetingDetector = StateObject(wrappedValue: detector)
        if !isRunningTests {
            detector.startMonitoring()
        }
    }

    var body: some Scene {
        // Primary window - opens automatically on launch
        WindowGroup {
            StartupView()
                .environmentObject(appState)
                .environmentObject(permissionManager)
                .environmentObject(meetingDetector)
        }
        .windowResizability(.contentSize)
        .commands {
            // Disable Cmd+N creating new windows
            CommandGroup(replacing: .newItem) {}
        }

        // Menu bar extra with isInserted binding allows coexistence with WindowGroup
        MenuBarExtra("Alona", systemImage: "note.text", isInserted: $showMenuBarExtra) {
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
