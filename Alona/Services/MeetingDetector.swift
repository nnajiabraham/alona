import AppKit
import Combine
import Foundation

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

    private var pollTimer: Timer?
    private var workspaceObserver: Any?
    private let pollInterval: TimeInterval = 2.0

    func startMonitoring() {
        guard pollTimer == nil else { return }

        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkMeetingStatus()
            }
        }

        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkMeetingStatus()
            }
        }

        checkMeetingStatus()
    }

    func stopMonitoring() {
        pollTimer?.invalidate()
        pollTimer = nil

        if let observer = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            workspaceObserver = nil
        }
    }

    private func checkMeetingStatus() {
        if checkZoomMeeting() {
            return
        }

        if checkGoogleMeet() {
            return
        }

        isInMeeting = false
        detectedApp = nil
        meetingTitle = "No meeting detected"
    }

    private func checkZoomMeeting() -> Bool {
        guard let zoomApp = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == MeetingApp.zoom.rawValue }) else {
            return false
        }

        guard verifyUDPConnections(for: zoomApp.processIdentifier) else {
            return false
        }

        detectedApp = .zoom
        isInMeeting = true
        meetingTitle = zoomApp.localizedName ?? "Zoom Meeting"
        automationPermissionDenied = false
        return true
    }

    private func verifyUDPConnections(for pid: pid_t) -> Bool {
        guard let executableURL = Self.locateLSOFExecutable() else {
            return false
        }

        let task = Process()
        task.executableURL = executableURL
        task.arguments = ["-i", "4UDP", "-p", "\(pid)"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return false }

            return output.components(separatedBy: "\n").count > 2
        } catch {
            return false
        }
    }

    private func checkGoogleMeet() -> Bool {
        let script = Self.googleMeetAppleScript
        var errorInfo: NSDictionary?
        let appleScript = NSAppleScript(source: script)
        let result = appleScript?.executeAndReturnError(&errorInfo)

        if let errorInfo, let errorNumber = errorInfo[NSAppleScript.errorNumber] as? Int, errorNumber == -1743 {
            automationPermissionDenied = true
            return false
        }

        if let errorInfo {
            automationPermissionDenied = false
            NSLog("AppleScript error: %@", errorInfo)
            return false
        }

        guard let title = result?.stringValue, !title.isEmpty else {
            automationPermissionDenied = false
            return false
        }

        detectedApp = .googleMeet
        isInMeeting = true
        meetingTitle = Self.normalizeMeetingTitle(title)
        automationPermissionDenied = false
        return true
    }
}

extension MeetingDetector {
    static func normalizeMeetingTitle(_ rawTitle: String) -> String {
        let cleaned = rawTitle.replacingOccurrences(of: " - Google Meet", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Google Meet" : cleaned
    }
}

private extension MeetingDetector {
    static func locateLSOFExecutable() -> URL? {
        let potentialPaths = ["/usr/sbin/lsof", "/usr/bin/lsof"]
        let fileManager = FileManager.default
        for path in potentialPaths where fileManager.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    static var googleMeetAppleScript: String {
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
