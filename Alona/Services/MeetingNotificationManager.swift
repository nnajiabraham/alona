import Foundation
import UserNotifications

protocol MeetingNotificationScheduling {
    func scheduleMeetingNotification(appName: String, meetingTitle: String, identifier: String)
}

extension Notification.Name {
    static let meetingNotificationStartRecording = Notification.Name("meetingNotificationStartRecording")
}

final class MeetingNotificationManager: NSObject, MeetingNotificationScheduling, UNUserNotificationCenterDelegate {
    static let shared = MeetingNotificationManager()

    private let notificationCenter = UNUserNotificationCenter.current()
    private let categoryIdentifier = "meeting-detected-category"
    private let startActionIdentifier = "meeting-start-recording"
    private var authorizationRequested = false

    override private init() {
        super.init()
        notificationCenter.delegate = self
        configureCategories()
        requestAuthorizationIfNeeded()
    }

    func scheduleMeetingNotification(appName: String, meetingTitle: String, identifier: String) {
        requestAuthorizationIfNeeded()
        let content = UNMutableNotificationContent()
        content.title = "\(appName) meeting detected"
        content.body = "Tap Start Recording to capture \"\(meetingTitle)\"."
        content.sound = UNNotificationSound.default
        content.categoryIdentifier = categoryIdentifier
        content.userInfo = ["meetingTitle": meetingTitle]

        let request = UNNotificationRequest(
            identifier: "meeting-\(identifier)",
            content: content,
            trigger: nil
        )
        notificationCenter.add(request)
    }

    func userNotificationCenter(_: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.actionIdentifier == startActionIdentifier || response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            let title = response.notification.request.content.userInfo["meetingTitle"] as? String
            NotificationCenter.default.post(
                name: .meetingNotificationStartRecording,
                object: nil,
                userInfo: ["meetingTitle": title ?? "Meeting"]
            )
        }
        completionHandler()
    }
}

private extension MeetingNotificationManager {
    func configureCategories() {
        let startAction = UNNotificationAction(
            identifier: startActionIdentifier,
            title: "Start Recording",
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: categoryIdentifier,
            actions: [startAction],
            intentIdentifiers: [],
            options: []
        )
        notificationCenter.setNotificationCategories([category])
    }

    func requestAuthorizationIfNeeded() {
        guard !authorizationRequested else { return }
        authorizationRequested = true
        notificationCenter.requestAuthorization(options: [.alert, .sound]) { _, _ in
            // Silent failures are acceptable; the UI still has manual options.
        }
    }
}
