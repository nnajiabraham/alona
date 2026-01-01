import Foundation
import XCTest
@testable import Alona

// MARK: - Permission Manager Tests

@MainActor
final class PermissionManagerTests: XCTestCase {
    /// Verify PermissionManager.refreshAllPermissions returns immediately.
    /// Automation check runs asynchronously.
    func testPermissionManagerRefreshDoesNotBlock() {
        let manager = PermissionManager()

        let start = CFAbsoluteTimeGetCurrent()
        manager.refreshAllPermissions()
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        // refreshAllPermissions should return almost immediately (< 50ms)
        // AppleScript for automation check takes 500ms+ if run synchronously
        XCTAssertLessThan(elapsed, 0.05, "refreshAllPermissions should not block main thread")
    }

    /// Verify that automation check runs asynchronously and eventually completes.
    /// Note: In test sandbox, the result may be denied or the check may not complete.
    func testAutomationCheckRunsAsynchronously() async {
        let manager = PermissionManager()

        // Initial state should be notDetermined
        XCTAssertEqual(manager.statuses[.automation], .notDetermined)

        // Trigger refresh - this should return immediately
        let start = CFAbsoluteTimeGetCurrent()
        manager.refreshAllPermissions()
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        // Refresh should return quickly (automation check is async)
        XCTAssertLessThan(elapsed, 0.05, "refreshAllPermissions should return immediately")

        // Give async task time to complete
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second

        // After waiting, status may have changed (we don't assert the value
        // since test environment may not allow AppleScript execution)
        // The key test is that refreshAllPermissions returned immediately above
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
    func testPermissionManagerSystemAudioStatusCheck() {
        // Verify that PermissionManager can check system audio status
        let manager = PermissionManager()

        // The status should be one of the valid states
        let status = manager.statuses[.systemAudio]
        XCTAssertNotNil(status, "System audio status should be populated")

        // Status should be one of: granted, denied, or notDetermined
        if let status {
            let validStatuses: [PermissionManager.PermissionStatus] = [.granted, .denied, .notDetermined]
            XCTAssertTrue(validStatuses.contains(status), "Status should be a valid permission status")
        }
    }
}
