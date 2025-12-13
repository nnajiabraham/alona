@testable import Alona
import AppKit
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
        let transcriptionResult = TranscriptionResult(text: "transcript text", segments: [])
        let transcriptionEngine = MockTranscriptionEngine(result: transcriptionResult)
        let summaryProvider = MockSummaryProvider(output: "SUMMARY")

        let appState = AppState(
            meetingFileManager: harness.manager,
            audioRecorder: recorder,
            transcriptionEngine: transcriptionEngine,
            summaryProvider: summaryProvider,
            notesAutosaveInterval: 0.05,
            notesAutosaveScheduler: .main
        )

        await appState.startRecording(meetingTitleOverride: "Autosave")
        appState.notesDraft = "Autosaved text"

        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(harness.manager.recoverNotesFromTemp(in: directory), "Autosaved text")

        await appState.stopRecording()
        try await waitForJobCompletion(in: appState)

        let savedNotes = try String(contentsOf: directory.appendingPathComponent("notes.md"))
        XCTAssertEqual(savedNotes, "Autosaved text")
        XCTAssertNil(harness.manager.recoverNotesFromTemp(in: directory))

        let summary = try String(contentsOf: directory.appendingPathComponent("summary.md"))
        XCTAssertEqual(summary, "SUMMARY")
        let transcript = try String(contentsOf: directory.appendingPathComponent("transcript.txt"))
        XCTAssertEqual(transcript, "transcript text")
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
        let transcriptionEngine = MockTranscriptionEngine()
        let appState = AppState(
            meetingFileManager: harness.manager,
            audioRecorder: recorder,
            transcriptionEngine: transcriptionEngine,
            summaryProvider: MockSummaryProvider()
        )

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

    func testMeetingEntriesUseSavedTitles() throws {
        let harness = try MeetingFileManagerTestHarness()
        defer { harness.cleanup() }

        let directory = try harness.manager.createMeetingDirectory(title: "Original")
        try harness.manager.saveTitle("Custom Title", to: directory)

        let entries = harness.manager.meetingEntries()
        XCTAssertEqual(entries.first?.title, "Custom Title")
    }

    @MainActor
    func testActiveMeetingTitleUpdatesPersist() async throws {
        let harness = try MeetingFileManagerTestHarness()
        defer { harness.cleanup() }

        let directory = try harness.manager.createMeetingDirectory(title: "Original")
        let recorder = MockAudioRecorder(directory: directory)
        let appState = AppState(
            meetingFileManager: harness.manager,
            audioRecorder: recorder,
            transcriptionEngine: MockTranscriptionEngine(),
            summaryProvider: MockSummaryProvider()
        )

        await appState.startRecording(meetingTitleOverride: "Original")
        appState.updateActiveMeetingTitle("Renamed Title")

        let storedTitle = harness.manager.loadTitle(from: directory)
        XCTAssertEqual(storedTitle, "Renamed Title")
    }

    func testModelLocatorRespectsOverriddenSupportDirectory() throws {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelLocator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        ModelLocator.applicationSupportDirectoryProvider = { tempBase }
        defer {
            ModelLocator.resetForTesting()
            try? FileManager.default.removeItem(at: tempBase)
        }

        let modelsDir = try ModelLocator.userModelsDirectory()
        XCTAssertTrue(modelsDir.path.hasPrefix(tempBase.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: modelsDir.path))
    }

    func testModelLocatorPrefersUserModelOverBundle() throws {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelLocatorUser-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        ModelLocator.applicationSupportDirectoryProvider = { tempBase }
        defer {
            ModelLocator.resetForTesting()
            try? FileManager.default.removeItem(at: tempBase)
        }

        let userURL = try ModelLocator.userModelURL()
        FileManager.default.createFile(atPath: userURL.path, contents: Data("user".utf8))
        let resolved = ModelLocator.existingModelURL()
        XCTAssertEqual(resolved, userURL)
    }

    @MainActor
    func testManualTranscriptionQueueProcesses() async throws {
        let harness = try MeetingFileManagerTestHarness()
        defer { harness.cleanup() }

        let directory = try harness.manager.createMeetingDirectory(title: "Queue")
        try "Existing notes".write(to: directory.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)

        let recorder = MockAudioRecorder(directory: directory)
        let engine = MockTranscriptionEngine(result: TranscriptionResult(text: "Hello Queue", segments: []))
        let summaryProvider = MockSummaryProvider(output: "Queued summary")
        let appState = AppState(
            meetingFileManager: harness.manager,
            audioRecorder: recorder,
            transcriptionEngine: engine,
            summaryProvider: summaryProvider,
            notesAutosaveInterval: 0.05,
            notesAutosaveScheduler: .main
        )

        appState.regenerateTranscription(for: directory, notes: "Existing notes")

        try await waitForJobCompletion(in: appState)

        let transcript = try String(contentsOf: directory.appendingPathComponent("transcript.txt"))
        XCTAssertEqual(transcript, "Hello Queue")
        guard case .completed = appState.transcriptionJobs.first?.state else {
            XCTFail("Job should be marked completed")
            return
        }
    }

    func testMeetingDetectorNotifiesOncePerMeeting() {
        let scheduler = MockMeetingNotificationScheduler()
        let detector = MeetingDetector(notificationScheduler: scheduler)

        detector.handleDetection(app: .zoom, meetingTitle: "Daily Sync")
        detector.handleDetection(app: .zoom, meetingTitle: "Daily Sync")
        XCTAssertEqual(scheduler.requests.count, 1)

        #if DEBUG
            detector.resetDetectionStateForTesting()
        #endif

        detector.handleDetection(app: .zoom, meetingTitle: "Daily Sync")
        XCTAssertEqual(scheduler.requests.count, 2)
    }

    @MainActor
    func testSystemAudioPreferencePersistsAcrossSessions() async throws {
        let harness = try MeetingFileManagerTestHarness()
        defer { harness.cleanup() }

        let recorder = MockAudioRecorder(directory: harness.manager.baseDirectory)
        let appState = AppState(
            meetingFileManager: harness.manager,
            audioRecorder: recorder,
            transcriptionEngine: MockTranscriptionEngine(),
            summaryProvider: MockSummaryProvider(),
            userDefaults: harness.userDefaults
        )

        XCTAssertFalse(appState.captureSystemAudio)
        XCTAssertFalse(recorder.captureSystemAudio)

        appState.captureSystemAudio = true
        XCTAssertTrue(recorder.captureSystemAudio)

        let reloadedRecorder = MockAudioRecorder(directory: harness.manager.baseDirectory)
        let reloadedState = AppState(
            meetingFileManager: harness.manager,
            audioRecorder: reloadedRecorder,
            transcriptionEngine: MockTranscriptionEngine(),
            summaryProvider: MockSummaryProvider(),
            userDefaults: harness.userDefaults
        )

        XCTAssertTrue(reloadedState.captureSystemAudio)
        XCTAssertTrue(reloadedRecorder.captureSystemAudio)
    }

    @MainActor
    func testDefaultMeetingTitleFallsBackToTimestamp() async throws {
        let harness = try MeetingFileManagerTestHarness()
        defer { harness.cleanup() }

        let directory = try harness.manager.createMeetingDirectory(title: "Placeholder")
        let recorder = MockAudioRecorder(directory: directory)
        let fixedDate = Date(timeIntervalSince1970: 1_738_000_000) // deterministic
        let appState = AppState(
            meetingFileManager: harness.manager,
            audioRecorder: recorder,
            transcriptionEngine: MockTranscriptionEngine(),
            summaryProvider: MockSummaryProvider(),
            userDefaults: harness.userDefaults,
            nowProvider: { fixedDate }
        )

        await appState.startRecording()

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d, yyyy 'at' h:mm a"
        formatter.timeZone = TimeZone.current
        XCTAssertEqual(appState.meetingTitle, formatter.string(from: fixedDate))
    }

    func testStartupWindowControllerFindsExistingWindow() {
        let other = NSWindow()
        other.identifier = NSUserInterfaceItemIdentifier("other")
        let target = NSWindow()
        target.identifier = NSUserInterfaceItemIdentifier(StartupWindowController.identifier)

        let found = StartupWindowController.existingWindow(in: [other, target])
        XCTAssertTrue(found === target)
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

// MARK: - Helpers

@MainActor
private func waitForJobCompletion(in appState: AppState, timeout: TimeInterval = 2.0) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if case .completed = appState.transcriptionJobs.first?.state {
            return
        }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    XCTFail("Timed out waiting for transcription job completion")
}

// MARK: - Mocks

final class MockAudioRecorder: AudioRecordingController {
    private let directory: URL
    private let isRecordingSubject = CurrentValueSubject<Bool, Never>(false)
    private let durationSubject = CurrentValueSubject<TimeInterval, Never>(0)
    var captureSystemAudio: Bool = false

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

final class MockMeetingNotificationScheduler: MeetingNotificationScheduling {
    var requests: [String] = []

    func scheduleMeetingNotification(appName _: String, meetingTitle _: String, identifier: String) {
        requests.append(identifier)
    }
}

final class MockTranscriptionEngine: TranscriptionProcessing {
    private let subject = PassthroughSubject<Double, Never>()
    private let result: TranscriptionResult

    init(result: TranscriptionResult = TranscriptionResult(text: "", segments: [])) {
        self.result = result
    }

    var progressPublisher: AnyPublisher<Double, Never> {
        subject.eraseToAnyPublisher()
    }

    func transcribe(audioURL _: URL) async throws -> TranscriptionResult {
        subject.send(0.5)
        subject.send(1.0)
        subject.send(completion: .finished)
        return result
    }
}

struct MockSummaryProvider: SummaryProviding {
    let output: String

    init(output: String = "SUMMARY") {
        self.output = output
    }

    func generateSummary(transcript _: String, notes _: String) async throws -> String {
        output
    }
}
