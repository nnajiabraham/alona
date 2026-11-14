import Foundation
import XCTest
@testable import AlonaCore

// MARK: - SummaryManager Tests

final class SummaryManagerTests: XCTestCase {
    func testSummaryManagerDelegatesToProvider() async throws {
        let customProvider = TestSummaryProvider(output: "Custom Summary Output")
        let manager = SummaryManager(provider: customProvider)

        let result = try await manager.generateSummary(transcript: "transcript", notes: "notes")

        XCTAssertEqual(result, "Custom Summary Output")
        XCTAssertEqual(customProvider.callCount, 1)
        XCTAssertEqual(customProvider.lastTranscript, "transcript")
        XCTAssertEqual(customProvider.lastNotes, "notes")
    }

    func testSummaryManagerUsesDefaultProvider() async throws {
        // Default provider is PlaceholderSummaryProvider
        let manager = SummaryManager()

        let result = try await manager.generateSummary(transcript: "Hello world", notes: "My notes")

        // PlaceholderSummaryProvider returns markdown with specific structure
        XCTAssertTrue(result.contains("# Meeting Summary"), "Should contain heading")
        XCTAssertTrue(result.contains("Hello world"), "Should contain transcript snippet")
        XCTAssertTrue(result.contains("My notes"), "Should contain notes snippet")
    }
}

// MARK: - PlaceholderSummaryProvider Tests

final class PlaceholderSummaryProviderTests: XCTestCase {
    func testPlaceholderSummaryProviderFormatsOutput() async throws {
        let provider = PlaceholderSummaryProvider()

        let result = try await provider.generateSummary(transcript: "Test transcript", notes: "Test notes")

        XCTAssertTrue(result.contains("# Meeting Summary"))
        XCTAssertTrue(result.contains("## Highlights"))
        XCTAssertTrue(result.contains("## Notes Snapshot"))
        XCTAssertTrue(result.contains("## Next Steps"))
    }

    func testPlaceholderSummaryHandlesEmptyTranscript() async throws {
        let provider = PlaceholderSummaryProvider()

        let result = try await provider.generateSummary(transcript: "", notes: "Some notes")

        XCTAssertTrue(result.contains("*Transcript pending*"), "Should show pending message for empty transcript")
        XCTAssertTrue(result.contains("Some notes"))
    }

    func testPlaceholderSummaryHandlesEmptyNotes() async throws {
        let provider = PlaceholderSummaryProvider()

        let result = try await provider.generateSummary(transcript: "Some transcript", notes: "")

        XCTAssertTrue(result.contains("*No notes provided*"), "Should show message for empty notes")
        XCTAssertTrue(result.contains("Some transcript"))
    }

    func testPlaceholderSummaryHandlesBothEmpty() async throws {
        let provider = PlaceholderSummaryProvider()

        let result = try await provider.generateSummary(transcript: "", notes: "")

        XCTAssertTrue(result.contains("*Transcript pending*"))
        XCTAssertTrue(result.contains("*No notes provided*"))
    }

    func testPlaceholderSummaryTruncatesLongContent() async throws {
        let provider = PlaceholderSummaryProvider()

        let longTranscript = String(repeating: "A", count: 500)
        let longNotes = String(repeating: "B", count: 500)

        let result = try await provider.generateSummary(transcript: longTranscript, notes: longNotes)

        // Content should be truncated to first 200 characters
        XCTAssertTrue(result.contains("…"), "Should contain ellipsis for truncated content")
    }
}

// MARK: - Test Helper

private final class TestSummaryProvider: SummaryProviding, @unchecked Sendable {
    let output: String
    private(set) var callCount = 0
    private(set) var lastTranscript: String?
    private(set) var lastNotes: String?

    init(output: String) {
        self.output = output
    }

    func generateSummary(transcript: String, notes: String) async throws -> String {
        self.callCount += 1
        self.lastTranscript = transcript
        self.lastNotes = notes
        return self.output
    }
}
