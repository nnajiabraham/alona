import Foundation
import XCTest
@testable import AlonaCore

// MARK: - TranscriptionResult Tests

final class TranscriptionResultTests: XCTestCase {
    func testTranscriptionResultStoresTextAndSegments() {
        let segments = [
            TranscriptionSegment(startTime: 0, endTime: 5, text: "Hello"),
            TranscriptionSegment(startTime: 5, endTime: 10, text: "World"),
        ]
        let result = TranscriptionResult(text: "Hello World", segments: segments)

        XCTAssertEqual(result.text, "Hello World")
        XCTAssertEqual(result.segments.count, 2)
    }

    func testTranscriptionResultWithEmptySegments() {
        let result = TranscriptionResult(text: "Some text", segments: [])

        XCTAssertEqual(result.text, "Some text")
        XCTAssertTrue(result.segments.isEmpty)
    }

    func testTranscriptionSegmentTimeIntervals() {
        let segment = TranscriptionSegment(startTime: 1.5, endTime: 3.75, text: "Test")

        XCTAssertEqual(segment.startTime, 1.5, accuracy: 0.001)
        XCTAssertEqual(segment.endTime, 3.75, accuracy: 0.001)

        let duration = segment.endTime - segment.startTime
        XCTAssertEqual(duration, 2.25, accuracy: 0.001)
    }

    func testTranscriptionSegmentWithEmptyText() {
        let segment = TranscriptionSegment(startTime: 0, endTime: 1, text: "")

        XCTAssertEqual(segment.text, "")
        XCTAssertEqual(segment.startTime, 0)
        XCTAssertEqual(segment.endTime, 1)
    }
}

// MARK: - TranscriptionError Tests

final class TranscriptionErrorTests: XCTestCase {
    func testTranscriptionErrorDescriptions() {
        XCTAssertTrue(
            TranscriptionError.modelNotFound.errorDescription?.contains("Whisper model") ?? false,
            "modelNotFound should mention Whisper model")

        XCTAssertTrue(
            TranscriptionError.modelNotLoaded.errorDescription?.contains("load") ?? false,
            "modelNotLoaded should mention loading")

        XCTAssertTrue(
            TranscriptionError.conversionFailed.errorDescription?.contains("16kHz") ?? false,
            "conversionFailed should mention target format")

        XCTAssertTrue(
            TranscriptionError.bufferAllocationFailed.errorDescription?.contains("buffer") ?? false,
            "bufferAllocationFailed should mention buffer")

        XCTAssertTrue(
            TranscriptionError.noChannelData.errorDescription?.contains("channel") ?? false,
            "noChannelData should mention channel")
    }
}

// MARK: - Transcription Engine Memory Management Tests

final class TranscriptionMemoryTests: XCTestCase {
    func testTranscriptionEngineModelLazyLoad() {
        // Verify model is not loaded on init
        let engine = TranscriptionEngine()

        XCTAssertFalse(engine.isModelLoaded, "Model should not be loaded on init")
    }

    func testTranscriptionEngineUnloadWhenIdle() {
        let engine = TranscriptionEngine()

        // Unload should be safe even when no model is loaded
        engine.unloadModelIfIdle()

        XCTAssertFalse(engine.isModelLoaded, "Model should remain unloaded")
    }
}

// MARK: - Model Locator Tests

final class ModelLocatorTests: XCTestCase {
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
}
