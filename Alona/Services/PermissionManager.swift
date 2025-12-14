import AppKit
import ApplicationServices
import AudioToolbox
import AVFoundation
import Combine
import CoreGraphics

@MainActor
final class PermissionManager: ObservableObject {
    enum PermissionType: CaseIterable, Hashable {
        case microphone
        case systemAudio
        case accessibility
        case automation

        var settingsURL: URL? {
            let base = "x-apple.systempreferences:com.apple.preference.security?"
            switch self {
            case .microphone:
                return URL(string: base + "Privacy_Microphone")
            case .systemAudio:
                // System Audio Recording appears in Screen & System Audio Recording pane
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
            case .systemAudio: return "System Audio Recording"
            case .accessibility: return "Accessibility"
            case .automation: return "Automation"
            }
        }

        var description: String {
            switch self {
            case .microphone:
                return "Capture your voice during meetings"
            case .systemAudio:
                return "Capture audio from meeting participants (via CoreAudio Process Taps)"
            case .accessibility:
                return "Detect Zoom meeting UI state"
            case .automation:
                return "Detect Google Meet tabs in browsers"
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
        statuses[.systemAudio] = currentSystemAudioStatus()
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
        case .systemAudio:
            // CoreAudio Process Taps require actually attempting to create a tap
            // to trigger the permission dialog and add the app to System Settings.
            // We create a minimal process tap that immediately gets destroyed.
            Task {
                await requestSystemAudioPermission()
            }
        case .accessibility:
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            let trusted = AXIsProcessTrustedWithOptions(options)
            statuses[.accessibility] = trusted ? .granted : .denied
            // If not trusted, open settings and poll for changes
            if !trusted {
                openSystemSettings(for: .accessibility)
                // Poll for permission grant (user may toggle in System Settings)
                Task {
                    for _ in 0 ..< 30 { // Poll for up to 30 seconds
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        if AXIsProcessTrusted() {
                            await MainActor.run {
                                statuses[.accessibility] = .granted
                            }
                            break
                        }
                    }
                }
            }
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

    /// Checks system audio recording permission status using TCC SPI.
    private func currentSystemAudioStatus() -> PermissionStatus {
        // First try TCC SPI (most accurate)
        let tccStatus = checkSystemAudioWithTCC()
        if tccStatus != .notDetermined {
            // Update cached value
            UserDefaults.standard.set(tccStatus == .granted, forKey: "systemAudioPermissionGranted")
            return tccStatus
        }

        // Fall back to cached value if TCC SPI unavailable
        if UserDefaults.standard.bool(forKey: "systemAudioPermissionGranted") {
            return .granted
        }

        return .notDetermined
    }

    /// Requests System Audio Recording permission using TCC SPI.
    /// This explicitly requests kTCCServiceAudioCapture and adds the app to
    /// the "System Audio Recording Only" section in System Settings (like Granola).
    private func requestSystemAudioPermission() async {
        // Update status to show we're trying
        await MainActor.run {
            statuses[.systemAudio] = .notDetermined
        }

        // Use TCC SPI to request permission - this adds the app to System Settings
        guard let requestFunc = Self.tccRequestSPI else {
            // TCC SPI not available - fall back to opening System Settings
            await MainActor.run {
                statuses[.systemAudio] = .denied
                openSystemSettings(for: .systemAudio)
            }
            return
        }

        // Request permission via TCC SPI
        // This will show the system permission dialog and add the app to
        // "System Audio Recording Only" in System Settings
        requestFunc("kTCCServiceAudioCapture" as CFString, nil) { [weak self] granted in
            Task { @MainActor in
                guard let self else { return }
                if granted {
                    UserDefaults.standard.set(true, forKey: "systemAudioPermissionGranted")
                    self.statuses[.systemAudio] = .granted
                } else {
                    self.statuses[.systemAudio] = .denied
                    // Open System Settings so user can toggle it manually
                    self.openSystemSettings(for: .systemAudio)
                }
            }
        }
    }

    // MARK: - TCC SPI (Private Framework)

    private typealias TCCPreflightFuncType = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias TCCRequestFuncType = @convention(c) (CFString, CFDictionary?, @escaping (Bool) -> Void) -> Void

    /// Handle to the TCC private framework
    private static let tccHandle: UnsafeMutableRawPointer? = {
        let path = "/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC"
        return dlopen(path, RTLD_NOW)
    }()

    /// TCCAccessPreflight function pointer
    private static let tccPreflightSPI: TCCPreflightFuncType? = {
        guard let handle = tccHandle else { return nil }
        guard let sym = dlsym(handle, "TCCAccessPreflight") else { return nil }
        return unsafeBitCast(sym, to: TCCPreflightFuncType.self)
    }()

    /// TCCAccessRequest function pointer
    private static let tccRequestSPI: TCCRequestFuncType? = {
        guard let handle = tccHandle else { return nil }
        guard let sym = dlsym(handle, "TCCAccessRequest") else { return nil }
        return unsafeBitCast(sym, to: TCCRequestFuncType.self)
    }()

    /// Check system audio permission status using TCC SPI
    private func checkSystemAudioWithTCC() -> PermissionStatus {
        guard let preflight = Self.tccPreflightSPI else {
            // TCC SPI not available
            return .notDetermined
        }

        let result = preflight("kTCCServiceAudioCapture" as CFString, nil)
        // TCC returns: 0 = authorized, 1 = denied, 2 = not determined
        switch result {
        case 0: return .granted
        case 1: return .denied
        default: return .notDetermined
        }
    }

    private func currentAccessibilityStatus() -> PermissionStatus {
        AXIsProcessTrusted() ? .granted : .denied
    }
}
