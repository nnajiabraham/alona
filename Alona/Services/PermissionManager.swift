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
    }

    func refreshAllPermissions() {
        statuses[.microphone] = currentMicrophoneStatus()
        statuses[.screenRecording] = currentScreenRecordingStatus()
        statuses[.accessibility] = currentAccessibilityStatus()
        statuses[.automation] = currentAutomationStatus()
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
            do {
                let granted = try runAutomationProbe(promptUser: true)
                statuses[.automation] = granted ? .granted : .denied
            } catch {
                statuses[.automation] = .denied
                lastAutomationCheckError = error
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

    private func currentAutomationStatus() -> PermissionStatus {
        do {
            let authorized = try runAutomationProbe(promptUser: false)
            return authorized ? .granted : .denied
        } catch {
            lastAutomationCheckError = error
            return .denied
        }
    }

    @discardableResult
    private func runAutomationProbe(promptUser: Bool) throws -> Bool {
        let script = "tell application \"System Events\" to get name of every process"
        var errorDict: NSDictionary?
        let appleScript = NSAppleScript(source: script)
        let result = appleScript?.executeAndReturnError(&errorDict)

        if let errorDict, let errorNumber = errorDict[NSAppleScript.errorNumber] as? Int, errorNumber == -1743 {
            if promptUser {
                openSystemSettings(for: .automation)
            }
            return false
        }

        if let errorDict {
            throw NSError(domain: "AutomationProbe", code: (errorDict[NSAppleScript.errorNumber] as? Int) ?? -1, userInfo: errorDict as? [String: Any])
        }

        return result != nil
    }
}
