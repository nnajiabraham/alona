// Alona's inference engine on Apple platforms. It answers the JSON protocol
// in core/engine.ts through `native.later`: every request gets one reply at
// once, and long work runs as a job the app polls by id.
import Foundation

private final class Job {
    let id: String
    var state = "running", progress = 0.0, text = "", segments: [[String: Any]] = [], error = "", cancelled = false
    var artifact = ""
    init(id: String) { self.id = id }
    var view: [String: Any] {
        ["id": id, "state": state, "progress": progress, "text": text, "segments": segments, "error": error]
    }
}

private enum Loaded {
    case speech(String, Speech)
    case writer(String, Writer)
}

final class Engine: ExactModule {
    /// One model at a time: the queue is the lock on `loaded`, and loading one kind frees the other.
    private let work = DispatchQueue(label: "alona.engine.work", qos: .userInitiated)
    private let net = DispatchQueue(label: "alona.engine.net", qos: .utility, attributes: .concurrent)
    private let lock = NSLock()
    private var jobs: [String: Job] = [:]
    private var loaded: Loaded?

    override func later(_ request: [String: Any], reply: ExactReply) {
        switch request["op"] as? String ?? "" {
        case "probe":
            reply.send(probe())
        case "installed":
            let list = (request["artifacts"] as? [Any] ?? []).compactMap { Artifact($0) }
            reply.send(["ids": list.filter(ModelStore.installed).map(\.id)])
        case "job":
            let id = request["job"] as? String ?? ""
            reply.send(read(id)?.view ?? ["id": id, "state": "unknown", "progress": 0, "text": "", "segments": [], "error": ""])
        case "cancel":
            lock.lock(); jobs[request["job"] as? String ?? ""]?.cancelled = true; lock.unlock()
            reply.send([:])
        case "unload":
            work.async { self.loaded = nil; reply.send([:]) }
        case "remove":
            guard let artifact = Artifact(request["artifact"]) else { return reply.fail("remove needs an artifact") }
            lock.lock()
            for (id, job) in jobs where job.artifact == artifact.id { job.cancelled = true; jobs[id] = nil }
            lock.unlock()
            work.async {
                if self.loadedId == artifact.id { self.loaded = nil }
                ModelStore.remove(artifact)
                reply.send([:])
            }
        case "download":
            guard let artifact = Artifact(request["artifact"]) else { return reply.fail("download needs an artifact") }
            start(request, artifact, reply, on: net) { job in
                try ModelStore.download(artifact, cancelled: { self.isCancelled(job) }) { fraction in
                    self.update(job) { $0.progress = fraction }
                }
            }
        case "transcribe":
            guard let artifact = Artifact(request["artifact"]), let url = file(request["audio"] as? String) else {
                return reply.fail("transcribe needs an artifact and a recording")
            }
            start(request, artifact, reply, on: work) { job in
                try self.speech(artifact).transcribe(url, cancelled: { self.isCancelled(job) }) { segment, read in
                    self.update(job) { if let segment { $0.segments.append(segment) }; $0.progress = read }
                }
            }
        case "generate":
            guard let artifact = Artifact(request["artifact"]), let prompt = request["prompt"] as? String else {
                return reply.fail("generate needs an artifact and a prompt")
            }
            let maxTokens = (request["maxTokens"] as? NSNumber)?.intValue ?? 512
            start(request, artifact, reply, on: work) { job in
                let text = try self.writer(artifact).generate(prompt: prompt, maxTokens: maxTokens, cancelled: { self.isCancelled(job) }) { text, fraction in
                    self.update(job) { $0.text = text; $0.progress = fraction }
                }
                self.update(job) { $0.text = text }
            }
        default:
            reply.fail("unknown op")
        }
    }

    override func destroy() { work.sync { loaded = nil } }

    /// Starts `body` as the job the request names, unless that job already exists: starting is idempotent by id.
    private func start(_ request: [String: Any], _ artifact: Artifact, _ reply: ExactReply, on queue: DispatchQueue,
                       _ body: @escaping (Job) throws -> Void) {
        guard let id = request["job"] as? String, !id.isEmpty else { return reply.fail("a job needs an id") }
        lock.lock()
        if let existing = jobs[id] { lock.unlock(); return reply.send(existing.view) }
        let job = Job(id: id)
        job.artifact = artifact.id
        jobs[id] = job
        lock.unlock()
        reply.send(job.view)
        queue.async {
            do {
                try body(job)
                self.update(job) { $0.progress = 1; $0.state = "done" }
            } catch {
                self.update(job) { $0.error = error.localizedDescription; $0.state = "failed" }
            }
        }
    }

    private func read(_ id: String) -> Job? { lock.lock(); defer { lock.unlock() }; return jobs[id] }
    private func update(_ job: Job, _ change: (Job) -> Void) { lock.lock(); change(job); lock.unlock() }
    private func isCancelled(_ job: Job) -> Bool { lock.lock(); defer { lock.unlock() }; return job.cancelled }

    private var loadedId: String? {
        switch loaded {
        case .speech(let id, _), .writer(let id, _): return id
        case nil: return nil
        }
    }

    private func speech(_ artifact: Artifact) throws -> Speech {
        if case .speech(artifact.id, let speech) = loaded { return speech }
        guard ModelStore.installed(artifact) else { throw EngineError("The speech model is not downloaded.") }
        loaded = nil
        let speech = try Speech(artifact)
        loaded = .speech(artifact.id, speech)
        return speech
    }

    private func writer(_ artifact: Artifact) throws -> Writer {
        if case .writer(artifact.id, let writer) = loaded { return writer }
        guard ModelStore.installed(artifact) else { throw EngineError("The notes model is not downloaded.") }
        loaded = nil
        let writer = try Writer(artifact)
        loaded = .writer(artifact.id, writer)
        return writer
    }

    /// An `app:/data/…` path as a file URL in this session's data directory.
    private func file(_ path: String?) -> URL? {
        let prefix = "app:/data/"
        guard let path, path.hasPrefix(prefix), !path.contains("..") else { return nil }
        return context.data.appendingPathComponent(String(path.dropFirst(prefix.count)))
    }

    private func probe() -> [String: Any] {
        let free = (try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage ?? 0
        #if os(macOS)
        let host = "macos", formFactor = "desktop"
        #else
        let host = "ios", formFactor = "phone"
        #endif
        #if arch(arm64)
        let appleSilicon = true
        #else
        let appleSilicon = false
        #endif
        // A file named demo-engine in the data folder makes the app use its demo engine.
        // tools/flows.mjs writes it so the flow captures need no models and take seconds.
        let demo = FileManager.default.fileExists(atPath: context.data.appendingPathComponent("demo-engine").path)
        return ["host": host, "formFactor": formFactor, "appleSilicon": appleSilicon, "iosBrowser": false, "demo": demo,
                "memoryGB": Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824,
                "cores": ProcessInfo.processInfo.processorCount, "gpu": true, "gpuMaxBufferGB": 0,
                "storageFreeGB": Double(free) / 1_000_000_000, "description": chip()]
    }

    private func chip() -> String {
        for name in ["machdep.cpu.brand_string", "hw.machine"] {
            var size = 0
            guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { continue }
            var buffer = [CChar](repeating: 0, count: size)
            sysctlbyname(name, &buffer, &size, nil, 0)
            let value = String(cString: buffer)
            if !value.isEmpty { return value }
        }
        return ""
    }
}

let exactModule: ExactModule.Type = Engine.self
