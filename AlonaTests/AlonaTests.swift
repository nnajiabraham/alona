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

    func testMeetingTitleNormalization() {
        let trimmed = MeetingDetector.normalizeMeetingTitle("Team Sync - Google Meet  ")
        XCTAssertEqual(trimmed, "Team Sync")

        let fallback = MeetingDetector.normalizeMeetingTitle("   ")
        XCTAssertEqual(fallback, "Google Meet")
    }

    func testMeetingDirectorySlugAndCollision() throws {
        let harness = try MeetingFileManagerTestHarness()
        defer { harness.cleanup() }

        let manager = harness.manager
        let fixedDate = Date(timeIntervalSince1970: 1_730_000_000) // deterministic timestamp

        let first = try manager.createMeetingDirectory(title: "Kickoff / Phase:1", date: fixedDate)
        XCTAssertTrue(first.lastPathComponent.contains("Kickoff-Phase-1"))

        let second = try manager.createMeetingDirectory(title: "Kickoff / Phase:1", date: fixedDate)
        XCTAssertTrue(second.lastPathComponent.hasSuffix("-1"))
    }

    func testNotesDraftPersistence() throws {
        let harness = try MeetingFileManagerTestHarness()
        defer { harness.cleanup() }

        let manager = harness.manager
        let directory = try manager.createMeetingDirectory(title: "Notes Test")

        try manager.saveNotesDraft("Draft text", to: directory)
        XCTAssertEqual(manager.recoverNotesFromTemp(in: directory), "Draft text")

        try manager.saveNotes("Final text", to: directory)
        let notesURL = directory.appendingPathComponent("notes.md")
        let saved = try String(contentsOf: notesURL)
        XCTAssertEqual(saved, "Final text")

        let tempURL = directory.appendingPathComponent("notes.tmp")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempURL.path))
    }

    func testTranscriptPersistsJSONAndText() throws {
        let harness = try MeetingFileManagerTestHarness()
        defer { harness.cleanup() }

        let manager = harness.manager
        let directory = try manager.createMeetingDirectory(title: "Transcript Test")

        let segments = [
            TranscriptionSegment(startTime: 0, endTime: 5, text: "Hello"),
            TranscriptionSegment(startTime: 5, endTime: 10, text: "World"),
        ]
        let result = TranscriptionResult(text: "Hello World", segments: segments)

        try manager.saveTranscript(result, to: directory)

        let transcriptText = try String(contentsOf: directory.appendingPathComponent("transcript.txt"))
        XCTAssertEqual(transcriptText, "Hello World")

        let jsonData = try Data(contentsOf: directory.appendingPathComponent("transcript.json"))
        let records = try JSONDecoder().decode([TranscriptSegmentRecord].self, from: jsonData)
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records.first?.text, "Hello")
        XCTAssertEqual(records.last?.end, 10)
    }

    func testAppStateUpdatesSaveDirectory() throws {
        let harness = try MeetingFileManagerTestHarness()
        defer { harness.cleanup() }

        let appState = AppState(meetingFileManager: harness.manager)
        XCTAssertEqual(appState.saveDirectory, harness.baseDirectory)

        let customDir = harness.baseDirectory.appendingPathComponent("Custom", isDirectory: true)
        try FileManager.default.createDirectory(at: customDir, withIntermediateDirectories: true)

        appState.updateSaveDirectory(customDir)
        XCTAssertEqual(harness.manager.baseDirectory, customDir)
        XCTAssertEqual(appState.saveDirectory, customDir)
    }

    func testDetectionDismissalReset() throws {
        let harness = try MeetingFileManagerTestHarness()
        defer { harness.cleanup() }

        let appState = AppState(meetingFileManager: harness.manager)
        appState.dismissDetection(identifier: "zoom|123")
        XCTAssertEqual(appState.dismissedDetectionIdentifier, "zoom|123")

        appState.resetDetectionDismissalIfNeeded(for: "zoom|123")
        XCTAssertEqual(appState.dismissedDetectionIdentifier, "zoom|123")

        appState.resetDetectionDismissalIfNeeded(for: "meet|456")
        XCTAssertNil(appState.dismissedDetectionIdentifier)
    }
}

// MARK: - Test Harness

private struct MeetingFileManagerTestHarness {
    let manager: MeetingFileManager
    let baseDirectory: URL
    let userDefaults: UserDefaults
    private let defaultsSuiteName: String

    init() throws {
        baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingFileManagerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)

        defaultsSuiteName = "MeetingFileManagerTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: defaultsSuiteName) else {
            throw NSError(domain: "MeetingFileManagerTests", code: -1)
        }
        defaults.removePersistentDomain(forName: defaultsSuiteName)

        userDefaults = defaults
        manager = MeetingFileManager(fileManager: .default, userDefaults: defaults)
        manager.baseDirectory = baseDirectory
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: baseDirectory)
        userDefaults.removePersistentDomain(forName: defaultsSuiteName)
    }
}
