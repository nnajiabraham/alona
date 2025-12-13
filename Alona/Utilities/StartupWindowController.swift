import AppKit
import SwiftUI

enum StartupWindowController {
    static let identifier = "startup-window"

    static func focusOrOpen(openWindow: OpenWindowAction) {
        if let window = existingWindow(in: NSApp.windows) {
            focus(window)
        } else {
            openWindow(id: "startup")
        }
    }

    static func existingWindow(in windows: [NSWindow]) -> NSWindow? {
        windows.first { $0.identifier?.rawValue == identifier }
    }

    private static func focus(_ window: NSWindow) {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct StartupWindowIdentifierSetter: NSViewRepresentable {
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
        if window.identifier?.rawValue != StartupWindowController.identifier {
            window.identifier = NSUserInterfaceItemIdentifier(StartupWindowController.identifier)
        }
    }
}
