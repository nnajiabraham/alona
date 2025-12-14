import AudioToolbox
import Foundation
import OSLog

/// Tracks which applications are actively using the microphone using CoreAudio APIs.
/// This provides a more reliable meeting detection signal than process/URL checks alone.
final class MicrophoneActivityTracker: ObservableObject {
    static let shared = MicrophoneActivityTracker()

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Alona", category: "MicrophoneActivityTracker")

    @Published private(set) var appsUsingMicrophone: Set<String> = []

    private var pollTimer: Timer?
    private let pollInterval: TimeInterval = 2.0

    private init() {}

    func startTracking() {
        guard pollTimer == nil else { return }

        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.updateMicrophoneUsage()
        }

        // Initial check
        updateMicrophoneUsage()
    }

    func stopTracking() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// Check if a specific app (by bundle identifier) is currently using the microphone.
    func isAppUsingMicrophone(bundleIdentifier: String) -> Bool {
        appsUsingMicrophone.contains(bundleIdentifier)
    }

    private func updateMicrophoneUsage() {
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }

            let usingMic = Self.getAppsUsingMicrophone()

            await MainActor.run {
                self.appsUsingMicrophone = usingMic
            }
        }
    }

    /// Returns bundle identifiers of all apps currently using the microphone.
    private static func getAppsUsingMicrophone() -> Set<String> {
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
    func isZoomInMeeting() -> Bool {
        isAppUsingMicrophone(bundleIdentifier: "us.zoom.xos")
    }

    /// Check if Chrome (Google Meet) is in an active meeting (running + using microphone).
    func isChromeUsingMicrophone() -> Bool {
        isAppUsingMicrophone(bundleIdentifier: "com.google.Chrome")
    }
}
