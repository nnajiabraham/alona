import AppKit
import SwiftUI

// Custom entry point that skips SwiftUI App initialization during tests
// SwiftUI apps hang on CI runners without a proper window server session
// By using a custom main, we can run a minimal AppKit app for tests

let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

if isRunningTests {
    // For hosted tests, XCTest injects the test bundle and runs tests
    // We just need to set up NSApplication minimally and let XCTest drive
    print("🧪 main.swift: Test mode - minimal AppKit setup")

    let app = NSApplication.shared
    app.setActivationPolicy(.accessory) // No dock icon, no menu bar

    class TestAppDelegate: NSObject, NSApplicationDelegate {
        func applicationDidFinishLaunching(_: Notification) {
            print("🧪 TestAppDelegate: Launched, XCTest will inject tests")
            // Post notification that app is ready - XCTest waits for this
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: NSApplication.didFinishLaunchingNotification, object: NSApp)
            }
        }

        func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
            false
        }
    }

    let delegate = TestAppDelegate()
    app.delegate = delegate

    // Use NSApplicationMain for proper XCTest integration
    // This allows XCTest to inject the test bundle
    _ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
} else {
    // Normal SwiftUI app launch
    AlonaApp.main()
}
