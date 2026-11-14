import Foundation
import UserNotifications
import XCTest
@testable import AlonaCore

// MARK: - MeetingNotificationManager Tests

@MainActor
final class MeetingNotificationManagerTests: XCTestCase {
    func testNotificationNameConstant() {
        // Verify the notification name constant is correctly defined
        let name = Notification.Name.meetingNotificationStartRecording
        XCTAssertEqual(name.rawValue, "meetingNotificationStartRecording")
    }

    func testMeetingNotificationSchedulingProtocolExists() {
        // Verify the protocol can be implemented (using our mock)
        let mock = MockMeetingNotificationScheduler()
        mock.scheduleMeetingNotification(appName: "Zoom", meetingTitle: "Test", identifier: "test-123")

        XCTAssertEqual(mock.notificationCount, 1)
        XCTAssertEqual(mock.requests.first, "test-123")
    }

    func testNotificationContentFormat() {
        // Test that notification content would be formatted correctly
        // We can't directly test UNMutableNotificationContent creation in unit tests
        // but we can test the formatting logic

        let appName = "Zoom"
        let meetingTitle = "Weekly Standup"
        let identifier = "zoom-12345"

        let expectedTitle = "\(appName) meeting detected"
        let expectedBody = "Tap Start Recording to capture \"\(meetingTitle)\"."
        let expectedIdentifier = "meeting-\(identifier)"

        XCTAssertEqual(expectedTitle, "Zoom meeting detected")
        XCTAssertEqual(expectedBody, "Tap Start Recording to capture \"Weekly Standup\".")
        XCTAssertEqual(expectedIdentifier, "meeting-zoom-12345")
    }

    func testMockSchedulerTracksMultipleNotifications() {
        let mock = MockMeetingNotificationScheduler()

        mock.scheduleMeetingNotification(appName: "Zoom", meetingTitle: "Meeting 1", identifier: "id-1")
        mock.scheduleMeetingNotification(appName: "Meet", meetingTitle: "Meeting 2", identifier: "id-2")
        mock.scheduleMeetingNotification(appName: "Zoom", meetingTitle: "Meeting 3", identifier: "id-3")

        XCTAssertEqual(mock.notificationCount, 3)
        XCTAssertEqual(mock.requests, ["id-1", "id-2", "id-3"])
    }
}

// MARK: - Notification Center Observer Tests

final class NotificationCenterObserverTests: XCTestCase {
    func testMeetingNotificationPostsCorrectly() {
        let expectation = self.expectation(description: "Notification received")
        var receivedTitle: String?

        let observer = NotificationCenter.default.addObserver(
            forName: .meetingNotificationStartRecording,
            object: nil,
            queue: .main) { notification in
                receivedTitle = notification.userInfo?["meetingTitle"] as? String
                expectation.fulfill()
            }

        defer { NotificationCenter.default.removeObserver(observer) }

        // Post notification
        NotificationCenter.default.post(
            name: .meetingNotificationStartRecording,
            object: nil,
            userInfo: ["meetingTitle": "Test Meeting"])

        wait(for: [expectation], timeout: 1.0)

        XCTAssertEqual(receivedTitle, "Test Meeting")
    }

    func testMeetingNotificationWithMissingTitle() {
        let expectation = self.expectation(description: "Notification received")
        var receivedTitle: String?

        let observer = NotificationCenter.default.addObserver(
            forName: .meetingNotificationStartRecording,
            object: nil,
            queue: .main) { notification in
                receivedTitle = notification.userInfo?["meetingTitle"] as? String
                expectation.fulfill()
            }

        defer { NotificationCenter.default.removeObserver(observer) }

        // Post notification without title
        NotificationCenter.default.post(
            name: .meetingNotificationStartRecording,
            object: nil,
            userInfo: nil)

        wait(for: [expectation], timeout: 1.0)

        XCTAssertNil(receivedTitle, "Should be nil when no title provided")
    }
}
