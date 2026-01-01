import Foundation
import UserNotifications

@MainActor
protocol MeetingNotificationScheduling {
    func scheduleMeetingNotification(appName: String, meetingTitle: String, identifier: String)
}

extension Notification.Name {
    static let meetingNotificationStartRecording = Notification.Name("meetingNotificationStartRecording")
}

@MainActor
final class MeetingNotificationManager: NSObject, MeetingNotificationScheduling, UNUserNotificationCenterDelegate {
    static let shared = MeetingNotificationManager()

    private let notificationCenter = UNUserNotificationCenter.current()
    // nonisolated needed because these are accessed from nonisolated delegate method
    private nonisolated static let categoryIdentifier = "meeting-detected-category"
    private nonisolated static let startActionIdentifier = "meeting-start-recording"
    private var authorizationRequested = false

    override private init() {
        super.init()
        self.notificationCenter.delegate = self
        configureCategories()
        requestAuthorizationIfNeeded()
    }

    func scheduleMeetingNotification(appName: String, meetingTitle: String, identifier: String) {
        requestAuthorizationIfNeeded()
        let content = UNMutableNotificationContent()
        content.title = "\(appName) meeting detected"
        content.body = "Tap Start Recording to capture \"\(meetingTitle)\"."
        content.sound = UNNotificationSound.default
        content.categoryIdentifier = Self.categoryIdentifier
        content.userInfo = ["meetingTitle": meetingTitle]

        let request = UNNotificationRequest(
            identifier: "meeting-\(identifier)",
            content: content,
            trigger: nil)
        self.notificationCenter.add(request)
    }

    nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void)
    {
        let actionId = response.actionIdentifier
        if actionId == Self.startActionIdentifier || actionId == UNNotificationDefaultActionIdentifier {
            let title = response.notification.request.content.userInfo["meetingTitle"] as? String
            NotificationCenter.default.post(
                name: .meetingNotificationStartRecording,
                object: nil,
                userInfo: ["meetingTitle": title ?? "Meeting"])
        }
        completionHandler()
    }
}

extension MeetingNotificationManager {
    private func configureCategories() {
        let startAction = UNNotificationAction(
            identifier: Self.startActionIdentifier,
            title: "Start Recording",
            options: [.foreground])
        let category = UNNotificationCategory(
            identifier: Self.categoryIdentifier,
            actions: [startAction],
            intentIdentifiers: [],
            options: [])
        self.notificationCenter.setNotificationCategories([category])
    }

    private func requestAuthorizationIfNeeded() {
        guard !self.authorizationRequested else { return }
        self.authorizationRequested = true
        self.notificationCenter.requestAuthorization(options: [.alert, .sound]) { _, _ in
            // Silent failures are acceptable; the UI still has manual options.
        }
    }
}
