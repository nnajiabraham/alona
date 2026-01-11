import AppKit
import SwiftUI

// Custom entry point that skips SwiftUI App initialization during tests
// SwiftUI apps hang on CI runners without a proper window server session
// By using a custom main, we can run a minimal AppKit app for tests

let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

if isRunningTests {
    // Minimal AppKit app for hosted tests - no SwiftUI, no windows
    print("🧪 main.swift: Running in test mode - using minimal AppKit app")

    // Create a minimal application
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    // Set up a minimal delegate that does nothing
    class MinimalAppDelegate: NSObject, NSApplicationDelegate {
        func applicationDidFinishLaunching(_: Notification) {
            print("🧪 MinimalAppDelegate: App launched for tests")
        }

        func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
            false
        }
    }

    let delegate = MinimalAppDelegate()
    app.delegate = delegate

    print("🧪 main.swift: Starting minimal run loop for tests")
    // Run the app - XCTest will inject tests and drive execution
    app.run()
} else {
    // Normal SwiftUI app launch
    print("🚀 main.swift: Running normal SwiftUI app")
    AlonaApp.main()
}
