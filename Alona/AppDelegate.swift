import AppKit
import OSLog

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Alona", category: "AppDelegate")

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    func applicationWillFinishLaunching(_: Notification) {
        // This is called BEFORE SwiftUI body is evaluated
        if self.isRunningTests {
            logger.info("🧪 AppDelegate: Test mode detected in applicationWillFinishLaunching")
            print("🧪 AppDelegate: Test mode detected in applicationWillFinishLaunching")
            // Set activation policy as early as possible
            NSApp.setActivationPolicy(.accessory)
            // Prevent automatic window creation
            NSApp.windows.forEach { $0.close() }
        }
    }

    func applicationDidFinishLaunching(_: Notification) {
        logger.info("📱 AppDelegate: applicationDidFinishLaunching called")
        print("📱 AppDelegate: applicationDidFinishLaunching called, isTests=\(self.isRunningTests)")

        if self.isRunningTests {
            logger.info("🧪 AppDelegate: Test mode - suppressing UI")
            print("🧪 AppDelegate: Test mode - suppressing UI")
            // Ensure activation policy is accessory
            NSApp.setActivationPolicy(.accessory)
            // Close any windows that SwiftUI might have created
            for window in NSApp.windows {
                print("🧪 AppDelegate: Closing window: \(window.title)")
                window.orderOut(nil)
            }
        } else {
            // Check and prompt for Accessibility permission on startup
            // This is critical for Zoom meeting detection
            self.checkAccessibilityPermissionOnStartup()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        // Keep app running (menu bar extra lives on)
        false
    }

    // MARK: - Permission Checks

    /// Check Accessibility permission on startup and prompt if not granted.
    /// This is critical for Zoom meeting detection via AppleScript.
    private func checkAccessibilityPermissionOnStartup() {
        let isTrusted = AXIsProcessTrusted()
        logger.info("📱 Accessibility permission check: \(isTrusted ? "granted" : "not granted")")

        if !isTrusted {
            // Prompt the user to grant Accessibility permission
            // This will show the system dialog asking to add the app to Accessibility
            // Use literal string to avoid Swift 6 concurrency warning with global constant
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)

            logger.info("📱 Prompted user for Accessibility permission")
        }
    }
}
