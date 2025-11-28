@testable import Alona
import Combine
import XCTest

@MainActor
final class AlonaTests: XCTestCase {
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

    func testAudioSampleMathDownmix() {
        let mono = AudioSampleMath.averagedMono(system: [1.0, -1.0, 0.0], mic: [-1.0, 1.0, 0.0])
        XCTAssertEqual(mono, [0.0, 0.0, 0.0])
    }

    func testNotesDraftDefaultsEmpty() {
        let appState = AppState()
        XCTAssertEqual(appState.notesDraft, "")
        appState.notesDraft = "Meeting notes"
        XCTAssertEqual(appState.notesDraft, "Meeting notes")
    }

    @MainActor
    func testNotesAutosaveAndFinalize() async throws {
        let harness = try MeetingFileManagerTestHarness()
        defer { harness.cleanup() }

        let directory = try harness.manager.createMeetingDirectory(title: "Autosave")
        let recorder = MockAudioRecorder(directory: directory)

        let appState = AppState(
            meetingFileManager: harness.manager,
            audioRecorder: recorder,
            notesAutosaveInterval: 0.05,
            notesAutosaveScheduler: .main
        )

        await appState.startRecording(meetingTitleOverride: "Autosave")
        appState.notesDraft = "Autosaved text"

        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(harness.manager.recoverNotesFromTemp(in: directory), "Autosaved text")

        await appState.stopRecording()

        let savedNotes = try String(contentsOf: directory.appendingPathComponent("notes.md"))
        XCTAssertEqual(savedNotes, "Autosaved text")
        XCTAssertNil(harness.manager.recoverNotesFromTemp(in: directory))
    }

    func testNotesInsertionAppendsWhenNoSelection() {
        let result = NotesInsertion.inserting(snippet: "• ", in: "Hello", range: NSRange(location: 5, length: 0))
        XCTAssertEqual(result.text, "Hello• ")
        XCTAssertEqual(result.range.location, 7)
    }

    func testNotesInsertionReplacesSelection() {
        let result = NotesInsertion.inserting(snippet: "[00:05] ", in: "Hello world", range: NSRange(location: 6, length: 5))
        XCTAssertEqual(result.text, "Hello [00:05] ")
        XCTAssertEqual(result.range.location, 14)
    }

    @MainActor
    func testRecordingRequestsNotesWindow() async throws {
        let harness = try MeetingFileManagerTestHarness()
        defer { harness.cleanup() }

        let directory = try harness.manager.createMeetingDirectory(title: "Window")
        let recorder = MockAudioRecorder(directory: directory)
        let appState = AppState(meetingFileManager: harness.manager, audioRecorder: recorder)

        XCTAssertNil(appState.notesWindowRequestID)
        await appState.startRecording(meetingTitleOverride: "Window")
        XCTAssertNotNil(appState.notesWindowRequestID)
    }

    func testMeetingEntriesLoadedInDescendingOrder() throws {
        let harness = try MeetingFileManagerTestHarness()
        defer { harness.cleanup() }

        let older = try harness.manager.createMeetingDirectory(title: "Older", date: Date(timeIntervalSince1970: 100))
        try "Old notes".write(to: older.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)

        let newer = try harness.manager.createMeetingDirectory(title: "Newer", date: Date(timeIntervalSince1970: 200))
        try "New notes".write(to: newer.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
        try "Transcript".write(to: newer.appendingPathComponent("transcript.txt"), atomically: true, encoding: .utf8)

        let entries = harness.manager.meetingEntries()
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.first?.title.contains("Newer"), true)
        XCTAssertEqual(harness.manager.loadNotes(from: newer), "New notes")
        XCTAssertEqual(harness.manager.loadTranscript(from: newer), "Transcript")
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

// MARK: - Mocks

final class MockAudioRecorder: AudioRecordingController {
    private let directory: URL
    private let isRecordingSubject = CurrentValueSubject<Bool, Never>(false)
    private let durationSubject = CurrentValueSubject<TimeInterval, Never>(0)

    init(directory: URL) {
        self.directory = directory
    }

    var isRecordingPublisher: AnyPublisher<Bool, Never> {
        isRecordingSubject.eraseToAnyPublisher()
    }

    var recordingDurationPublisher: AnyPublisher<TimeInterval, Never> {
        durationSubject.eraseToAnyPublisher()
    }

    func startRecording(meetingTitle _: String) async throws -> URL {
        isRecordingSubject.send(true)
        return directory
    }

    func stopRecording() async {
        isRecordingSubject.send(false)
    }
}
