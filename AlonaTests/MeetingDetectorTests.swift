import Foundation
import XCTest
@testable import Alona

@MainActor
final class MeetingDetectorTests: XCTestCase {
    func testPermissionStatusDisplayNames() {
        XCTAssertEqual(PermissionManager.PermissionStatus.granted.displayName, "Granted")
        XCTAssertEqual(PermissionManager.PermissionStatus.denied.displayName, "Denied")
        XCTAssertEqual(PermissionManager.PermissionStatus.notDetermined.displayName, "Not Determined")
    }

    func testMeetingTitleNormalization() {
        let trimmed = MeetingDetector.normalizeMeetingTitle("Team Sync - Google Meet  ")
        XCTAssertEqual(trimmed, "Team Sync")

        let fallback = MeetingDetector.normalizeMeetingTitle("   ")
        XCTAssertEqual(fallback, "Google Meet")
    }

    func testMeetingDetectorNotifiesOncePerMeeting() {
        let scheduler = MockMeetingNotificationScheduler()
        let detector = MeetingDetector(notificationScheduler: scheduler)

        detector.handleDetection(app: .zoom, meetingTitle: "Daily Sync")
        detector.handleDetection(app: .zoom, meetingTitle: "Daily Sync")
        XCTAssertEqual(scheduler.requests.count, 1)

        #if DEBUG
        detector.resetDetectionStateForTesting()
        #endif

        detector.handleDetection(app: .zoom, meetingTitle: "Daily Sync")
        XCTAssertEqual(scheduler.requests.count, 2)
    }

    func testStickyDetectionPreventsFlickering() {
        let scheduler = MockMeetingNotificationScheduler()
        let detector = MeetingDetector(notificationScheduler: scheduler)

        // Simulate detection
        _ = detector.handleDetection(app: MeetingDetector.MeetingApp.zoom, meetingTitle: "Test Meeting")
        XCTAssertTrue(detector.isInMeeting, "Should be in meeting after detection")

        // State should remain stable (sticky detection)
        XCTAssertEqual(detector.detectedApp, MeetingDetector.MeetingApp.zoom, "App should remain detected")
        XCTAssertEqual(detector.meetingTitle, "Test Meeting", "Title should persist")
    }

    func testMeetingDetectorNotifiesOnlyOnce() {
        let scheduler = MockMeetingNotificationScheduler()
        let detector = MeetingDetector(notificationScheduler: scheduler)

        // First detection should notify
        _ = detector.handleDetection(app: MeetingDetector.MeetingApp.zoom, meetingTitle: "Meeting 1")
        XCTAssertEqual(scheduler.notificationCount, 1, "Should notify on first detection")

        // Same meeting should not notify again
        _ = detector.handleDetection(app: MeetingDetector.MeetingApp.zoom, meetingTitle: "Meeting 1")
        XCTAssertEqual(scheduler.notificationCount, 1, "Should not notify for same meeting")

        // Different meeting should notify
        _ = detector.handleDetection(app: MeetingDetector.MeetingApp.zoom, meetingTitle: "Meeting 2")
        XCTAssertEqual(scheduler.notificationCount, 2, "Should notify for different meeting")
    }
}

// MARK: - Non-blocking behavior tests

@MainActor
final class NonBlockingBehaviorTests: XCTestCase {
    /// Verify MeetingDetector.startMonitoring returns immediately without blocking.
    /// The actual detection happens asynchronously on a background thread.
    func testMeetingDetectorStartMonitoringDoesNotBlock() {
        let mockScheduler = MockMeetingNotificationScheduler()
        let detector = MeetingDetector(notificationScheduler: mockScheduler)

        // Measure how long startMonitoring takes - should be < 100ms
        let start = CFAbsoluteTimeGetCurrent()
        detector.startMonitoring()
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        detector.stopMonitoring()

        // startMonitoring should return almost immediately (< 100ms)
        // AppleScript execution takes 500ms+ if run synchronously
        XCTAssertLessThan(elapsed, 0.1, "startMonitoring should not block main thread")
    }
}
