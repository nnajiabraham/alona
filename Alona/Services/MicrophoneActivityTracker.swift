import AudioToolbox
import Foundation
import OSLog

/// Tracks which applications are actively using the microphone using CoreAudio APIs.
/// This provides a more reliable meeting detection signal than process/URL checks alone.
@MainActor
final class MicrophoneActivityTracker: ObservableObject {
    static let shared = MicrophoneActivityTracker()

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Alona",
        category: "MicrophoneActivityTracker")

    @Published private(set) var appsUsingMicrophone: Set<String> = []

    private var pollTimer: Timer?
    private let pollInterval: TimeInterval = 2.0

    private init() {}

    func startTracking() {
        guard self.pollTimer == nil else { return }

        self.pollTimer = Timer.scheduledTimer(withTimeInterval: self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateMicrophoneUsage()
            }
        }

        // Initial check
        self.updateMicrophoneUsage()
    }

    func stopTracking() {
        self.pollTimer?.invalidate()
        self.pollTimer = nil
    }

    /// Check if a specific app (by bundle identifier) is currently using the microphone.
    func isAppUsingMicrophone(bundleIdentifier: String) -> Bool {
        self.appsUsingMicrophone.contains(bundleIdentifier)
    }

    private func updateMicrophoneUsage() {
        Task.detached(priority: .utility) {
            let usingMic = Self.getAppsUsingMicrophone()

            await MainActor.run { [weak self] in
                self?.appsUsingMicrophone = usingMic
            }
        }
    }

    /// Returns bundle identifiers of all apps currently using the microphone.
    private nonisolated static func getAppsUsingMicrophone() -> Set<String> {
        var result = Set<String>()

        guard let processObjects = try? AudioObjectID.readProcessList() else {
            return result
        }

        for processObject in processObjects {
            // Check if process is running audio input
            guard processObject.readProcessIsRunningInput() else { continue }

            // Get bundle identifier
            if let bundleID = processObject.readProcessBundleID() {
                result.insert(bundleID)
            }
        }

        return result
    }
}

// MARK: - Meeting Detection Integration

extension MicrophoneActivityTracker {
    /// Check if Zoom is in an active meeting (running + using microphone).
    /// Checks multiple Zoom bundle IDs for compatibility with different Zoom versions.
    func isZoomInMeeting() -> Bool {
        let zoomBundleIDs = ["us.zoom.xos", "us.zoom.ZoomHelperAgent", "us.zoom.Workplace", "us.zoom.videomeetings"]
        return zoomBundleIDs.contains { self.isAppUsingMicrophone(bundleIdentifier: $0) }
    }

    /// Check if Chrome (Google Meet) is in an active meeting (running + using microphone).
    func isChromeUsingMicrophone() -> Bool {
        self.isAppUsingMicrophone(bundleIdentifier: "com.google.Chrome")
    }

    /// Check if any known meeting app is using the microphone.
    func isAnyMeetingAppUsingMicrophone() -> Bool {
        self.isZoomInMeeting() || self.isChromeUsingMicrophone() ||
            self.isAppUsingMicrophone(bundleIdentifier: "com.microsoft.teams") ||
            self.isAppUsingMicrophone(bundleIdentifier: "com.microsoft.teams2")
    }
}
