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

// MARK: - WhisperModel Tests

final class WhisperModelTests: XCTestCase {
    func testWhisperModelDefaultIsLargeV3Turbo() {
        XCTAssertEqual(WhisperModel.defaultModel, .largeV3Turbo)
    }

    func testWhisperModelDisplayNames() {
        XCTAssertEqual(WhisperModel.tinyEn.displayName, "Tiny (English)")
        XCTAssertEqual(WhisperModel.baseEn.displayName, "Base (English)")
        XCTAssertEqual(WhisperModel.largeV3Turbo.displayName, "Large V3 Turbo (Multilingual)")
    }

    func testWhisperModelSizes() {
        XCTAssertEqual(WhisperModel.tinyEn.sizeInMB, 75)
        XCTAssertEqual(WhisperModel.baseEn.sizeInMB, 142)
        XCTAssertEqual(WhisperModel.largeV3Turbo.sizeInMB, 1600)
    }

    func testWhisperModelFormattedSize() {
        XCTAssertEqual(WhisperModel.tinyEn.formattedSize, "75 MB")
        XCTAssertEqual(WhisperModel.largeV3Turbo.formattedSize, "1.6 GB")
        XCTAssertEqual(WhisperModel.largeV3.formattedSize, "2.9 GB")
    }

    func testWhisperModelFileNames() {
        XCTAssertEqual(WhisperModel.tinyEn.fileName, "ggml-tiny.en")
        XCTAssertEqual(WhisperModel.baseEn.fileName, "ggml-base.en")
        XCTAssertEqual(WhisperModel.largeV3Turbo.fileName, "ggml-large-v3-turbo")
        XCTAssertEqual(WhisperModel.largeV3Turbo.fullFileName, "ggml-large-v3-turbo.bin")
    }

    func testWhisperModelDownloadURLs() {
        let turboURL = WhisperModel.largeV3Turbo.downloadURL
        XCTAssertEqual(
            turboURL.absoluteString,
            "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin")
    }

    func testWhisperModelQuantizedFlag() {
        XCTAssertFalse(WhisperModel.tinyEn.isQuantized)
        XCTAssertTrue(WhisperModel.tinyEnQ5.isQuantized)
        XCTAssertTrue(WhisperModel.baseEnQ5.isQuantized)
        XCTAssertFalse(WhisperModel.largeV3Turbo.isQuantized)
    }

    func testWhisperModelMultilingualFlag() {
        XCTAssertFalse(WhisperModel.tinyEn.isMultilingual)
        XCTAssertFalse(WhisperModel.baseEn.isMultilingual)
        XCTAssertTrue(WhisperModel.largeV3.isMultilingual)
        XCTAssertTrue(WhisperModel.largeV3Turbo.isMultilingual)
    }

    func testWhisperModelRecommendedModels() {
        let recommended = WhisperModel.recommendedModels
        XCTAssertTrue(recommended.contains(.largeV3Turbo))
        XCTAssertTrue(recommended.contains(.smallEn))
        XCTAssertTrue(recommended.contains(.baseEn))
    }

    func testWhisperModelAllCasesCount() {
        // Ensure we have all expected models
        XCTAssertEqual(WhisperModel.allCases.count, 11)
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

    func testModelLocatorUserModelURLForSpecificModel() throws {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelLocatorSpecific-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        ModelLocator.applicationSupportDirectoryProvider = { tempBase }
        defer {
            ModelLocator.resetForTesting()
            try? FileManager.default.removeItem(at: tempBase)
        }

        let turboURL = try ModelLocator.userModelURL(for: .largeV3Turbo)
        XCTAssertTrue(turboURL.lastPathComponent == "ggml-large-v3-turbo.bin")

        let baseURL = try ModelLocator.userModelURL(for: .baseEn)
        XCTAssertTrue(baseURL.lastPathComponent == "ggml-base.en.bin")
    }

    func testModelLocatorUserModelExistsForSpecificModel() throws {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelLocatorExists-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        ModelLocator.applicationSupportDirectoryProvider = { tempBase }
        defer {
            ModelLocator.resetForTesting()
            try? FileManager.default.removeItem(at: tempBase)
        }

        // Initially no model exists
        XCTAssertFalse(ModelLocator.userModelExists(for: .baseEn))

        // Create a fake model file
        let modelURL = try ModelLocator.userModelURL(for: .baseEn)
        FileManager.default.createFile(atPath: modelURL.path, contents: Data("fake".utf8))

        // Now it should exist
        XCTAssertTrue(ModelLocator.userModelExists(for: .baseEn))
        XCTAssertFalse(ModelLocator.userModelExists(for: .largeV3Turbo))
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

        let userURL = try ModelLocator.userModelURL(for: .baseEn)
        FileManager.default.createFile(atPath: userURL.path, contents: Data("user".utf8))
        let resolved = ModelLocator.existingModelURL(for: .baseEn)
        XCTAssertEqual(resolved, userURL)
    }

    func testModelLocatorDeleteUserModel() throws {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelLocatorDelete-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        ModelLocator.applicationSupportDirectoryProvider = { tempBase }
        defer {
            ModelLocator.resetForTesting()
            try? FileManager.default.removeItem(at: tempBase)
        }

        // Create a model file
        let modelURL = try ModelLocator.userModelURL(for: .tinyEn)
        FileManager.default.createFile(atPath: modelURL.path, contents: Data("model".utf8))
        XCTAssertTrue(ModelLocator.userModelExists(for: .tinyEn))

        // Delete it
        try ModelLocator.deleteUserModel(for: .tinyEn)
        XCTAssertFalse(ModelLocator.userModelExists(for: .tinyEn))
    }
}

// MARK: - WhisperModelManager Tests

@MainActor
final class WhisperModelManagerTests: XCTestCase {
    func testWhisperModelManagerDefaultSelection() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "test-\(UUID())"))
        let manager = WhisperModelManager(userDefaults: defaults)
        XCTAssertEqual(manager.selectedModel, .largeV3Turbo)
    }

    func testWhisperModelManagerPersistsSelection() throws {
        let testDefaults = try XCTUnwrap(UserDefaults(suiteName: "test-\(UUID())"))
        let manager = WhisperModelManager(userDefaults: testDefaults)

        manager.selectedModel = .smallEn
        XCTAssertEqual(testDefaults.string(forKey: "selectedWhisperModel"), "small.en")

        // Create new manager with same defaults
        let manager2 = WhisperModelManager(userDefaults: testDefaults)
        XCTAssertEqual(manager2.selectedModel, .smallEn)
    }

    func testWhisperModelManagerStatusTracking() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "test-\(UUID())"))
        let manager = WhisperModelManager(userDefaults: defaults)

        // All models should start as not downloaded (unless bundled)
        for model in WhisperModel.allCases {
            let status = manager.status(for: model)
            // Status should be either available (bundled) or notDownloaded
            XCTAssertTrue(
                status == .available || status == .notDownloaded,
                "Model \(model.displayName) has unexpected status")
        }
    }

    func testWhisperModelManagerModelStatusEquality() {
        let status1 = WhisperModelManager.ModelStatus.downloading(progress: 0.5)
        let status2 = WhisperModelManager.ModelStatus.downloading(progress: 0.5)
        let status3 = WhisperModelManager.ModelStatus.downloading(progress: 0.7)

        XCTAssertEqual(status1, status2)
        XCTAssertNotEqual(status1, status3)
        XCTAssertEqual(WhisperModelManager.ModelStatus.available, .available)
        XCTAssertEqual(WhisperModelManager.ModelStatus.notDownloaded, .notDownloaded)
    }

    func testWhisperModelManagerIsDownloadingFlag() {
        let downloading = WhisperModelManager.ModelStatus.downloading(progress: 0.5)
        let available = WhisperModelManager.ModelStatus.available
        let notDownloaded = WhisperModelManager.ModelStatus.notDownloaded

        XCTAssertTrue(downloading.isDownloading)
        XCTAssertFalse(available.isDownloading)
        XCTAssertFalse(notDownloaded.isDownloading)
    }
}
