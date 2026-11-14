import AppKit
import SwiftUI

@MainActor
enum WindowFocusController {
    static func identifier(for windowID: String) -> String {
        switch windowID {
        case "settings-window":
            // Keep this stable without double "-window" suffix.
            "settings-window"
        default:
            "\(windowID)-window"
        }
    }

    static func focusOrOpen(windowID: String, openWindow: OpenWindowAction) {
        let identifier = identifier(for: windowID)
        if let window = existingWindow(in: NSApp.windows, identifier: identifier) {
            self.focus(window)
            return
        }
        openWindow(id: windowID)
    }

    static func existingWindow(in windows: [NSWindow], identifier: String) -> NSWindow? {
        windows.first { $0.identifier?.rawValue == identifier }
    }

    private static func focus(_ window: NSWindow) {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor
enum StartupWindowController {
    static let identifier = "startup-window"

    /// Focus the startup window if it exists, otherwise activate the app (SwiftUI will restore the main window).
    static func focusOrOpen(openWindow _: OpenWindowAction) {
        if let window = existingWindow(in: NSApp.windows) {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        // For default WindowGroup (no ID), just activate the app - SwiftUI handles the rest
        NSApp.activate(ignoringOtherApps: true)
    }

    static func existingWindow(in windows: [NSWindow]) -> NSWindow? {
        windows.first { $0.identifier?.rawValue == self.identifier }
    }
}

struct WindowIdentifierSetter: NSViewRepresentable {
    let identifier: String

    func makeNSView(context _: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            self.updateIdentifier(for: view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context _: Context) {
        DispatchQueue.main.async {
            self.updateIdentifier(for: nsView)
        }
    }

    private func updateIdentifier(for view: NSView) {
        guard let window = view.window else { return }
        if window.identifier?.rawValue != self.identifier {
            window.identifier = NSUserInterfaceItemIdentifier(self.identifier)
        }
    }
}

struct StartupWindowIdentifierSetter: View {
    var body: some View {
        WindowIdentifierSetter(identifier: StartupWindowController.identifier)
            .frame(width: 0, height: 0)
    }
}
