import Foundation
import XCTest
@testable import Alona

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
