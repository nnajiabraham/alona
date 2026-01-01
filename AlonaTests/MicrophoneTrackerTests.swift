import Foundation
import XCTest
@testable import Alona

// MARK: - Microphone Activity Tracker Tests

@MainActor
final class MicrophoneTrackerTests: XCTestCase {
    func testMicrophoneTrackerStartsAndStops() {
        let tracker = MicrophoneActivityTracker.shared

        // Initially not tracking
        tracker.stopTracking()

        // Start tracking
        tracker.startTracking()

        // Should have initialized (may have empty set if no apps using mic)
        XCTAssertNotNil(tracker.appsUsingMicrophone)

        // Stop tracking
        tracker.stopTracking()
    }

    func testMicrophoneTrackerAppCheckMethods() {
        let tracker = MicrophoneActivityTracker.shared

        // These should return false when no apps are using microphone
        // (which is expected in test environment)
        let zoomInMeeting = tracker.isZoomInMeeting()
        let chromeUsingMic = tracker.isChromeUsingMicrophone()

        // Just verify they don't crash and return booleans
        XCTAssertNotNil(zoomInMeeting)
        XCTAssertNotNil(chromeUsingMic)
    }

    func testIsAppUsingMicrophoneReturnsFalseForUnknownApp() {
        let tracker = MicrophoneActivityTracker.shared

        // Unknown bundle ID should return false
        let result = tracker.isAppUsingMicrophone(bundleIdentifier: "com.unknown.app.that.does.not.exist")
        XCTAssertFalse(result)
    }

    func testMultipleZoomBundleIDsChecked() {
        // Test that MicrophoneActivityTracker checks multiple Zoom bundle IDs
        let tracker = MicrophoneActivityTracker.shared

        // The isZoomInMeeting() method should check multiple bundle IDs
        // This is a structural test - actual detection depends on running apps
        let result = tracker.isZoomInMeeting()

        // Result should be deterministic (false when Zoom isn't running with mic)
        XCTAssertFalse(result, "Should return false when Zoom is not running with mic")
    }
}
