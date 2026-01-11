import Foundation
import OSLog

// MARK: - Whisper Model Definition

/// Available Whisper model variants with their metadata
enum WhisperModel: String, CaseIterable, Identifiable, Codable {
    case tinyEn = "tiny.en"
    case tinyEnQ5 = "tiny.en-q5_1"
    case baseEn = "base.en"
    case baseEnQ5 = "base.en-q5_1"
    case smallEn = "small.en"
    case smallEnQ5 = "small.en-q5_1"
    case mediumEn = "medium.en"
    case mediumEnQ5 = "medium.en-q5_0"
    case largeV3 = "large-v3"
    case largeV3Turbo = "large-v3-turbo"
    case largeQ5 = "large-q5_0"

    var id: String { self.rawValue }

    /// Human-readable display name
    var displayName: String {
        switch self {
        case .tinyEn: "Tiny (English)"
        case .tinyEnQ5: "Tiny Q5 (English)"
        case .baseEn: "Base (English)"
        case .baseEnQ5: "Base Q5 (English)"
        case .smallEn: "Small (English)"
        case .smallEnQ5: "Small Q5 (English)"
        case .mediumEn: "Medium (English)"
        case .mediumEnQ5: "Medium Q5 (English)"
        case .largeV3: "Large V3 (Multilingual)"
        case .largeV3Turbo: "Large V3 Turbo (Multilingual)"
        case .largeQ5: "Large Q5 (Multilingual)"
        }
    }

    /// Model file size in MB (approximate)
    var sizeInMB: Int {
        switch self {
        case .tinyEn: 75
        case .tinyEnQ5: 31
        case .baseEn: 142
        case .baseEnQ5: 57
        case .smallEn: 466
        case .smallEnQ5: 182
        case .mediumEn: 1500
        case .mediumEnQ5: 515
        case .largeV3: 2900
        case .largeV3Turbo: 1600
        case .largeQ5: 1030
        }
    }

    /// Formatted size string for display
    var formattedSize: String {
        if self.sizeInMB >= 1000 {
            return String(format: "%.1f GB", Double(self.sizeInMB) / 1000.0)
        }
        return "\(self.sizeInMB) MB"
    }

    /// Relative speed compared to realtime (higher = faster)
    var speedMultiplier: String {
        switch self {
        case .tinyEn, .tinyEnQ5: "~10x"
        case .baseEn, .baseEnQ5: "~7x"
        case .smallEn, .smallEnQ5: "~4x"
        case .mediumEn, .mediumEnQ5: "~2x"
        case .largeV3: "~1x"
        case .largeV3Turbo: "~2x"
        case .largeQ5: "~1.5x"
        }
    }

    /// Quality/accuracy description
    var qualityDescription: String {
        switch self {
        case .tinyEn, .tinyEnQ5: "Fast, basic accuracy"
        case .baseEn, .baseEnQ5: "Good balance"
        case .smallEn, .smallEnQ5: "Better accuracy"
        case .mediumEn, .mediumEnQ5: "High accuracy"
        case .largeV3: "Best accuracy"
        case .largeV3Turbo: "Best accuracy, optimized"
        case .largeQ5: "Best accuracy, compressed"
        }
    }

    /// Whether this is a quantized (compressed) model
    var isQuantized: Bool {
        self.rawValue.contains("q5")
    }

    /// Whether this model supports multiple languages
    var isMultilingual: Bool {
        !self.rawValue.contains(".en")
    }

    /// The ggml filename (without extension)
    var fileName: String {
        "ggml-\(self.rawValue)"
    }

    /// Full filename with extension
    var fullFileName: String {
        "\(self.fileName).bin"
    }

    /// Download URL from HuggingFace
    var downloadURL: URL {
        // swiftlint:disable:next force_unwrapping
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(self.fullFileName)")!
    }

    /// Default model for new installations
    static let defaultModel: WhisperModel = .largeV3Turbo

    /// Recommended models shown prominently in UI
    static let recommendedModels: [WhisperModel] = [
        .largeV3Turbo, // Best balance of speed and accuracy
        .smallEn, // Good for most use cases
        .baseEn, // Lightweight option
    ]
}

// MARK: - Model Locator

enum ModelLocator {
    /// Mutable for testing only - intentionally not isolated
    nonisolated(unsafe) static var applicationSupportDirectoryProvider: () -> URL = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    static func resetForTesting() {
        self.applicationSupportDirectoryProvider = {
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        }
    }

    /// Check if a specific model exists in the bundle
    static func bundleModelURL(for model: WhisperModel) -> URL? {
        if let url = Bundle.main.url(forResource: model.fileName, withExtension: "bin") {
            return url
        }
        return Bundle.main.url(forResource: model.fileName, withExtension: "bin", subdirectory: "Models")
    }

    /// Directory where user-downloaded models are stored
    static func userModelsDirectory() throws -> URL {
        let base = self.applicationSupportDirectoryProvider()
        let directory = base.appendingPathComponent("Alona/Models", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Path where a specific model would be stored in user directory
    static func userModelURL(for model: WhisperModel) throws -> URL {
        try self.userModelsDirectory().appendingPathComponent(model.fullFileName)
    }

    /// Check if a specific model exists in user directory
    static func userModelExists(for model: WhisperModel) -> Bool {
        guard let url = try? userModelURL(for: model) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Get URL of existing model (user directory first, then bundle)
    static func existingModelURL(for model: WhisperModel) -> URL? {
        if let userURL = try? userModelURL(for: model),
           FileManager.default.fileExists(atPath: userURL.path) {
            return userURL
        }
        if let bundleURL = bundleModelURL(for: model) {
            return bundleURL
        }
        return nil
    }

    /// Check if any model is available
    @MainActor
    static func anyModelAvailable() -> WhisperModel? {
        // Check selected model first
        let selected = WhisperModelManager.shared.selectedModel
        if self.existingModelURL(for: selected) != nil {
            return selected
        }
        // Fall back to any available model
        for model in WhisperModel.allCases where self.existingModelURL(for: model) != nil {
            return model
        }
        return nil
    }

    /// Save downloaded model to user directory
    static func persistUserModel(from sourceURL: URL, for model: WhisperModel) throws {
        let destination = try userModelURL(for: model)
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.moveItem(at: sourceURL, to: destination)
    }

    /// Delete a user-downloaded model
    static func deleteUserModel(for model: WhisperModel) throws {
        let url = try userModelURL(for: model)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Legacy compatibility

    /// Legacy: Get URL for currently selected model
    /// Note: This accesses MainActor-isolated state, so caller must be on MainActor
    @MainActor
    static func existingModelURL() -> URL? {
        self.existingModelURL(for: WhisperModelManager.shared.selectedModel)
    }
}

// MARK: - Whisper Model Manager

@MainActor
@Observable
final class WhisperModelManager {
    static let shared = WhisperModelManager()

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Alona", category: "WhisperModelManager")
    private let userDefaults: UserDefaults

    // MARK: - Model Status

    enum ModelStatus: Equatable {
        case available
        case downloading(progress: Double)
        case notDownloaded
        case failed(String)

        var isDownloading: Bool {
            if case .downloading = self { return true }
            return false
        }
    }

    // MARK: - Published State

    /// Currently selected model for transcription
    var selectedModel: WhisperModel {
        didSet {
            self.userDefaults.set(self.selectedModel.rawValue, forKey: "selectedWhisperModel")
            self.refreshAllStatuses()
        }
    }

    /// Status of each model (available, downloading, not downloaded)
    var modelStatuses: [WhisperModel: ModelStatus] = [:]

    /// Active download tasks
    private var downloadTasks: [WhisperModel: Task<Void, Never>] = [:]

    // MARK: - Initialization

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults

        // Load saved model selection or use default
        if let savedModel = userDefaults.string(forKey: "selectedWhisperModel"),
           let model = WhisperModel(rawValue: savedModel) {
            self.selectedModel = model
        } else {
            self.selectedModel = .largeV3Turbo
        }

        // Initialize all statuses
        for model in WhisperModel.allCases {
            self.modelStatuses[model] = .notDownloaded
        }
        self.refreshAllStatuses()
    }

    // MARK: - Status Management

    /// Refresh status for all models
    func refreshAllStatuses() {
        for model in WhisperModel.allCases {
            if ModelLocator.existingModelURL(for: model) != nil {
                self.modelStatuses[model] = .available
            } else if self.downloadTasks[model] != nil {
                // Keep downloading status
            } else {
                self.modelStatuses[model] = .notDownloaded
            }
        }
    }

    /// Get status for a specific model
    func status(for model: WhisperModel) -> ModelStatus {
        self.modelStatuses[model] ?? .notDownloaded
    }

    /// Check if selected model is available
    var isSelectedModelAvailable: Bool {
        self.status(for: self.selectedModel) == .available
    }

    /// Get URL for selected model (if available)
    var selectedModelURL: URL? {
        ModelLocator.existingModelURL(for: self.selectedModel)
    }

    // MARK: - Download Management

    /// Start downloading a model
    func downloadModel(_ model: WhisperModel) {
        guard self.downloadTasks[model] == nil else {
            self.logger.info("Download already in progress for \(model.displayName)")
            return
        }

        self.logger.info("Starting download of \(model.displayName) (\(model.formattedSize))")
        self.modelStatuses[model] = .downloading(progress: 0)

        self.downloadTasks[model] = Task {
            do {
                let (tempURL, _) = try await self.downloadWithProgress(model: model)
                try ModelLocator.persistUserModel(from: tempURL, for: model)

                await MainActor.run {
                    self.modelStatuses[model] = .available
                    self.downloadTasks[model] = nil
                    self.logger.info("Successfully downloaded \(model.displayName)")
                }
            } catch {
                await MainActor.run {
                    self.modelStatuses[model] = .failed(error.localizedDescription)
                    self.downloadTasks[model] = nil
                    self.logger.error("Failed to download \(model.displayName): \(error.localizedDescription)")
                }
            }
        }
    }

    /// Cancel an in-progress download
    func cancelDownload(_ model: WhisperModel) {
        self.downloadTasks[model]?.cancel()
        self.downloadTasks[model] = nil
        self.modelStatuses[model] = .notDownloaded
        self.logger.info("Cancelled download of \(model.displayName)")
    }

    /// Delete a downloaded model
    func deleteModel(_ model: WhisperModel) {
        do {
            try ModelLocator.deleteUserModel(for: model)
            self.modelStatuses[model] = .notDownloaded
            self.logger.info("Deleted \(model.displayName)")
        } catch {
            self.logger.error("Failed to delete \(model.displayName): \(error.localizedDescription)")
        }
    }

    // MARK: - Private Helpers

    private func downloadWithProgress(model: WhisperModel) async throws -> (URL, URLResponse) {
        let request = URLRequest(url: model.downloadURL)

        let (asyncBytes, response) = try await URLSession.shared.bytes(for: request)

        let expectedLength = response.expectedContentLength
        var receivedLength: Int64 = 0

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(model.fullFileName)

        // Remove existing temp file if present
        try? FileManager.default.removeItem(at: tempURL)

        guard let outputStream = OutputStream(url: tempURL, append: false) else {
            throw URLError(.cannotCreateFile)
        }
        outputStream.open()
        defer { outputStream.close() }

        let bufferSize = 65536
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        var bufferIndex = 0

        for try await byte in asyncBytes {
            buffer[bufferIndex] = byte
            bufferIndex += 1

            if bufferIndex == bufferSize {
                outputStream.write(buffer, maxLength: bufferIndex)
                receivedLength += Int64(bufferIndex)
                bufferIndex = 0

                if expectedLength > 0 {
                    let progress = Double(receivedLength) / Double(expectedLength)
                    await MainActor.run {
                        self.modelStatuses[model] = .downloading(progress: progress)
                    }
                }
            }
        }

        // Write remaining bytes
        if bufferIndex > 0 {
            outputStream.write(buffer, maxLength: bufferIndex)
        }

        await MainActor.run {
            self.modelStatuses[model] = .downloading(progress: 1.0)
        }

        return (tempURL, response)
    }
}
