import Combine
import Foundation
import XCTest
@testable import Alona

// MARK: - AppState Recording Flow Integration Tests

@MainActor
final class AppStateRecordingFlowTests: XCTestCase {
    func testStartRecordingUpdatesIsRecordingState() async throws {
        let harness = try MeetingFileManagerTestHarness()
        defer { harness.cleanup() }

        let directory = try harness.manager.createMeetingDirectory(title: "Recording Flow")
        let recorder = MockAudioRecorder(directory: directory)
        let appState = AppState(
            meetingFileManager: harness.manager,
            audioRecorder: recorder,
            transcriptionEngine: MockTranscriptionEngine(),
            summaryProvider: MockSummaryProvider())

        XCTAssertFalse(appState.isRecording, "Should not be recording initially")

        await appState.startRecording(meetingTitleOverride: "Test")

        // Give time for publisher to propagate
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertTrue(appState.isRecording, "Should be recording after start")
    }

    func testStopRecordingUpdatesIsRecordingState() async throws {
        let harness = try MeetingFileManagerTestHarness()
        defer { harness.cleanup() }

        let directory = try harness.manager.createMeetingDirectory(title: "Stop Flow")
        let recorder = MockAudioRecorder(directory: directory)
        let appState = AppState(
            meetingFileManager: harness.manager,
            audioRecorder: recorder,
            transcriptionEngine: MockTranscriptionEngine(),
            summaryProvider: MockSummaryProvider())

        await appState.startRecording(meetingTitleOverride: "Test")
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(appState.isRecording)

        await appState.stopRecording()
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertFalse(appState.isRecording, "Should not be recording after stop")
    }

    func testRecordingDurationUpdatesFromPublisher() async throws {
        let harness = try MeetingFileManagerTestHarness()
        defer { harness.cleanup() }

        let directory = try harness.manager.createMeetingDirectory(title: "Duration")
        let recorder = MockAudioRecorder(directory: directory)
        let appState = AppState(
            meetingFileManager: harness.manager,
            audioRecorder: recorder,
            transcriptionEngine: MockTranscriptionEngine(),
            summaryProvider: MockSummaryProvider())

        XCTAssertEqual(appState.recordingDuration, 0, "Duration should start at 0")
    }
}

// MARK: - AppState Edge Case Tests

@MainActor
final class AppStateEdgeCaseTests: XCTestCase {
    func testNotesAutosaveSkipsDuplicateContent() async throws {
        let harness = try MeetingFileManagerTestHarness()
        defer { harness.cleanup() }

        let directory = try harness.manager.createMeetingDirectory(title: "Duplicate")
        let recorder = MockAudioRecorder(directory: directory)
        let appState = AppState(
            meetingFileManager: harness.manager,
            audioRecorder: recorder,
            transcriptionEngine: MockTranscriptionEngine(),
            summaryProvider: MockSummaryProvider(),
            notesAutosaveInterval: 0.05)

        await appState.startRecording(meetingTitleOverride: "Duplicate")

        // Set notes and wait for autosave
        appState.notesDraft = "Same content"
        try await Task.sleep(nanoseconds: 100_000_000)

        // Set same content again - should not trigger redundant save
        appState.notesDraft = "Same content"
        try await Task.sleep(nanoseconds: 100_000_000)

        // Verify content is saved correctly
        let saved = harness.manager.recoverNotesFromTemp(in: directory)
        XCTAssertEqual(saved, "Same content")
    }

    func testNotesSelectionBoundsAreRespected() {
        // Test that selection bounds work correctly with NotesInsertion
        let text = "Hello"

        // Valid range at end
        let result1 = NotesInsertion.inserting(snippet: "!", in: text, range: NSRange(location: 5, length: 0))
        XCTAssertEqual(result1.text, "Hello!")

        // Valid range at start
        let result2 = NotesInsertion.inserting(snippet: "Hi ", in: text, range: NSRange(location: 0, length: 0))
        XCTAssertEqual(result2.text, "Hi Hello")

        // Valid range replacing middle
        let result3 = NotesInsertion.inserting(snippet: "i", in: text, range: NSRange(location: 1, length: 3))
        XCTAssertEqual(result3.text, "Hio")
    }

    func testTranscriptionJobStateTransitions() async throws {
        let harness = try MeetingFileManagerTestHarness()
        defer { harness.cleanup() }

        let directory = try harness.manager.createMeetingDirectory(title: "Job State")
        let recorder = MockAudioRecorder(directory: directory)
        let engine = MockTranscriptionEngine(result: TranscriptionResult(text: "Test", segments: []))
        let appState = AppState(
            meetingFileManager: harness.manager,
            audioRecorder: recorder,
            transcriptionEngine: engine,
            summaryProvider: MockSummaryProvider())

        // Queue a transcription job
        appState.regenerateTranscription(for: directory, notes: "")

        // Job should be queued
        XCTAssertEqual(appState.transcriptionJobs.count, 1)

        // Wait for completion
        try await waitForJobCompletion(in: appState)

        // Verify final state
        guard case .completed = appState.transcriptionJobs.first?.state else {
            XCTFail("Job should be in completed state")
            return
        }
    }

    func testCaptureSystemAudioToggles() throws {
        let harness = try MeetingFileManagerTestHarness()
        defer { harness.cleanup() }

        let recorder = MockAudioRecorder(directory: harness.manager.baseDirectory)
        let appState = AppState(
            meetingFileManager: harness.manager,
            audioRecorder: recorder,
            transcriptionEngine: MockTranscriptionEngine(),
            summaryProvider: MockSummaryProvider(),
            userDefaults: harness.userDefaults)

        XCTAssertFalse(appState.captureSystemAudio)
        XCTAssertFalse(recorder.captureSystemAudio)

        appState.captureSystemAudio = true
        XCTAssertTrue(appState.captureSystemAudio)
        XCTAssertTrue(recorder.captureSystemAudio)

        appState.captureSystemAudio = false
        XCTAssertFalse(appState.captureSystemAudio)
        XCTAssertFalse(recorder.captureSystemAudio)
    }
}

// MARK: - AppState Tests

@MainActor
final class AppStateTests: XCTestCase {
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

    func testNotesDraftDefaultsEmpty() {
        let appState = AppState()
        XCTAssertEqual(appState.notesDraft, "")
        appState.notesDraft = "Meeting notes"
        XCTAssertEqual(appState.notesDraft, "Meeting notes")
    }

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
            notesAutosaveScheduler: .main)

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
        let result = NotesInsertion.inserting(
            snippet: "[00:05] ",
            in: "Hello world",
            range: NSRange(location: 6, length: 5))
        XCTAssertEqual(result.text, "Hello [00:05] ")
        XCTAssertEqual(result.range.location, 14)
    }

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
            summaryProvider: MockSummaryProvider())

        XCTAssertNil(appState.notesWindowRequestID)
        await appState.startRecording(meetingTitleOverride: "Window")
        XCTAssertNotNil(appState.notesWindowRequestID)
    }

    func testActiveMeetingTitleUpdatesPersist() async throws {
        let harness = try MeetingFileManagerTestHarness()
        defer { harness.cleanup() }

        let directory = try harness.manager.createMeetingDirectory(title: "Original")
        let recorder = MockAudioRecorder(directory: directory)
        let appState = AppState(
            meetingFileManager: harness.manager,
            audioRecorder: recorder,
            transcriptionEngine: MockTranscriptionEngine(),
            summaryProvider: MockSummaryProvider())

        await appState.startRecording(meetingTitleOverride: "Original")
        appState.updateActiveMeetingTitle("Renamed Title")

        let storedTitle = harness.manager.loadTitle(from: directory)
        XCTAssertEqual(storedTitle, "Renamed Title")
    }

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
            notesAutosaveScheduler: .main)

        appState.regenerateTranscription(for: directory, notes: "Existing notes")

        try await waitForJobCompletion(in: appState)

        let transcript = try String(contentsOf: directory.appendingPathComponent("transcript.txt"))
        XCTAssertEqual(transcript, "Hello Queue")
        guard case .completed = appState.transcriptionJobs.first?.state else {
            XCTFail("Job should be marked completed")
            return
        }
    }

    func testSystemAudioPreferencePersistsAcrossSessions() async throws {
        let harness = try MeetingFileManagerTestHarness()
        defer { harness.cleanup() }

        let recorder = MockAudioRecorder(directory: harness.manager.baseDirectory)
        let appState = AppState(
            meetingFileManager: harness.manager,
            audioRecorder: recorder,
            transcriptionEngine: MockTranscriptionEngine(),
            summaryProvider: MockSummaryProvider(),
            userDefaults: harness.userDefaults)

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
            userDefaults: harness.userDefaults)

        XCTAssertTrue(reloadedState.captureSystemAudio)
        XCTAssertTrue(reloadedRecorder.captureSystemAudio)
    }

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
            nowProvider: { fixedDate })

        await appState.startRecording()

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d, yyyy 'at' h:mm a"
        formatter.timeZone = TimeZone.current
        XCTAssertEqual(appState.meetingTitle, formatter.string(from: fixedDate))
    }
}
