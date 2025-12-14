import AppKit
import ApplicationServices
import AVFoundation
import Combine
import CoreGraphics

@MainActor
final class PermissionManager: ObservableObject {
    enum PermissionType: CaseIterable, Hashable {
        case microphone
        case screenRecording
        case accessibility
        case automation

        var settingsURL: URL? {
            let base = "x-apple.systempreferences:com.apple.preference.security?"
            switch self {
            case .microphone:
                return URL(string: base + "Privacy_Microphone")
            case .screenRecording:
                return URL(string: base + "Privacy_ScreenCapture")
            case .accessibility:
                return URL(string: base + "Privacy_Accessibility")
            case .automation:
                return URL(string: base + "Privacy_Automation")
            }
        }

        var title: String {
            switch self {
            case .microphone: return "Microphone"
            case .screenRecording: return "Screen Recording"
            case .accessibility: return "Accessibility"
            case .automation: return "Automation"
            }
        }
    }

    enum PermissionStatus: String {
        case granted
        case denied
        case notDetermined

        var displayName: String {
            switch self {
            case .granted: return "Granted"
            case .denied: return "Denied"
            case .notDetermined: return "Not Determined"
            }
        }
    }

    @Published private(set) var statuses: [PermissionType: PermissionStatus] = [:]
    @Published var lastAutomationCheckError: Error?

    init() {
        PermissionType.allCases.forEach { statuses[$0] = .notDetermined }
        // Refresh permissions on init so UI shows current status immediately
        refreshAllPermissions()
    }

    func refreshAllPermissions() {
        // Sync checks (fast, non-blocking)
        statuses[.microphone] = currentMicrophoneStatus()
        statuses[.screenRecording] = currentScreenRecordingStatus()
        statuses[.accessibility] = currentAccessibilityStatus()

        // Async check for automation (runs AppleScript, potentially slow)
        refreshAutomationPermissionAsync()
    }

    private func refreshAutomationPermissionAsync() {
        Task.detached(priority: .utility) { [weak self] in
            let status = Self.checkAutomationStatusBackground()
            await MainActor.run {
                self?.statuses[.automation] = status
            }
        }
    }

    private nonisolated static func checkAutomationStatusBackground() -> PermissionStatus {
        let script = "tell application \"System Events\" to get name of every process"
        var errorDict: NSDictionary?
        let appleScript = NSAppleScript(source: script)
        let result = appleScript?.executeAndReturnError(&errorDict)

        if let errorDict, let errorNumber = errorDict[NSAppleScript.errorNumber] as? Int, errorNumber == -1743 {
            return .denied
        }

        if errorDict != nil {
            return .denied
        }

        return result != nil ? .granted : .denied
    }

    func requestPermission(_ type: PermissionType) {
        switch type {
        case .microphone:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                Task { @MainActor in
                    self?.statuses[.microphone] = granted ? .granted : .denied
                }
            }
        case .screenRecording:
            let allowed = CGRequestScreenCaptureAccess()
            statuses[.screenRecording] = allowed ? .granted : .denied
        case .accessibility:
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            let trusted = AXIsProcessTrustedWithOptions(options)
            statuses[.accessibility] = trusted ? .granted : .denied
        case .automation:
            // Run async to avoid blocking main thread
            Task.detached(priority: .userInitiated) { [weak self] in
                let status = Self.checkAutomationStatusBackground()
                await MainActor.run {
                    self?.statuses[.automation] = status
                    if status == .denied {
                        self?.openSystemSettings(for: .automation)
                    }
                }
            }
        }
    }

    func openSystemSettings(for type: PermissionType) {
        guard let url = type.settingsURL else { return }
        NSWorkspace.shared.open(url)
    }

    private func currentMicrophoneStatus() -> PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return .granted
        case .denied, .restricted:
            return .denied
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .notDetermined
        }
    }

    private func currentScreenRecordingStatus() -> PermissionStatus {
        if CGPreflightScreenCaptureAccess() {
            return .granted
        }
        return .denied
    }

    private func currentAccessibilityStatus() -> PermissionStatus {
        AXIsProcessTrusted() ? .granted : .denied
    }
}
