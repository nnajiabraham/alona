import AppKit
import Combine
import Foundation
import OSLog

@MainActor
final class MeetingDetector: ObservableObject {
    enum MeetingApp: String, CaseIterable {
        case zoom = "us.zoom.xos"
        case googleMeet = "com.google.Chrome"
        case teams = "com.microsoft.teams"

        var displayName: String {
            switch self {
            case .zoom: return "Zoom"
            case .googleMeet: return "Google Meet"
            case .teams: return "Microsoft Teams"
            }
        }
    }

    @Published var isInMeeting = false
    @Published var detectedApp: MeetingApp?
    @Published var meetingTitle: String = "No meeting detected"
    @Published var automationPermissionDenied = false

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Alona", category: "MeetingDetector")
    private var pollTimer: Timer?
    private var workspaceObserver: Any?
    private let pollInterval: TimeInterval = 2.0
    private let notificationScheduler: MeetingNotificationScheduling
    private var lastNotificationIdentifier: String?
    private let microphoneTracker = MicrophoneActivityTracker.shared

    init(notificationScheduler: MeetingNotificationScheduling = MeetingNotificationManager.shared) {
        self.notificationScheduler = notificationScheduler
    }

    func startMonitoring() {
        guard pollTimer == nil else { return }

        // Start tracking microphone activity
        microphoneTracker.startTracking()

        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleBackgroundCheck()
            }
        }

        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleBackgroundCheck()
            }
        }

        // Initial check on background thread to avoid blocking main thread
        scheduleBackgroundCheck()
    }

    private func scheduleBackgroundCheck() {
        // Capture current mic usage state on main thread
        let zoomUsingMic = microphoneTracker.isZoomInMeeting()
        let chromeUsingMic = microphoneTracker.isChromeUsingMicrophone()

        Task.detached(priority: .utility) { [weak self] in
            await self?.checkMeetingStatusBackground(zoomUsingMic: zoomUsingMic, chromeUsingMic: chromeUsingMic)
        }
    }

    func stopMonitoring() {
        pollTimer?.invalidate()
        pollTimer = nil

        microphoneTracker.stopTracking()

        if let observer = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            workspaceObserver = nil
        }
    }

    /// Called from background thread - performs blocking operations off main thread
    private nonisolated func checkMeetingStatusBackground(zoomUsingMic: Bool, chromeUsingMic: Bool) async {
        // Perform blocking operations on current (background) thread
        let zoomResult = Self.checkZoomMeetingBackground(isUsingMicrophone: zoomUsingMic)
        let googleMeetResult = Self.checkGoogleMeetBackground(isUsingMicrophone: chromeUsingMic)

        // Update UI state on main thread
        await MainActor.run {
            applyDetectionResult(zoom: zoomResult, googleMeet: googleMeetResult)
        }
    }

    private func applyDetectionResult(zoom: DetectionResult, googleMeet: DetectionResult) {
        // Apply Zoom result
        if case let .detected(app, title) = zoom {
            _ = handleDetection(app: app, meetingTitle: title)
            return
        }
        if case .permissionDenied = zoom {
            automationPermissionDenied = true
        }

        // Apply Google Meet result
        if case let .detected(app, title) = googleMeet {
            automationPermissionDenied = false
            _ = handleDetection(app: app, meetingTitle: title)
            return
        }
        if case .permissionDenied = googleMeet {
            automationPermissionDenied = true
        } else {
            automationPermissionDenied = false
        }

        // No meeting detected
        isInMeeting = false
        detectedApp = nil
        meetingTitle = "No meeting detected"
        lastNotificationIdentifier = nil
    }

    private enum DetectionResult {
        case detected(app: MeetingApp, title: String)
        case notDetected
        case permissionDenied
    }

    /// Improved Zoom detection: Zoom running + using microphone OR Zoom with active meeting UI
    private nonisolated static func checkZoomMeetingBackground(isUsingMicrophone: Bool) -> DetectionResult {
        guard NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == MeetingApp.zoom.rawValue }) != nil else {
            return .notDetected
        }

        // If Zoom is using the microphone, it's likely in a meeting
        if isUsingMicrophone {
            return .detected(app: .zoom, title: "Zoom Meeting")
        }

        // Fall back to AppleScript UI check for cases where mic might not be active yet
        switch zoomMeetingUIState() {
        case .permissionDenied:
            return .permissionDenied
        case .inactive:
            return .notDetected
        case .active:
            return .detected(app: .zoom, title: "Zoom Meeting")
        }
    }

    /// Improved Google Meet detection: Chrome running + meet.google.com tab with meeting URL + optional mic check
    private nonisolated static func checkGoogleMeetBackground(isUsingMicrophone _: Bool) -> DetectionResult {
        // First check if Chrome is running
        guard NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == MeetingApp.googleMeet.rawValue }) != nil else {
            return .notDetected
        }

        // Check for Google Meet tab with improved URL matching
        let script = googleMeetAppleScriptImproved
        var errorInfo: NSDictionary?
        let appleScript = NSAppleScript(source: script)
        let result = appleScript?.executeAndReturnError(&errorInfo)

        if let errorInfo, let errorNumber = errorInfo[NSAppleScript.errorNumber] as? Int, errorNumber == -1743 {
            return .permissionDenied
        }

        if errorInfo != nil {
            return .notDetected
        }

        guard let title = result?.stringValue, !title.isEmpty else {
            return .notDetected
        }

        // Both mic usage and meeting tab detected = confirmed meeting
        // Just meeting tab = probable meeting (could be landing page)
        return .detected(app: .googleMeet, title: normalizeMeetingTitle(title))
    }

    @discardableResult
    func handleDetection(app: MeetingApp, meetingTitle title: String) -> Bool {
        detectedApp = app
        isInMeeting = true
        meetingTitle = title
        automationPermissionDenied = false
        let identifier = "\(app.rawValue)|\(title)"
        if lastNotificationIdentifier != identifier {
            notificationScheduler.scheduleMeetingNotification(appName: app.displayName, meetingTitle: title, identifier: identifier)
            lastNotificationIdentifier = identifier
        }
        return true
    }

    #if DEBUG
        func resetDetectionStateForTesting() {
            isInMeeting = false
            detectedApp = nil
            meetingTitle = "No meeting detected"
            lastNotificationIdentifier = nil
        }
    #endif
}

extension MeetingDetector {
    nonisolated static func normalizeMeetingTitle(_ rawTitle: String) -> String {
        let cleaned = rawTitle.replacingOccurrences(of: " - Google Meet", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Google Meet" : cleaned
    }
}

extension MeetingDetector {
    private enum ZoomUIState: Sendable {
        case active
        case inactive
        case permissionDenied
    }

    private nonisolated static func zoomMeetingUIState() -> ZoomUIState {
        var errorInfo: NSDictionary?
        let script = NSAppleScript(source: zoomMeetingAppleScript)
        let result = script?.executeAndReturnError(&errorInfo)

        if let errorInfo, let errorNumber = errorInfo[NSAppleScript.errorNumber] as? Int,
           errorNumber == -25211 || errorNumber == -25205 || errorNumber == -1743
        {
            return .permissionDenied
        }

        let isActive = result?.booleanValue ?? false
        return isActive ? .active : .inactive
    }

    private nonisolated static var zoomMeetingAppleScript: String {
        """
        tell application "System Events"
            repeat with appName in {"zoom.us", "Zoom Workplace"}
                if exists process appName then
                    tell process appName
                        if exists menu item "Leave Meeting" of menu "Meeting" of menu bar 1 then
                            return true
                        end if
                        if exists menu item "End Meeting" of menu "Meeting" of menu bar 1 then
                            return true
                        end if
                    end tell
                end if
            end repeat
        end tell
        return false
        """
    }
}

private extension MeetingDetector {
    /// Improved Google Meet AppleScript that only matches actual meeting URLs
    /// Excludes: /lookup/, landing pages, "meeting ended" pages
    nonisolated static var googleMeetAppleScriptImproved: String {
        """
        tell application "System Events"
            if exists (process "Google Chrome") then
                tell application "Google Chrome"
                    repeat with w in windows
                        repeat with t in tabs of w
                            set tabURL to URL of t
                            -- Only match URLs that are actual meetings (have meeting codes)
                            -- Meeting codes are typically 3 groups of letters like abc-defg-hij
                            if tabURL starts with "https://meet.google.com/" then
                                -- Exclude non-meeting URLs
                                if tabURL does not contain "/lookup/" and tabURL does not contain "authuser" and tabURL does not contain "/new" then
                                    -- Check if this looks like a meeting code (contains hyphen after the domain)
                                    set meetPath to text 25 thru -1 of tabURL
                                    if meetPath contains "-" then
                                        return title of t
                                    end if
                                end if
                            end if
                        end repeat
                    end repeat
                end tell
            end if
        end tell
        return ""
        """
    }

    /// Original simpler Google Meet script (kept for fallback)
    nonisolated static var googleMeetAppleScript: String {
        """
        tell application "System Events"
            if exists (process "Google Chrome") then
                tell application "Google Chrome"
                    repeat with w in windows
                        repeat with t in tabs of w
                            if URL of t contains "meet.google.com" then
                                return title of t
                            end if
                        end repeat
                    end repeat
                end tell
            end if
        end tell
        return ""
        """
    }
}
