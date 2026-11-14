// Model files on disk: where an artifact lives, whether it is complete, and
// the download that puts it there. Files are checked by size and SHA-256
// before they take their final name, so a file with its final name is whole.
import CryptoKit
import Foundation

struct ModelFile {
    let url: URL, name: String, bytes: Int64, sha256: String
}

/// A model as the app's registry (core/artifacts.json) describes it.
struct Artifact {
    let id: String, runtime: String, files: [ModelFile]

    init?(_ raw: Any?) {
        guard let d = raw as? [String: Any], let id = d["id"] as? String, !id.isEmpty,
              let runtime = d["runtime"] as? String, let list = d["files"] as? [[String: Any]] else { return nil }
        var files: [ModelFile] = []
        for f in list {
            guard let s = f["url"] as? String, let url = URL(string: s), let name = f["name"] as? String,
                  !name.isEmpty, !name.contains("/") else { return nil }
            files.append(ModelFile(url: url, name: name, bytes: (f["bytes"] as? NSNumber)?.int64Value ?? 0, sha256: f["sha256"] as? String ?? ""))
        }
        self.id = id; self.runtime = runtime; self.files = files
    }

    var totalBytes: Int64 { files.reduce(0) { $0 + $1.bytes } }
}

struct EngineError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

enum ModelStore {
    /// Models sit beside the app's data, not inside it: they are large and
    /// refetchable, and an agent drive's scratch store should not own them.
    static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var dir = base.appendingPathComponent("exact/com.alona.app/models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        return dir
    }()

    static func dir(_ artifact: Artifact) -> URL { root.appendingPathComponent(artifact.id, isDirectory: true) }
    static func path(_ artifact: Artifact, _ name: String) -> String { dir(artifact).appendingPathComponent(name).path }

    static func installed(_ artifact: Artifact) -> Bool {
        artifact.files.allSatisfy { f in
            let size = (try? FileManager.default.attributesOfItem(atPath: path(artifact, f.name))[.size] as? NSNumber)?.int64Value
            return size != nil && (f.bytes == 0 || size == f.bytes)
        }
    }

    static func remove(_ artifact: Artifact) {
        try? FileManager.default.removeItem(at: dir(artifact))
    }

    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Downloads every missing file of `artifact`. `progress` hears a fraction of the artifact's bytes.
    static func download(_ artifact: Artifact, cancelled: @escaping () -> Bool, progress: @escaping (Double) -> Void) throws {
        try FileManager.default.createDirectory(at: dir(artifact), withIntermediateDirectories: true)
        let total = max(1, artifact.totalBytes)
        var before: Int64 = 0
        for file in artifact.files {
            let dest = dir(artifact).appendingPathComponent(file.name)
            let have = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? NSNumber)?.int64Value
            if have == nil || (file.bytes != 0 && have != file.bytes) {
                let base = before
                try FileDownload(dest: dest, cancelled: cancelled) { got in progress(Double(base + got) / Double(total)) }.run(file)
            }
            before += file.bytes
            progress(Double(before) / Double(total))
        }
    }
}

/// Streams one file into `<dest>.part`, resuming with a Range request, then
/// verifies it and renames it into place.
private final class FileDownload: NSObject, URLSessionDataDelegate {
    private let dest: URL, part: URL, cancelled: () -> Bool, onBytes: (Int64) -> Void
    private var handle: FileHandle?, have: Int64 = 0, failure: Error?
    private let done = DispatchSemaphore(value: 0)

    init(dest: URL, cancelled: @escaping () -> Bool, onBytes: @escaping (Int64) -> Void) {
        self.dest = dest; part = dest.appendingPathExtension("part"); self.cancelled = cancelled; self.onBytes = onBytes
    }

    func run(_ file: ModelFile) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: part.path) { fm.createFile(atPath: part.path, contents: nil) }
        have = (try? fm.attributesOfItem(atPath: part.path)[.size] as? NSNumber)?.int64Value ?? 0
        if file.bytes != 0, have > file.bytes { try Data().write(to: part); have = 0 }
        if file.bytes == 0 || have < file.bytes {
            var request = URLRequest(url: file.url)
            if have > 0 { request.setValue("bytes=\(have)-", forHTTPHeaderField: "Range") }
            let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
            session.dataTask(with: request).resume()
            done.wait()
            session.finishTasksAndInvalidate()
            if let failure { throw failure }
        }
        if file.bytes != 0, have != file.bytes {
            throw EngineError("\(file.name) stopped at \(have) of \(file.bytes) bytes. Try the download again.")
        }
        if !file.sha256.isEmpty, try ModelStore.sha256(of: part) != file.sha256 {
            try? fm.removeItem(at: part)
            throw EngineError("\(file.name) did not match its checksum and was discarded. Try the download again.")
        }
        try? fm.removeItem(at: dest)
        try fm.moveItem(at: part, to: dest)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        // A 200 to a Range request means the server sent the whole file again.
        if status == 200, have > 0 { have = 0; try? Data().write(to: part) }
        guard status == 200 || status == 206 else {
            failure = EngineError("The model server answered HTTP \(status).")
            completionHandler(.cancel); return
        }
        handle = try? FileHandle(forWritingTo: part)
        _ = try? handle?.seekToEnd()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if cancelled() { failure = EngineError("Cancelled."); dataTask.cancel(); return }
        do { try handle?.write(contentsOf: data) } catch { failure = error; dataTask.cancel(); return }
        have += Int64(data.count)
        onBytes(have)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if failure == nil, let error { failure = error }
        try? handle?.close()
        done.signal()
    }
}
