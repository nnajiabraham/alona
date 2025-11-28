@testable import Alona
import XCTest

@MainActor
final class AlonaTests: XCTestCase {
    func testAppStateToggle() {
        let appState = AppState()
        XCTAssertFalse(appState.isRecording)
        appState.toggleRecording()
        XCTAssertTrue(appState.isRecording)
    }

    func testPermissionStatusDisplayNames() {
        XCTAssertEqual(PermissionManager.PermissionStatus.granted.displayName, "Granted")
        XCTAssertEqual(PermissionManager.PermissionStatus.denied.displayName, "Denied")
        XCTAssertEqual(PermissionManager.PermissionStatus.notDetermined.displayName, "Not Determined")
    }
}
