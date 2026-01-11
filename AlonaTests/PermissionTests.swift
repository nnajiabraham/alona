import Foundation
import XCTest
@testable import Alona

// MARK: - Permission Manager Tests

@MainActor
final class PermissionManagerTests: XCTestCase {
    /// Check if running in test host with minimal permissions (CI environment)
    /// XCTest runs in a hosted app context - check if the app is in test mode
    private var isRunningInCIEnvironment: Bool {
        // When XCTestConfigurationFilePath is set, we're in a hosted test context
        // Combined with skipRefresh being needed, we assume CI
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    /// Verify PermissionManager initializes without blocking.
    /// Uses skipRefresh to avoid AppleScript on CI.
    func testPermissionManagerInitializesWithSkipRefresh() {
        // Use skipRefresh: true which is safe everywhere
        let manager = PermissionManager(skipRefresh: true)

        // All statuses should be notDetermined since we skipped refresh
        XCTAssertEqual(manager.statuses[.microphone], .notDetermined)
        XCTAssertEqual(manager.statuses[.systemAudio], .notDetermined)
        XCTAssertEqual(manager.statuses[.accessibility], .notDetermined)
        XCTAssertEqual(manager.statuses[.automation], .notDetermined)
    }

    /// Verify PermissionManager status types are valid.
    func testPermissionStatusDisplayNames() {
        XCTAssertEqual(PermissionManager.PermissionStatus.granted.displayName, "Granted")
        XCTAssertEqual(PermissionManager.PermissionStatus.denied.displayName, "Denied")
        XCTAssertEqual(PermissionManager.PermissionStatus.notDetermined.displayName, "Not Determined")
    }

    /// Verify permission types have correct metadata.
    func testPermissionTypeMetadata() {
        // Test titles
        XCTAssertEqual(PermissionManager.PermissionType.microphone.title, "Microphone")
        XCTAssertEqual(PermissionManager.PermissionType.systemAudio.title, "System Audio Recording")
        XCTAssertEqual(PermissionManager.PermissionType.accessibility.title, "Accessibility")
        XCTAssertEqual(PermissionManager.PermissionType.automation.title, "Automation")

        // Test that settings URLs are valid
        for type in PermissionManager.PermissionType.allCases {
            XCTAssertNotNil(type.settingsURL, "\(type.title) should have a settings URL")
        }
    }
}

// MARK: - TCC SPI Tests

final class TCCSPITests: XCTestCase {
    func testTCCFrameworkCanBeLoaded() {
        // Verify that we can load the TCC private framework
        let tccPath = "/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC"
        let handle = dlopen(tccPath, RTLD_NOW)

        // TCC framework should be loadable on macOS
        XCTAssertNotNil(handle, "TCC framework should be loadable")

        if let handle {
            dlclose(handle)
        }
    }

    func testTCCPreflightFunctionExists() {
        // Verify that TCCAccessPreflight function can be found
        let tccPath = "/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC"
        guard let handle = dlopen(tccPath, RTLD_NOW) else {
            XCTFail("Failed to load TCC framework")
            return
        }
        defer { dlclose(handle) }

        let preflightSym = dlsym(handle, "TCCAccessPreflight")
        XCTAssertNotNil(preflightSym, "TCCAccessPreflight function should exist")
    }

    func testTCCRequestFunctionExists() {
        // Verify that TCCAccessRequest function can be found
        let tccPath = "/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC"
        guard let handle = dlopen(tccPath, RTLD_NOW) else {
            XCTFail("Failed to load TCC framework")
            return
        }
        defer { dlclose(handle) }

        let requestSym = dlsym(handle, "TCCAccessRequest")
        XCTAssertNotNil(requestSym, "TCCAccessRequest function should exist")
    }

    @MainActor
    func testPermissionManagerSystemAudioStatusInitializes() {
        // Use skipRefresh: true for CI safety, then manually verify
        // that system audio status check code path works
        let manager = PermissionManager(skipRefresh: true)

        // Initial status should be notDetermined (since we skipped refresh)
        let status = manager.statuses[.systemAudio]
        XCTAssertEqual(status, .notDetermined, "System audio status should be notDetermined when skipRefresh")

        // Status should be one of the valid types
        let validStatuses: [PermissionManager.PermissionStatus] = [.granted, .denied, .notDetermined]
        if let status {
            XCTAssertTrue(validStatuses.contains(status), "Status should be a valid permission status")
        }
    }
}
