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
        case downloading(progress: Double, info: DownloadInfo)
        case notDownloaded
        case failed(String)

        var isDownloading: Bool {
            if case .downloading = self { return true }
            return false
        }

        /// Helper to get just the progress value
        var progressValue: Double {
            if case let .downloading(progress, _) = self {
                return progress
            }
            return 0
        }
    }

    /// Detailed download progress information
    struct DownloadInfo: Equatable {
        var bytesDownloaded: Int64
        var totalBytes: Int64
        var bytesPerSecond: Double
        var startTime: Date
        var lastUpdateTime: Date

        var formattedDownloaded: String {
            ByteCountFormatter.string(fromByteCount: self.bytesDownloaded, countStyle: .file)
        }

        var formattedTotal: String {
            ByteCountFormatter.string(fromByteCount: self.totalBytes, countStyle: .file)
        }

        var formattedSpeed: String {
            let speedBytesPerSec = Int64(self.bytesPerSecond)
            return "\(ByteCountFormatter.string(fromByteCount: speedBytesPerSec, countStyle: .file))/s"
        }

        var estimatedTimeRemaining: String {
            guard self.bytesPerSecond > 0 else { return "Calculating..." }
            let remaining = Double(self.totalBytes - self.bytesDownloaded)
            let seconds = remaining / self.bytesPerSecond
            if seconds < 60 {
                return "\(Int(seconds))s remaining"
            } else if seconds < 3600 {
                return "\(Int(seconds / 60))m remaining"
            } else {
                return "\(Int(seconds / 3600))h \(Int((seconds.truncatingRemainder(dividingBy: 3600)) / 60))m"
            }
        }

        var percentComplete: Int {
            guard self.totalBytes > 0 else { return 0 }
            return Int((Double(self.bytesDownloaded) / Double(self.totalBytes)) * 100)
        }

        static func initial(totalBytes: Int64) -> DownloadInfo {
            DownloadInfo(
                bytesDownloaded: 0,
                totalBytes: totalBytes,
                bytesPerSecond: 0,
                startTime: Date(),
                lastUpdateTime: Date())
        }
    }

    /// Log entry for download activity
    struct DownloadLogEntry: Identifiable, Equatable {
        let id = UUID()
        let timestamp: Date
        let message: String
        let type: LogType

        enum LogType: Equatable {
            case info
            case progress
            case warning
            case error
            case success
        }

        var formattedTimestamp: String {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            return formatter.string(from: self.timestamp)
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

    /// Download activity log (visible to user)
    var downloadLogs: [DownloadLogEntry] = []

    /// Active download tasks
    private var downloadTasks: [WhisperModel: Task<Void, Never>] = [:]

    /// Maximum log entries to keep
    private let maxLogEntries = 100

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
            self.addLog("Download already in progress", type: .warning)
            return
        }

        self.logger.info("Starting download of \(model.displayName) (\(model.formattedSize))")
        self.addLog("Starting download: \(model.displayName) (\(model.formattedSize))", type: .info)

        let expectedBytes = Int64(model.sizeInMB) * 1024 * 1024
        let initialInfo = DownloadInfo.initial(totalBytes: expectedBytes)
        self.modelStatuses[model] = .downloading(progress: 0, info: initialInfo)

        self.downloadTasks[model] = Task {
            do {
                let (tempURL, _) = try await self.downloadWithProgress(model: model)

                await MainActor.run {
                    self.addLog("Saving model to disk...", type: .info)
                }

                try ModelLocator.persistUserModel(from: tempURL, for: model)

                await MainActor.run {
                    self.modelStatuses[model] = .available
                    self.downloadTasks[model] = nil
                    self.logger.info("Successfully downloaded \(model.displayName)")
                    self.addLog("✓ Download complete: \(model.displayName)", type: .success)
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.modelStatuses[model] = .notDownloaded
                    self.downloadTasks[model] = nil
                    self.addLog("Download cancelled", type: .warning)
                }
            } catch {
                await MainActor.run {
                    self.modelStatuses[model] = .failed(error.localizedDescription)
                    self.downloadTasks[model] = nil
                    self.logger.error("Failed to download \(model.displayName): \(error.localizedDescription)")
                    self.addLog("✗ Error: \(error.localizedDescription)", type: .error)
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
        self.addLog("Cancelled download of \(model.displayName)", type: .warning)
    }

    /// Delete a downloaded model
    func deleteModel(_ model: WhisperModel) {
        do {
            try ModelLocator.deleteUserModel(for: model)
            self.modelStatuses[model] = .notDownloaded
            self.logger.info("Deleted \(model.displayName)")
            self.addLog("Deleted \(model.displayName)", type: .info)
        } catch {
            self.logger.error("Failed to delete \(model.displayName): \(error.localizedDescription)")
            self.addLog("Failed to delete: \(error.localizedDescription)", type: .error)
        }
    }

    /// Clear download logs
    func clearLogs() {
        self.downloadLogs.removeAll()
    }

    /// Add a log entry
    private func addLog(_ message: String, type: DownloadLogEntry.LogType) {
        let entry = DownloadLogEntry(timestamp: Date(), message: message, type: type)
        self.downloadLogs.append(entry)
        // Keep log size manageable
        if self.downloadLogs.count > self.maxLogEntries {
            self.downloadLogs.removeFirst(self.downloadLogs.count - self.maxLogEntries)
        }
    }

    // MARK: - Private Helpers

    private func downloadWithProgress(model: WhisperModel) async throws -> (URL, URLResponse) {
        await MainActor.run {
            self.addLog("Connecting to \(model.downloadURL.host ?? "server")...", type: .info)
        }

        var request = URLRequest(url: model.downloadURL)
        request.timeoutInterval = 30

        let (asyncBytes, response) = try await URLSession.shared.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        await MainActor.run {
            self.addLog("Connected (HTTP \(httpResponse.statusCode))", type: .info)
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }

        let expectedLength = response.expectedContentLength
        var receivedLength: Int64 = 0
        let startTime = Date()
        var lastLogTime = startTime
        var lastLogBytes: Int64 = 0

        await MainActor.run {
            let total = ByteCountFormatter.string(fromByteCount: expectedLength, countStyle: .file)
            self.addLog("Downloading \(total)...", type: .info)
        }

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(model.fullFileName)

        // Remove existing temp file if present
        try? FileManager.default.removeItem(at: tempURL)

        guard let outputStream = OutputStream(url: tempURL, append: false) else {
            throw URLError(.cannotCreateFile)
        }
        outputStream.open()
        defer { outputStream.close() }

        // Use larger buffer for efficiency (1MB)
        let bufferSize = 1024 * 1024
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        var bufferIndex = 0

        // Progress update interval (update every ~1 second or 1MB, whichever comes first)
        let progressUpdateInterval: TimeInterval = 1.0

        for try await byte in asyncBytes {
            try Task.checkCancellation()

            buffer[bufferIndex] = byte
            bufferIndex += 1

            if bufferIndex == bufferSize {
                outputStream.write(buffer, maxLength: bufferIndex)
                receivedLength += Int64(bufferIndex)
                bufferIndex = 0

                let now = Date()
                let elapsed = now.timeIntervalSince(lastLogTime)

                // Update progress and log periodically
                if elapsed >= progressUpdateInterval {
                    let totalElapsed = now.timeIntervalSince(startTime)
                    let bytesPerSecond = totalElapsed > 0 ? Double(receivedLength) / totalElapsed : 0
                    let progress = expectedLength > 0 ? Double(receivedLength) / Double(expectedLength) : 0

                    let info = DownloadInfo(
                        bytesDownloaded: receivedLength,
                        totalBytes: expectedLength,
                        bytesPerSecond: bytesPerSecond,
                        startTime: startTime,
                        lastUpdateTime: now)

                    await MainActor.run {
                        self.modelStatuses[model] = .downloading(progress: progress, info: info)

                        // Log progress every ~10%
                        let currentPercent = Int(progress * 100)
                        let lastPercent = expectedLength > 0
                            ? Int((Double(lastLogBytes) / Double(expectedLength)) * 100)
                            : 0
                        if currentPercent / 10 > lastPercent / 10 || elapsed >= 5.0 {
                            let downloaded = ByteCountFormatter
                                .string(fromByteCount: receivedLength, countStyle: .file)
                            let speed = ByteCountFormatter
                                .string(fromByteCount: Int64(bytesPerSecond), countStyle: .file)
                            self.addLog("\(currentPercent)% - \(downloaded) @ \(speed)/s", type: .progress)
                        }
                    }

                    lastLogTime = now
                    lastLogBytes = receivedLength
                }
            }
        }

        // Write remaining bytes
        if bufferIndex > 0 {
            outputStream.write(buffer, maxLength: bufferIndex)
            receivedLength += Int64(bufferIndex)
        }

        let totalTime = Date().timeIntervalSince(startTime)
        let avgSpeed = totalTime > 0 ? Double(receivedLength) / totalTime : 0

        let finalInfo = DownloadInfo(
            bytesDownloaded: receivedLength,
            totalBytes: expectedLength,
            bytesPerSecond: avgSpeed,
            startTime: startTime,
            lastUpdateTime: Date())

        await MainActor.run {
            self.modelStatuses[model] = .downloading(progress: 1.0, info: finalInfo)
            let time = String(format: "%.1f", totalTime)
            let speed = ByteCountFormatter.string(fromByteCount: Int64(avgSpeed), countStyle: .file)
            self.addLog("Download finished in \(time)s (avg \(speed)/s)", type: .success)
        }

        return (tempURL, response)
    }
}
