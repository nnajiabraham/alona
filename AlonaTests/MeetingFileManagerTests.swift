import Foundation
import XCTest
@testable import Alona

@MainActor
final class MeetingFileManagerTests: XCTestCase {
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

    func testMeetingFileManagerRecordingAudioURLPrefersRecordingWav() throws {
        let harness = try MeetingFileManagerTestHarness()
        defer { harness.cleanup() }

        let directory = try harness.manager.createMeetingDirectory(title: "Audio URL")
        let mono = directory.appendingPathComponent("recording-mono.wav")
        let preferred = directory.appendingPathComponent("recording.wav")

        try Data([0x00, 0x01]).write(to: mono)
        XCTAssertEqual(harness.manager.recordingAudioURL(in: directory), mono)

        try Data([0x02, 0x03]).write(to: preferred)
        XCTAssertEqual(harness.manager.recordingAudioURL(in: directory), preferred)
    }
}

// MARK: - MeetingFileManager Edge Case Tests

@MainActor
final class MeetingFileManagerEdgeCaseTests: XCTestCase {
    func testMeetingDirectoryWithSpecialCharactersInTitle() throws {
        let harness = try MeetingFileManagerTestHarness()
        defer { harness.cleanup() }

        // Test various special characters that should be sanitized
        let directory = try harness.manager.createMeetingDirectory(title: "Test: Meeting / Review (2024)")
        let name = directory.lastPathComponent

        // Should not contain problematic characters
        XCTAssertFalse(name.contains("/"), "Should not contain forward slash")
        XCTAssertFalse(name.contains(":"), "Should not contain colon")
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path), "Directory should exist")
    }

    func testMeetingDirectoryWithVeryLongTitle() throws {
        let harness = try MeetingFileManagerTestHarness()
        defer { harness.cleanup() }

        // Create a very long title
        let longTitle = String(repeating: "A", count: 300)
        let directory = try harness.manager.createMeetingDirectory(title: longTitle)

        // Should create directory successfully (filename may be truncated)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path), "Directory should exist")

        // Save and verify title is preserved correctly
        try harness.manager.saveTitle(longTitle, to: directory)
        let loadedTitle = harness.manager.loadTitle(from: directory)
        XCTAssertEqual(loadedTitle, longTitle, "Full title should be preserved in metadata")
    }

    func testMeetingDirectoryWithEmptyTitle() throws {
        let harness = try MeetingFileManagerTestHarness()
        defer { harness.cleanup() }

        let directory = try harness.manager.createMeetingDirectory(title: "")

        // Should still create a valid directory
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path), "Directory should exist")
    }

    func testMeetingDirectoryWithUnicodeTitle() throws {
        let harness = try MeetingFileManagerTestHarness()
        defer { harness.cleanup() }

        let unicodeTitle = "会议 Meeting 🎉 Réunion"
        let directory = try harness.manager.createMeetingDirectory(title: unicodeTitle)

        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path), "Directory should exist")

        try harness.manager.saveTitle(unicodeTitle, to: directory)
        let loadedTitle = harness.manager.loadTitle(from: directory)
        XCTAssertEqual(loadedTitle, unicodeTitle, "Unicode title should be preserved")
    }

    func testLoadNotesReturnsNilForMissingFile() throws {
        let harness = try MeetingFileManagerTestHarness()
        defer { harness.cleanup() }

        let directory = try harness.manager.createMeetingDirectory(title: "No Notes")

        // Don't create notes.md file
        let notes = harness.manager.loadNotes(from: directory)
        XCTAssertNil(notes, "Should return nil for missing notes file")
    }

    func testLoadTranscriptReturnsNilForMissingFile() throws {
        let harness = try MeetingFileManagerTestHarness()
        defer { harness.cleanup() }

        let directory = try harness.manager.createMeetingDirectory(title: "No Transcript")

        // Don't create transcript.txt file
        let transcript = harness.manager.loadTranscript(from: directory)
        XCTAssertNil(transcript, "Should return nil for missing transcript file")
    }

    func testMeetingEntriesWithMissingMetadataFiles() throws {
        let harness = try MeetingFileManagerTestHarness()
        defer { harness.cleanup() }

        // Create directory but don't add any metadata files
        let directory = try harness.manager.createMeetingDirectory(title: "Bare")

        let entries = harness.manager.meetingEntries()

        // Should still list the entry (using directory name as fallback title)
        XCTAssertEqual(entries.count, 1)
        XCTAssertNotNil(entries.first?.title)
    }

    func testRecoverNotesFromTempReturnsNilWhenNoTemp() throws {
        let harness = try MeetingFileManagerTestHarness()
        defer { harness.cleanup() }

        let directory = try harness.manager.createMeetingDirectory(title: "No Temp")

        let recovered = harness.manager.recoverNotesFromTemp(in: directory)
        XCTAssertNil(recovered, "Should return nil when no temp file exists")
    }
}
