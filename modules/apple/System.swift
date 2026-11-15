// The system seam in core/system.ts: a folder outside app storage, the Swift
// app's recordings, meeting detection and system audio. Ops start `sys.`. Only
// macOS answers with anything; iOS reports every capability off.
import AVFoundation
import Foundation
#if os(macOS)
import AppKit
import ApplicationServices
import CoreAudio
#endif

final class SystemOps {
    private let data: URL
    /// Under Exact's agent: no device is asked, so drives repeat and never prompt.
    private let agent: Bool
    private let changed: (String) -> Void
    private let io = DispatchQueue(label: "alona.system.io", qos: .userInitiated)
    /// Owns `detector` and `tap`. Separate from `io`, so a long mix never holds up starting a recording.
    private let control = DispatchQueue(label: "alona.system.control", qos: .userInitiated)
    #if os(macOS)
    private var detector: AnyObject?
    private var tap: AnyObject?
    #endif

    init(data: URL, agent: Bool, changed: @escaping (String) -> Void) {
        self.data = data
        self.agent = agent
        self.changed = changed
    }

    /// An `app:/data/…` path in this session's data folder, or an absolute path. Nothing climbs out with `..`.
    func url(_ path: String?) -> URL? {
        guard let path, !path.split(separator: "/").contains("..") else { return nil }
        if path.hasPrefix("app:/data/") { return data.appendingPathComponent(String(path.dropFirst("app:/data/".count))) }
        #if os(macOS)
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        #endif
        return nil
    }

    func handle(_ op: String, _ request: [String: Any], _ reply: ExactReply) -> Bool {
        guard op.hasPrefix("sys.") else { return false }
        if op == "sys.facts" { reply.send(facts()); return true }
        #if os(macOS)
        switch op {
        case "sys.detect":
            control.async { reply.send(self.detect(enabled: request["enabled"] as? Bool ?? true)) }
        case "sys.captureStart":
            let target = url(request["path"] as? String)
            control.async { reply.send(["ok": target.map(self.startCapture) ?? false]) }
        case "sys.captureStop":
            control.async { reply.send(self.stopCapture()) }
        default:
            io.async { reply.send(self.file(op, request)) }
        }
        #else
        reply.send(["error": "unsupported", "message": "Not on this device."])
        #endif
        return true
    }

    /// The session is ending: stop listening and close the system audio file.
    func end() {
        #if os(macOS)
        control.sync { detector = nil; _ = stopCapture() }
        #endif
    }

    private func facts() -> [String: Any] {
        #if os(macOS)
        let modern: Bool
        if #available(macOS 14.2, *) { modern = true } else { modern = false }
        return ["folders": true, "detection": modern, "capture": modern, "legacyFolder": legacyFolder(),
                "accessibility": AXIsProcessTrusted()]
        #else
        return ["folders": false, "detection": false, "capture": false, "legacyFolder": "", "accessibility": false]
        #endif
    }

    #if os(macOS)
    /// The Swift app (`com.alona.mac`) saved its folder as a plain path, else used ~/Documents/Alona.
    /// Only the path: reading inside ~/Documents makes macOS ask the person, so that waits for them to ask.
    private func legacyFolder() -> String {
        let saved = UserDefaults(suiteName: "com.alona.mac")?.string(forKey: "meetingSaveDirectory") ?? ""
        return saved.isEmpty ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Alona").path : saved
    }

    private func failure(_ error: Error) -> [String: Any] {
        let ns = error as NSError
        let missing = (ns.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(ns.code))
            || (ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOENT))
        let denied = ns.domain == NSCocoaErrorDomain && [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(ns.code)
        return ["error": missing ? "ENOENT" : denied ? "EACCES" : "failed", "message": error.localizedDescription]
    }

    private func file(_ op: String, _ request: [String: Any]) -> [String: Any] {
        let fm = FileManager.default
        do {
            switch op {
            case "sys.read":
                guard let u = url(request["path"] as? String) else { return ["error": "EINVAL"] }
                return ["text": try String(contentsOf: u, encoding: .utf8)]
            case "sys.write":
                guard let u = url(request["path"] as? String), let text = request["text"] as? String else { return ["error": "EINVAL"] }
                try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(text.utf8).write(to: u, options: .atomic)
                return [:]
            case "sys.list":
                guard let u = url(request["path"] as? String) else { return ["error": "EINVAL"] }
                return ["names": try fm.contentsOfDirectory(atPath: u.path)]
            case "sys.mkdir":
                guard let u = url(request["path"] as? String) else { return ["error": "EINVAL"] }
                try fm.createDirectory(at: u, withIntermediateDirectories: true)
                return [:]
            case "sys.rm":
                guard let u = url(request["path"] as? String) else { return ["error": "EINVAL"] }
                try fm.removeItem(at: u)
                return [:]
            case "sys.copy":
                guard let from = url(request["from"] as? String), let to = url(request["to"] as? String) else { return ["error": "EINVAL"] }
                try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(atPath: to.path) { try fm.removeItem(at: to) }
                try fm.copyItem(at: from, to: to)
                return [:]
            case "sys.move":
                guard let from = url(request["from"] as? String), let to = url(request["to"] as? String) else { return ["error": "EINVAL"] }
                try move(from, to)
                return [:]
            case "sys.audioInfo":
                guard let u = url(request["path"] as? String) else { return ["error": "EINVAL"] }
                let file = try AVAudioFile(forReading: u)
                let created = (try? fm.attributesOfItem(atPath: u.path)[.creationDate] as? Date) ?? nil
                return ["seconds": Double(file.length) / file.processingFormat.sampleRate,
                        "createdMs": (created?.timeIntervalSince1970 ?? 0) * 1000]
            case "sys.mix":
                guard let mic = url(request["mic"] as? String), let sys = url(request["system"] as? String),
                      let out = url(request["out"] as? String) else { return ["error": "EINVAL"] }
                try Mixer.mix(mic: mic, system: sys, offsetMs: (request["offsetMs"] as? NSNumber)?.doubleValue ?? 0, out: out)
                return [:]
            default:
                return ["error": "unsupported", "message": "unknown op \(op)"]
            }
        } catch {
            return failure(error)
        }
    }

    /// Copies to `<to>.moving`, renames that into place, then removes the source. A crash leaves either
    /// the source alone, or both, which the library resolves by keeping the destination.
    private func move(_ from: URL, _ to: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: to.path) { try fm.removeItem(at: from); return }
        let partial = to.appendingPathExtension("moving")
        if fm.fileExists(atPath: partial.path) { try fm.removeItem(at: partial) }
        try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: from, to: partial)
        try fm.moveItem(at: partial, to: to)
        try fm.removeItem(at: from)
    }

    private func detect(enabled: Bool) -> [String: Any] {
        guard enabled else { detector = nil; return [:] }
        // tools/flows.mjs writes this file so a flow can show a detected call without one.
        let fixture = data.appendingPathComponent("detect-fixture.json")
        if let raw = try? Data(contentsOf: fixture), let found = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] {
            return found
        }
        guard #available(macOS 14.2, *), !agent else { return [:] }
        if detector == nil { detector = Detector { [weak self] in self?.changed("meeting") } }
        return (detector as? Detector)?.current() ?? [:]
    }

    private func startCapture(_ target: URL) -> Bool {
        guard #available(macOS 14.2, *), tap == nil else { return false }
        do {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            tap = agent ? StandInTap(url: target) as Tap : try SystemTap(url: target)
            return true
        } catch {
            NSLog("Alona: system audio did not start: \(error)")
            return false
        }
    }

    private func stopCapture() -> [String: Any] {
        guard #available(macOS 14.2, *), let running = tap as? Tap else { return ["path": ""] }
        tap = nil
        let result = running.stop()
        return ["path": result.frames > 0 ? "app:/data/" + running.url.path.dropFirst(data.path.count + 1) : "",
                "offsetMs": result.offsetMs, "health": result.peak > 0 ? "heard" : "silent"]
    }
    #endif
}

#if os(macOS)
private func property<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: inout T) -> Bool {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<T>.size)
    return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr
}

/// Which meeting app has the microphone open. It listens instead of polling: Core Audio calls back
/// when a process starts or stops using input, and NSWorkspace when an app launches or quits.
@available(macOS 14.2, *)
final class Detector {
    private let onChange: () -> Void
    private var watched: Set<AudioObjectID> = []
    private var observers: [NSObjectProtocol] = []
    private let queue = DispatchQueue(label: "alona.detector")
    private lazy var listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.refresh() }

    private static let apps: [(prefix: String, app: String, name: String)] = [
        ("us.zoom.", "zoom", "Zoom"),
        ("com.microsoft.teams", "teams", "Microsoft Teams"),
        ("com.google.Chrome", "browser", "Google Chrome"),
        ("company.thebrowser.", "browser", "Arc"),
        ("com.microsoft.edgemac", "browser", "Microsoft Edge"),
        ("com.brave.Browser", "browser", "Brave"),
        ("org.mozilla.firefox", "browser", "Firefox"),
        ("com.apple.Safari", "browser", "Safari"),
    ]

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in self?.onChange() })
        }
        queue.sync { watchProcesses() }
    }

    deinit {
        var list = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &list, queue, listener)
        var input = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningInput, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        for process in watched { AudioObjectRemovePropertyListenerBlock(process, &input, queue, listener) }
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
    }

    private func refresh() {
        watchProcesses()
        onChange()
    }

    private func processes() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private func watchProcesses() {
        var input = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningInput, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        for process in processes() where !watched.contains(process) {
            if AudioObjectAddPropertyListenerBlock(process, &input, queue, listener) == noErr { watched.insert(process) }
        }
    }

    private func bundle(_ process: AudioObjectID) -> String {
        var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &value) == noErr, let value else { return "" }
        return value.takeRetainedValue() as String
    }

    func current() -> [String: Any] {
        let own = ProcessInfo.processInfo.processIdentifier
        var found: [(app: String, name: String, pid: pid_t)] = []
        for process in processes() {
            var running: UInt32 = 0
            var pid: pid_t = 0
            guard property(process, kAudioProcessPropertyIsRunningInput, &running), running != 0,
                  property(process, kAudioProcessPropertyPID, &pid), pid != own else { continue }
            let id = bundle(process)
            if let match = Detector.apps.first(where: { id.hasPrefix($0.prefix) }) { found.append((match.app, match.name, pid)) }
        }
        if let zoom = found.first(where: { $0.app == "zoom" }) { return ["app": "zoom", "title": "Zoom meeting", "pid": zoom.pid] }
        if let teams = found.first(where: { $0.app == "teams" }) { return ["app": "teams", "title": "Teams call", "pid": teams.pid] }
        if let browser = found.first {
            if let title = meetTitle(browser.name) { return ["app": "meet", "title": title] }
            return ["app": "browser", "title": "A call in \(browser.name)"]
        }
        if AXIsProcessTrusted(), zoomInMeeting() { return ["app": "zoom", "title": "Zoom meeting"] }
        return [:]
    }

    /// With Accessibility, a browser window titled for Google Meet names the call. Without it, nothing.
    private func meetTitle(_ browser: String) -> String? {
        guard AXIsProcessTrusted(),
              let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == browser }) else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var windows: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &windows) == .success,
              let list = windows as? [AXUIElement] else { return nil }
        for window in list {
            var title: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title) == .success,
                  let text = title as? String else { continue }
            if text.hasPrefix("Meet - ") { return String(text.dropFirst("Meet - ".count)).components(separatedBy: " - ").first }
            if text.contains("Google Meet") { return "Google Meet" }
        }
        return nil
    }

    /// A muted Zoom call has no microphone running. Its menu bar then has a Meeting menu, which Accessibility can see.
    private func zoomInMeeting() -> Bool {
        guard let zoom = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "us.zoom.xos" }) else { return false }
        let element = AXUIElementCreateApplication(zoom.processIdentifier)
        var bar: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXMenuBarAttribute as CFString, &bar) == .success, let bar else { return false }
        var items: CFTypeRef?
        guard AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &items) == .success,
              let list = items as? [AXUIElement] else { return false }
        return list.contains { item in
            var title: CFTypeRef?
            return AXUIElementCopyAttributeValue(item, kAXTitleAttribute as CFString, &title) == .success && (title as? String) == "Meeting"
        }
    }
}

struct Stopped { let frames: Int64; let peak: Float; let offsetMs: Double }

protocol Tap: AnyObject {
    var url: URL { get }
    func stop() -> Stopped
}

/// What the agent records instead of the Mac's sound: a quiet 1500 Hz tone (the agent's microphone plays 440 Hz) as long as the
/// recording, written in chunks, so a drive proves the mix without the System Audio prompt.
final class StandInTap: Tap {
    let url: URL
    private let started = Date()

    init(url: URL) { self.url = url }

    func stop() -> Stopped {
        let rate = 48_000.0, seconds = max(Date().timeIntervalSince(started), 1)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1]
        guard let file = try? AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else { return Stopped(frames: 0, peak: 0, offsetMs: 0) }
        let total = Int64(seconds * rate)
        var written: Int64 = 0
        while written < total {
            let n = AVAudioFrameCount(min(Int64(buffer.frameCapacity), total - written))
            let p = buffer.floatChannelData![0]
            for i in 0..<Int(n) { p[i] = 0.1 * sin(2 * .pi * 1500 * Float(written + Int64(i)) / Float(rate)) }
            buffer.frameLength = n
            guard (try? file.write(from: buffer)) != nil else { break }
            written += Int64(n)
        }
        return Stopped(frames: written, peak: 0.1, offsetMs: 0)
    }
}

/// Records what the Mac plays through a Core Audio process tap, straight to an AAC file. Each
/// callback's buffer goes to ExtAudioFile's own bounded async writer, so nothing accumulates in
/// memory however long the meeting runs. Alona's own sound is excluded from the tap.
@available(macOS 14.2, *)
final class SystemTap: Tap {
    let url: URL
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var file: ExtAudioFileRef?
    private let queue = DispatchQueue(label: "alona.tap", qos: .userInitiated)
    private let asked = DispatchTime.now()
    private var firstAt: DispatchTime?
    private var frames: Int64 = 0
    private var peak: Float = 0

    enum TapError: Error { case status(String, OSStatus) }

    private static func check(_ status: OSStatus, _ what: String) throws {
        if status != noErr { throw TapError.status(what, status) }
    }

    init(url: URL) throws {
        self.url = url
        var own = AudioObjectID(kAudioObjectUnknown)
        var pid = ProcessInfo.processInfo.processIdentifier
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &own)

        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: own == kAudioObjectUnknown ? [] : [own])
        description.uuid = UUID()
        description.muteBehavior = .unmuted
        description.isPrivate = true
        description.name = "Alona system audio"
        do {
            try Self.check(AudioHardwareCreateProcessTap(description, &tapID), "create the tap")
            var format = AudioStreamBasicDescription()
            guard property(tapID, kAudioTapPropertyFormat, &format) else { throw TapError.status("read the tap format", -1) }

            let aggregate: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Alona system audio",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]],
            ]
            try Self.check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &deviceID), "create the device")

            var aac = AudioStreamBasicDescription(mSampleRate: format.mSampleRate, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0,
                                                  mBytesPerPacket: 0, mFramesPerPacket: 1024, mBytesPerFrame: 0,
                                                  mChannelsPerFrame: min(format.mChannelsPerFrame, 2), mBitsPerChannel: 0, mReserved: 0)
            try Self.check(ExtAudioFileCreateWithURL(url as CFURL, kAudioFileM4AType, &aac, nil, AudioFileFlags.eraseFile.rawValue, &file), "create the file")
            try Self.check(ExtAudioFileSetProperty(file!, kExtAudioFileProperty_ClientDataFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &format), "set the file format")
            try Self.check(ExtAudioFileWriteAsync(file!, 0, nil), "prime the writer")

            let bytesPerFrame = max(format.mBytesPerFrame, 1)
            let isFloat = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
            try Self.check(AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, queue) { [weak self] _, input, _, _, _ in
                guard let self, let file = self.file else { return }
                let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
                guard let first = list.first, first.mDataByteSize > 0 else { return }
                let count = first.mDataByteSize / bytesPerFrame
                if self.firstAt == nil { self.firstAt = .now() }
                if isFloat, self.peak == 0, let samples = first.mData?.assumingMemoryBound(to: Float.self) {
                    let n = Int(first.mDataByteSize) / MemoryLayout<Float>.size
                    for i in 0..<n where samples[i] != 0 { self.peak = abs(samples[i]); break }
                }
                if ExtAudioFileWriteAsync(file, count, input) == noErr { self.frames += Int64(count) }
            }, "create the callback")
            try Self.check(AudioDeviceStart(deviceID, procID), "start")
        } catch {
            teardown()
            throw error
        }
    }

    private func teardown() {
        if let procID { AudioDeviceStop(deviceID, procID); AudioDeviceDestroyIOProcID(deviceID, procID) }
        procID = nil
        if deviceID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(deviceID) }
        deviceID = AudioObjectID(kAudioObjectUnknown)
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        tapID = AudioObjectID(kAudioObjectUnknown)
        queue.sync {}
        if let file { ExtAudioFileDispose(file) }
        file = nil
    }

    func stop() -> Stopped {
        teardown()
        let offset = firstAt.map { Double($0.uptimeNanoseconds - asked.uptimeNanoseconds) / 1_000_000 } ?? 0
        return Stopped(frames: frames, peak: peak, offsetMs: offset)
    }
}
#endif

/// Mixes the microphone and system recordings into one AAC file, a few thousand frames at a time,
/// so memory stays the same for a five-minute meeting and a three-hour one.
enum Mixer {
    static let rate = 48_000.0
    static let chunk: AVAudioFrameCount = 4096

    private final class Source {
        let file: AVAudioFile
        let converter: AVAudioConverter
        let input: AVAudioPCMBuffer
        var lead: AVAudioFrameCount
        var done = false

        init(_ url: URL, to format: AVAudioFormat, leadFrames: AVAudioFrameCount) throws {
            file = try AVAudioFile(forReading: url)
            guard let converter = AVAudioConverter(from: file.processingFormat, to: format),
                  let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: Mixer.chunk) else {
                throw NSError(domain: "Alona", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot read \(url.lastPathComponent)"])
            }
            if file.processingFormat.channelCount == 2 {
                converter.downmix = true
            }
            self.converter = converter
            self.input = input
            lead = leadFrames
        }

        /// Fills `out` with up to its capacity: first the silence that aligns this source, then audio.
        func read(into out: AVAudioPCMBuffer) throws {
            out.frameLength = 0
            if lead > 0 {
                let n = min(lead, out.frameCapacity)
                memset(out.floatChannelData![0], 0, Int(n) * MemoryLayout<Float>.size)
                out.frameLength = n
                lead -= n
                return
            }
            guard !done else { return }
            var error: NSError?
            let status = converter.convert(to: out, error: &error) { _, outStatus in
                do {
                    try self.file.read(into: self.input, frameCount: Mixer.chunk)
                } catch {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                if self.input.frameLength == 0 { outStatus.pointee = .endOfStream; return nil }
                outStatus.pointee = .haveData
                return self.input
            }
            if let error { throw error }
            if status == .endOfStream || status == .error { done = true }
        }
    }

    static func mix(mic: URL, system: URL, offsetMs: Double, out: URL) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        let lead = AVAudioFrameCount(abs(offsetMs) * rate / 1000)
        let a = try Source(mic, to: format, leadFrames: offsetMs < 0 ? lead : 0)
        let b = try Source(system, to: format, leadFrames: offsetMs > 0 ? lead : 0)
        let partial = out.appendingPathExtension("partial")
        try? FileManager.default.removeItem(at: partial)
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 96_000]
        do {
            let writer = try AVAudioFile(forWriting: partial, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let x = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk)!
            let y = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk)!
            let mixed = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk)!
            while true {
                try a.read(into: x)
                try b.read(into: y)
                let n = max(x.frameLength, y.frameLength)
                if n == 0 && a.done && b.done { break }
                if n == 0 { continue }
                let px = x.floatChannelData![0], py = y.floatChannelData![0], pm = mixed.floatChannelData![0]
                for i in 0..<Int(n) {
                    let v = (i < Int(x.frameLength) ? px[i] : 0) + (i < Int(y.frameLength) ? py[i] : 0)
                    pm[i] = max(-1, min(1, v))
                }
                mixed.frameLength = n
                try writer.write(from: mixed)
            }
        }
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.moveItem(at: partial, to: out)
    }
}
