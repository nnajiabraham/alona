import SwiftUI

@main
struct AlonaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appState: AppState
    @State private var permissionManager: PermissionManager
    @State private var meetingDetector: MeetingDetector
    // Use a State binding to ensure menu bar extra is always visible
    // (Previously @AppStorage could cause the binding to become false unexpectedly)
    // During tests, hide menu bar extra to avoid UI issues on CI
    @State private var showMenuBarExtra: Bool

    init() {
        let isTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

        // Disable notification observer during tests to prevent test notifications
        // from triggering real recordings in the production directory
        _appState = State(initialValue: AppState(observeNotifications: !isTest))

        // Skip permission manager initialization during tests (avoids AppleScript/TCC calls)
        _permissionManager = State(initialValue: isTest ? PermissionManager(skipRefresh: true) : PermissionManager())

        // Hide menu bar extra during tests
        _showMenuBarExtra = State(initialValue: !isTest)

        let detector = MeetingDetector()
        _meetingDetector = State(initialValue: detector)
        if !isTest {
            detector.startMonitoring()
        }
    }

    var body: some Scene {
        // Primary window - opens automatically on launch
        WindowGroup {
            StartupView()
                .environment(self.appState)
                .environment(self.permissionManager)
                .environment(self.meetingDetector)
        }
        .windowResizability(.contentSize)
        .commands {
            // Disable Cmd+N creating new windows
            CommandGroup(replacing: .newItem) {}
        }

        // Menu bar extra with isInserted binding allows coexistence with WindowGroup
        // During tests, isInserted=false prevents menu bar from showing
        MenuBarExtra("Alona", systemImage: "note.text", isInserted: self.$showMenuBarExtra) {
            MenuBarView()
                .environment(self.appState)
                .environment(self.permissionManager)
                .environment(self.meetingDetector)
        }
        .menuBarExtraStyle(.window)
        .defaultSize(width: 360, height: 320)

        WindowGroup(id: "onboarding") {
            OnboardingView()
                .environment(self.permissionManager)
        }
        .windowResizability(.contentSize)

        WindowGroup(id: "meeting-notes") {
            MeetingNotesView()
                .environment(self.appState)
        }
        .defaultSize(width: 420, height: 380)

        WindowGroup(id: "recordings") {
            RecordingsBrowserView()
                .environment(self.appState)
        }
        .defaultSize(width: 700, height: 420)

        WindowGroup(id: "settings-window") {
            SettingsView()
                .environment(self.permissionManager)
                .environment(self.appState)
        }
        .defaultSize(width: 480, height: 360)

        WindowGroup(id: "transcription-queue") {
            TranscriptionQueueView()
                .environment(self.appState)
        }
        .defaultSize(width: 480, height: 420)
    }
}
