import AppKit
import SwiftUI

/// Manages a floating popup window for meeting detection notifications.
/// Shows in the top-right corner, similar to Granola's notification style.
@MainActor
final class MeetingPopupWindowController {
    static let shared = MeetingPopupWindowController()

    private var window: NSWindow?
    private var hostingView: NSHostingView<AnyView>?

    private init() {}

    /// Show the meeting detected popup.
    /// The popup auto-dismisses after 7 seconds.
    func showMeetingDetected(
        appName: String,
        meetingTitle: String,
        onStartRecording: @escaping () -> Void) {
        // Dismiss any existing popup first
        self.dismiss()

        // Create the popup content
        let popupView = MeetingDetectedPopup(
            appName: appName,
            meetingTitle: meetingTitle,
            onStartRecording: onStartRecording,
            onDismiss: { [weak self] in
                self?.dismiss()
            })

        // Create the window
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 80),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating
        window.hasShadow = false
        window.isMovableByWindowBackground = false
        window.ignoresMouseEvents = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]

        // Create hosting view
        let hostingView = NSHostingView(rootView: AnyView(popupView))
        window.contentView = hostingView

        // Position in top-right corner
        self.positionWindow(window)

        // Show the window
        window.orderFront(nil)

        self.window = window
        self.hostingView = hostingView
    }

    private func positionWindow(_ window: NSWindow) {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let windowSize = window.frame.size

        // Position in top-right corner with padding
        let x = screenFrame.maxX - windowSize.width - 20
        let y = screenFrame.maxY - windowSize.height - 20

        window.setFrameOrigin(NSPoint(x: x, y: y))
    }

    func dismiss() {
        self.window?.orderOut(nil)
        self.window = nil
        self.hostingView = nil
    }
}
