import AudioToolbox
import AVFoundation
import Foundation
import OSLog

/// Represents an audio process that can be tapped.
struct AudioProcess: Identifiable, Hashable {
    let id: pid_t
    let objectID: AudioObjectID
    let name: String
    let bundleIdentifier: String?

    var isRunning: Bool { self.objectID.readProcessIsRunning() }
    var isUsingMicrophone: Bool { self.objectID.readProcessIsRunningInput() }

    static func allRunning() -> [AudioProcess] {
        guard let objectIDs = try? AudioObjectID.readProcessList() else { return [] }
        return objectIDs.compactMap { objectID -> AudioProcess? in
            guard objectID.readProcessIsRunning() else { return nil }
            let bundleID = objectID.readProcessBundleID()
            // Get PID from process object
            guard let pid = try? objectID.read(kAudioProcessPropertyPID, defaultValue: pid_t(0)) else { return nil }
            let name = bundleID?.components(separatedBy: ".").last ?? "Unknown"
            return AudioProcess(id: pid, objectID: objectID, name: name, bundleIdentifier: bundleID)
        }
    }

    static func find(bundleIdentifier: String) -> AudioProcess? {
        self.allRunning().first { $0.bundleIdentifier == bundleIdentifier }
    }
}

/// Taps audio from a specific process using CoreAudio Process Taps (macOS 14.4+).
/// This triggers "System Audio Recording Only" permission instead of "Screen & System Audio Recording".
@Observable
final class ProcessTap {
    typealias InvalidationHandler = (ProcessTap) -> Void

    let process: AudioProcess
    let muteWhenRunning: Bool
    private let logger: Logger

    private(set) var errorMessage: String?

    init(process: AudioProcess, muteWhenRunning: Bool = false) {
        self.process = process
        self.muteWhenRunning = muteWhenRunning
        self.logger = Logger(
            subsystem: Bundle.main.bundleIdentifier ?? "Alona",
            category: "ProcessTap(\(process.name))")
    }

    @ObservationIgnored
    private var processTapID: AudioObjectID = .unknown
    @ObservationIgnored
    private var aggregateDeviceID = AudioObjectID.unknown
    @ObservationIgnored
    private var deviceProcID: AudioDeviceIOProcID?
    @ObservationIgnored
    private(set) var tapStreamDescription: AudioStreamBasicDescription?
    @ObservationIgnored
    private var invalidationHandler: InvalidationHandler?

    @ObservationIgnored
    private(set) var activated = false

    @MainActor
    func activate() {
        guard !self.activated else { return }
        self.activated = true

        self.logger.debug("\(#function)")

        self.errorMessage = nil

        do {
            try self.prepare(for: self.process.objectID)
        } catch {
            self.logger.error("\(error, privacy: .public)")
            self.errorMessage = error.localizedDescription
        }
    }

    func invalidate() {
        guard self.activated else { return }
        defer { activated = false }

        self.logger.debug("\(#function)")

        self.invalidationHandler?(self)
        self.invalidationHandler = nil

        if self.aggregateDeviceID.isValid {
            var err = AudioDeviceStop(aggregateDeviceID, deviceProcID)
            if err != noErr { self.logger.warning("Failed to stop aggregate device: \(err, privacy: .public)") }

            if let deviceProcID {
                err = AudioDeviceDestroyIOProcID(self.aggregateDeviceID, deviceProcID)
                if err != noErr { self.logger.warning("Failed to destroy device I/O proc: \(err, privacy: .public)") }
                self.deviceProcID = nil
            }

            err = AudioHardwareDestroyAggregateDevice(self.aggregateDeviceID)
            if err != noErr {
                self.logger.warning("Failed to destroy aggregate device: \(err, privacy: .public)")
            }
            self.aggregateDeviceID = .unknown
        }

        if self.processTapID.isValid {
            let err = AudioHardwareDestroyProcessTap(processTapID)
            if err != noErr {
                self.logger.warning("Failed to destroy audio tap: \(err, privacy: .public)")
            }
            self.processTapID = .unknown
        }
    }

    private func prepare(for objectID: AudioObjectID) throws {
        self.errorMessage = nil

        let tapDescription = CATapDescription(stereoMixdownOfProcesses: [objectID])
        tapDescription.uuid = UUID()
        tapDescription.muteBehavior = self.muteWhenRunning ? .mutedWhenTapped : .unmuted
        var tapID: AUAudioObjectID = .unknown
        var err = AudioHardwareCreateProcessTap(tapDescription, &tapID)

        guard err == noErr else {
            throw CoreAudioError.tapCreationFailed(err)
        }

        self.logger.debug("Created process tap #\(tapID, privacy: .public)")

        self.processTapID = tapID

        let systemOutputID = try AudioDeviceID.readDefaultSystemOutputDevice()

        let outputUID = try systemOutputID.readDeviceUID()

        let aggregateUID = UUID().uuidString

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Alona-Tap-\(process.id)",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [
                    kAudioSubDeviceUIDKey: outputUID,
                ],
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapDescription.uuid.uuidString,
                ],
            ],
        ]

        self.tapStreamDescription = try tapID.readAudioTapStreamBasicDescription()

        self.aggregateDeviceID = AudioObjectID.unknown
        err = AudioHardwareCreateAggregateDevice(description as CFDictionary, &self.aggregateDeviceID)
        guard err == noErr else {
            throw CoreAudioError.aggregateDeviceFailed(err)
        }

        let deviceID = self.aggregateDeviceID
        self.logger.debug("Created aggregate device #\(deviceID, privacy: .public)")
    }

    func run(
        on queue: DispatchQueue,
        ioBlock: @escaping AudioDeviceIOBlock,
        invalidationHandler: @escaping InvalidationHandler) throws
    {
        assert(self.activated, "\(#function) called with inactive tap!")
        assert(self.invalidationHandler == nil, "\(#function) called with tap already active!")

        self.errorMessage = nil

        self.logger.debug("Run tap!")

        self.invalidationHandler = invalidationHandler

        var err = AudioDeviceCreateIOProcIDWithBlock(&self.deviceProcID, self.aggregateDeviceID, queue, ioBlock)
        guard err == noErr else { throw CoreAudioError.ioProcCreationFailed(err) }

        err = AudioDeviceStart(self.aggregateDeviceID, self.deviceProcID)
        guard err == noErr else { throw CoreAudioError.deviceStartFailed(err) }
    }

    deinit { invalidate() }
}

/// Recorder that uses ProcessTap to capture audio to a file.
@Observable
final class ProcessTapRecorder {
    let fileURL: URL
    let process: AudioProcess
    private let queue = DispatchQueue(label: "ProcessTapRecorder", qos: .userInitiated)
    private let logger: Logger

    @ObservationIgnored
    private weak var _tap: ProcessTap?

    private(set) var isRecording = false

    init(fileURL: URL, tap: ProcessTap) {
        self.process = tap.process
        self.fileURL = fileURL
        self._tap = tap
        self.logger = Logger(
            subsystem: Bundle.main.bundleIdentifier ?? "Alona",
            category: "ProcessTapRecorder(\(fileURL.lastPathComponent))")
    }

    private var tap: ProcessTap {
        get throws {
            guard let _tap else { throw RecordingError.tapUnavailable }
            return _tap
        }
    }

    @ObservationIgnored
    private var currentFile: AVAudioFile?

    @MainActor
    func start() throws {
        self.logger.debug("\(#function)")

        guard !self.isRecording else {
            self.logger.warning("\(#function, privacy: .public) while already recording")
            return
        }

        let tap = try tap

        if !tap.activated { tap.activate() }

        guard var streamDescription = tap.tapStreamDescription else {
            throw RecordingError.streamDescriptionUnavailable
        }

        guard let format = AVAudioFormat(streamDescription: &streamDescription) else {
            throw RecordingError.formatCreationFailed
        }

        self.logger.info("Using audio format: \(format, privacy: .public)")

        let settings: [String: Any] = [
            AVFormatIDKey: streamDescription.mFormatID,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
        ]
        let file = try AVAudioFile(
            forWriting: fileURL,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: format.isInterleaved)

        self.currentFile = file

        try tap.run(on: self.queue) { [weak self] _, inInputData, _, _, _ in
            guard let self, let currentFile else { return }
            do {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inInputData, deallocator: nil)
                else {
                    throw RecordingError.bufferCreationFailed
                }

                try currentFile.write(from: buffer)
            } catch {
                self.logger.error("\(error, privacy: .public)")
            }
        } invalidationHandler: { [weak self] _ in
            guard let self else { return }
            self.handleInvalidation()
        }

        self.isRecording = true
    }

    func stop() {
        self.logger.debug("\(#function)")

        guard self.isRecording else { return }

        self.currentFile = nil

        self.isRecording = false

        do {
            try self.tap.invalidate()
        } catch {
            self.logger.error("Stop failed: \(error, privacy: .public)")
        }
    }

    private func handleInvalidation() {
        guard self.isRecording else { return }

        self.logger.debug("\(#function)")
    }
}
