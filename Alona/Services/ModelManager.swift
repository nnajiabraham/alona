import Foundation

enum ModelLocator {
    static let modelName = "ggml-base.en"
    static let modelExtension = "bin"
    static let remoteURL = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin")!
    /// Mutable for testing only - intentionally not isolated
    nonisolated(unsafe) static var applicationSupportDirectoryProvider: () -> URL = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    static func resetForTesting() {
        self.applicationSupportDirectoryProvider = {
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        }
    }

    static func bundleModelURL() -> URL? {
        if let url = Bundle.main.url(forResource: modelName, withExtension: modelExtension) {
            return url
        }
        return Bundle.main.url(forResource: self.modelName, withExtension: self.modelExtension, subdirectory: "Models")
    }

    static func userModelsDirectory() throws -> URL {
        let base = self.applicationSupportDirectoryProvider()
        let directory = base.appendingPathComponent("Alona/Models", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func userModelURL() throws -> URL {
        try self.userModelsDirectory().appendingPathComponent("\(self.modelName).\(self.modelExtension)")
    }

    static func userModelExists() -> Bool {
        guard let url = try? userModelURL() else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    static func existingModelURL() -> URL? {
        if let userURL = try? userModelURL(), FileManager.default.fileExists(atPath: userURL.path) {
            return userURL
        }
        if let bundleURL = bundleModelURL() {
            return bundleURL
        }
        return nil
    }

    static func persistUserModel(from sourceURL: URL) throws {
        let destination = try userModelURL()
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.moveItem(at: sourceURL, to: destination)
    }
}

@MainActor
final class WhisperModelManager: ObservableObject {
    static let shared = WhisperModelManager()

    enum Status: Equatable {
        case available
        case downloading
        case missing
        case failed(String)
    }

    @Published private(set) var status: Status = .missing
    private var downloadTask: Task<Void, Never>?

    private init() {
        self.refreshStatus()
    }

    func refreshStatus() {
        if ModelLocator.existingModelURL() != nil {
            self.status = .available
        } else {
            self.status = .missing
        }
    }

    func downloadModel() {
        guard self.downloadTask == nil else { return }
        self.status = .downloading
        self.downloadTask = Task {
            do {
                let (tempURL, _) = try await URLSession.shared.download(from: ModelLocator.remoteURL)
                try ModelLocator.persistUserModel(from: tempURL)
                await MainActor.run {
                    self.status = .available
                }
            } catch {
                await MainActor.run {
                    self.status = .failed(error.localizedDescription)
                }
            }
            await MainActor.run {
                self.downloadTask = nil
            }
        }
    }
}
