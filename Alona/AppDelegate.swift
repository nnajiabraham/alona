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
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        // Keep app running (menu bar extra lives on)
        false
    }
}
