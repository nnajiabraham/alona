import AppKit
import Foundation
import Observation
import OSLog

@Observable
@MainActor
final class MeetingDetector {
    enum MeetingApp: String, CaseIterable {
        case zoom = "us.zoom.xos"
        case googleMeet = "com.google.Chrome"
        case teams = "com.microsoft.teams"

        var displayName: String {
            switch self {
            case .zoom: "Zoom"
            case .googleMeet: "Google Meet"
            case .teams: "Microsoft Teams"
            }
        }
    }

    var isInMeeting = false
    var detectedApp: MeetingApp?
    var meetingTitle: String = "No meeting detected"
    var automationPermissionDenied = false

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Alona", category: "MeetingDetector")
    private var pollTimer: Timer?
    private var workspaceObserver: Any?
    private let pollInterval: TimeInterval = 2.0
    private let notificationScheduler: MeetingNotificationScheduling
    private var lastNotificationIdentifier: String?
    private let microphoneTracker = MicrophoneActivityTracker.shared

    // Sticky detection: prevent flickering by keeping detection stable
    private var lastDetectedApp: MeetingApp?
    private var missedDetectionCount = 0
    private let missedDetectionThreshold = 3 // Require 3 consecutive misses before clearing

    init(notificationScheduler: MeetingNotificationScheduling = MeetingNotificationManager.shared) {
        self.notificationScheduler = notificationScheduler
    }

    func startMonitoring() {
        guard self.pollTimer == nil else { return }

        // Start tracking microphone activity
        self.microphoneTracker.startTracking()

        self.workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main)
        { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleBackgroundCheck()
            }
        }

        self.pollTimer = Timer.scheduledTimer(withTimeInterval: self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleBackgroundCheck()
            }
        }

        // Initial check on background thread to avoid blocking main thread
        self.scheduleBackgroundCheck()
    }

    private func scheduleBackgroundCheck() {
        // Capture current mic usage state on main thread
        let zoomUsingMic = self.microphoneTracker.isZoomInMeeting()
        let chromeUsingMic = self.microphoneTracker.isChromeUsingMicrophone()

        Task.detached(priority: .utility) { [weak self] in
            await self?.checkMeetingStatusBackground(zoomUsingMic: zoomUsingMic, chromeUsingMic: chromeUsingMic)
        }
    }

    func stopMonitoring() {
        self.pollTimer?.invalidate()
        self.pollTimer = nil

        self.microphoneTracker.stopTracking()

        if let observer = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            self.workspaceObserver = nil
        }
    }

    /// Called from background thread - performs blocking operations off main thread
    private nonisolated func checkMeetingStatusBackground(zoomUsingMic: Bool, chromeUsingMic: Bool) async {
        // Perform blocking operations on current (background) thread
        let zoomResult = Self.checkZoomMeetingBackground(isUsingMicrophone: zoomUsingMic)
        let googleMeetResult = Self.checkGoogleMeetBackground(isUsingMicrophone: chromeUsingMic)

        // Update UI state on main thread
        await MainActor.run {
            self.applyDetectionResult(zoom: zoomResult, googleMeet: googleMeetResult)
        }
    }

    private func applyDetectionResult(zoom: DetectionResult, googleMeet: DetectionResult) {
        // Apply Zoom result
        if case let .detected(app, title) = zoom {
            self.missedDetectionCount = 0
            self.lastDetectedApp = app
            _ = self.handleDetection(app: app, meetingTitle: title)
            return
        }
        if case .permissionDenied = zoom {
            self.automationPermissionDenied = true
        }

        // Apply Google Meet result
        if case let .detected(app, title) = googleMeet {
            self.missedDetectionCount = 0
            self.lastDetectedApp = app
            self.automationPermissionDenied = false
            _ = self.handleDetection(app: app, meetingTitle: title)
            return
        }
        if case .permissionDenied = googleMeet {
            self.automationPermissionDenied = true
        } else {
            self.automationPermissionDenied = false
        }

        // No meeting detected - but use sticky detection to prevent flickering
        // Only clear detection after several consecutive misses
        if self.isInMeeting, let lastApp = lastDetectedApp {
            // Check if the meeting app is still running
            let appStillRunning = NSWorkspace.shared.runningApplications.contains {
                $0.bundleIdentifier == lastApp.rawValue ||
                    (lastApp == .googleMeet && $0.bundleIdentifier == "com.google.Chrome")
            }

            if appStillRunning {
                self.missedDetectionCount += 1
                // swiftformat:disable:next redundantSelf
                logger.debug("Meeting app still running, missed count: \(self.missedDetectionCount)")

                // Keep detection active if below threshold
                if self.missedDetectionCount < self.missedDetectionThreshold {
                    return
                }
            }
        }

        // Clear detection
        self.missedDetectionCount = 0
        self.lastDetectedApp = nil
        self.isInMeeting = false
        self.detectedApp = nil
        self.meetingTitle = "No meeting detected"
        self.lastNotificationIdentifier = nil
    }

    private enum DetectionResult {
        case detected(app: MeetingApp, title: String)
        case notDetected
        case permissionDenied
    }

    /// Improved Zoom detection: Zoom running + using microphone OR Zoom with active meeting UI
    /// Also checks for Zoom Workplace (newer bundle ID)
    private nonisolated static func checkZoomMeetingBackground(isUsingMicrophone: Bool) -> DetectionResult {
        // Check for both Zoom bundle IDs (us.zoom.xos and Zoom Workplace)
        let zoomBundleIDs = ["us.zoom.xos", "us.zoom.ZoomHelperAgent", "us.zoom.Workplace"]
        let zoomRunning = NSWorkspace.shared.runningApplications.contains { app in
            guard let bundleID = app.bundleIdentifier else { return false }
            return zoomBundleIDs.contains(bundleID)
        }

        guard zoomRunning else {
            return .notDetected
        }

        // If Zoom is using the microphone, it's likely in a meeting
        if isUsingMicrophone {
            return .detected(app: .zoom, title: "Zoom Meeting")
        }

        // Fall back to AppleScript UI check for cases where mic might not be active yet
        // This catches cases like muted in meeting or just joined
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
        guard NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == MeetingApp.googleMeet.rawValue }) != nil
        else {
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
        self.detectedApp = app
        self.isInMeeting = true
        self.meetingTitle = title
        self.automationPermissionDenied = false
        let identifier = "\(app.rawValue)|\(title)"
        if self.lastNotificationIdentifier != identifier {
            // Show floating popup notification (Granola-style)
            self.showMeetingPopup(app: app, meetingTitle: title)
            // Also call notification scheduler (for testing and fallback)
            self.notificationScheduler.scheduleMeetingNotification(
                appName: app.displayName,
                meetingTitle: title,
                identifier: identifier)
            self.lastNotificationIdentifier = identifier
        }
        return true
    }

    private func showMeetingPopup(app: MeetingApp, meetingTitle: String) {
        MeetingPopupWindowController.shared.showMeetingDetected(
            appName: app.displayName,
            meetingTitle: meetingTitle,
            onStartRecording: { [weak self] in
                guard let self else { return }
                Task {
                    await self.startRecordingFromPopup()
                }
            })
    }

    private func startRecordingFromPopup() async {
        // Post notification to start recording (uses existing notification from MeetingNotificationManager)
        NotificationCenter.default.post(
            name: .meetingNotificationStartRecording,
            object: nil,
            userInfo: ["meetingTitle": self.meetingTitle])
    }

    #if DEBUG
    func resetDetectionStateForTesting() {
        self.isInMeeting = false
        self.detectedApp = nil
        self.meetingTitle = "No meeting detected"
        self.lastNotificationIdentifier = nil
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

extension MeetingDetector {
    /// Improved Google Meet AppleScript that only matches actual meeting URLs
    /// Excludes: /lookup/, landing pages, "meeting ended" pages
    fileprivate nonisolated static var googleMeetAppleScriptImproved: String {
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
    fileprivate nonisolated static var googleMeetAppleScript: String {
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
