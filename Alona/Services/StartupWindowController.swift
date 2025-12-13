import AppKit
import SwiftUI

enum WindowFocusController {
    static func identifier(for windowID: String) -> String {
        switch windowID {
        case "settings-window":
            // Keep this stable without double "-window" suffix.
            return "settings-window"
        default:
            return "\(windowID)-window"
        }
    }

    static func focusOrOpen(windowID: String, openWindow: OpenWindowAction) {
        let identifier = identifier(for: windowID)
        if let window = existingWindow(in: NSApp.windows, identifier: identifier) {
            focus(window)
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

enum StartupWindowController {
    static let identifier = WindowFocusController.identifier(for: "startup")

    static func focusOrOpen(openWindow: OpenWindowAction) {
        WindowFocusController.focusOrOpen(windowID: "startup", openWindow: openWindow)
    }

    static func existingWindow(in windows: [NSWindow]) -> NSWindow? {
        WindowFocusController.existingWindow(in: windows, identifier: identifier)
    }
}

struct WindowIdentifierSetter: NSViewRepresentable {
    let identifier: String

    func makeNSView(context _: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            updateIdentifier(for: view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context _: Context) {
        DispatchQueue.main.async {
            updateIdentifier(for: nsView)
        }
    }

    private func updateIdentifier(for view: NSView) {
        guard let window = view.window else { return }
        if window.identifier?.rawValue != identifier {
            window.identifier = NSUserInterfaceItemIdentifier(identifier)
        }
    }
}

struct StartupWindowIdentifierSetter: View {
    var body: some View {
        WindowIdentifierSetter(identifier: StartupWindowController.identifier)
    }
}
