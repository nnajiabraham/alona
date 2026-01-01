import AppKit
import Foundation
import XCTest
@testable import Alona

// MARK: - Window Controller Tests

@MainActor
final class WindowControllerTests: XCTestCase {
    func testStartupWindowControllerFindsExistingWindow() {
        let other = NSWindow()
        other.identifier = NSUserInterfaceItemIdentifier("other")
        let target = NSWindow()
        target.identifier = NSUserInterfaceItemIdentifier(StartupWindowController.identifier)

        let found = StartupWindowController.existingWindow(in: [other, target])
        XCTAssertTrue(found === target)
    }

    func testWindowFocusControllerFindsRecordingsWindow() {
        let other = NSWindow()
        other.identifier = NSUserInterfaceItemIdentifier("other")
        let recordings = NSWindow()
        recordings.identifier = NSUserInterfaceItemIdentifier(WindowFocusController.identifier(for: "recordings"))

        let found = WindowFocusController.existingWindow(
            in: [other, recordings],
            identifier: WindowFocusController
                .identifier(for: "recordings"))
        XCTAssertTrue(found === recordings)
    }
}
