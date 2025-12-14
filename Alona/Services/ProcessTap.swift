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

    var isRunning: Bool { objectID.readProcessIsRunning() }
    var isUsingMicrophone: Bool { objectID.readProcessIsRunningInput() }

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
        allRunning().first { $0.bundleIdentifier == bundleIdentifier }
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
        logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Alona", category: "ProcessTap(\(process.name))")
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
        guard !activated else { return }
        activated = true

        logger.debug("\(#function)")

        errorMessage = nil

        do {
            try prepare(for: process.objectID)
        } catch {
            logger.error("\(error, privacy: .public)")
            errorMessage = error.localizedDescription
        }
    }

    func invalidate() {
        guard activated else { return }
        defer { activated = false }

        logger.debug("\(#function)")

        invalidationHandler?(self)
        invalidationHandler = nil

        if aggregateDeviceID.isValid {
            var err = AudioDeviceStop(aggregateDeviceID, deviceProcID)
            if err != noErr { logger.warning("Failed to stop aggregate device: \(err, privacy: .public)") }

            if let deviceProcID {
                err = AudioDeviceDestroyIOProcID(aggregateDeviceID, deviceProcID)
                if err != noErr { logger.warning("Failed to destroy device I/O proc: \(err, privacy: .public)") }
                self.deviceProcID = nil
            }

            err = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            if err != noErr {
                logger.warning("Failed to destroy aggregate device: \(err, privacy: .public)")
            }
            aggregateDeviceID = .unknown
        }

        if processTapID.isValid {
            let err = AudioHardwareDestroyProcessTap(processTapID)
            if err != noErr {
                logger.warning("Failed to destroy audio tap: \(err, privacy: .public)")
            }
            processTapID = .unknown
        }
    }

    private func prepare(for objectID: AudioObjectID) throws {
        errorMessage = nil

        let tapDescription = CATapDescription(stereoMixdownOfProcesses: [objectID])
        tapDescription.uuid = UUID()
        tapDescription.muteBehavior = muteWhenRunning ? .mutedWhenTapped : .unmuted
        var tapID: AUAudioObjectID = .unknown
        var err = AudioHardwareCreateProcessTap(tapDescription, &tapID)

        guard err == noErr else {
            throw CoreAudioError.tapCreationFailed(err)
        }

        logger.debug("Created process tap #\(tapID, privacy: .public)")

        processTapID = tapID

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

        tapStreamDescription = try tapID.readAudioTapStreamBasicDescription()

        aggregateDeviceID = AudioObjectID.unknown
        err = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateDeviceID)
        guard err == noErr else {
            throw CoreAudioError.aggregateDeviceFailed(err)
        }

        let deviceID = aggregateDeviceID
        logger.debug("Created aggregate device #\(deviceID, privacy: .public)")
    }

    func run(on queue: DispatchQueue, ioBlock: @escaping AudioDeviceIOBlock, invalidationHandler: @escaping InvalidationHandler) throws {
        assert(activated, "\(#function) called with inactive tap!")
        assert(self.invalidationHandler == nil, "\(#function) called with tap already active!")

        errorMessage = nil

        logger.debug("Run tap!")

        self.invalidationHandler = invalidationHandler

        var err = AudioDeviceCreateIOProcIDWithBlock(&deviceProcID, aggregateDeviceID, queue, ioBlock)
        guard err == noErr else { throw CoreAudioError.ioProcCreationFailed(err) }

        err = AudioDeviceStart(aggregateDeviceID, deviceProcID)
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
        process = tap.process
        self.fileURL = fileURL
        _tap = tap
        logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Alona", category: "ProcessTapRecorder(\(fileURL.lastPathComponent))")
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
        logger.debug("\(#function)")

        guard !isRecording else {
            logger.warning("\(#function, privacy: .public) while already recording")
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

        logger.info("Using audio format: \(format, privacy: .public)")

        let settings: [String: Any] = [
            AVFormatIDKey: streamDescription.mFormatID,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
        ]
        let file = try AVAudioFile(forWriting: fileURL, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: format.isInterleaved)

        currentFile = file

        try tap.run(on: queue) { [weak self] _, inInputData, _, _, _ in
            guard let self, let currentFile else { return }
            do {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inInputData, deallocator: nil) else {
                    throw RecordingError.bufferCreationFailed
                }

                try currentFile.write(from: buffer)
            } catch {
                logger.error("\(error, privacy: .public)")
            }
        } invalidationHandler: { [weak self] _ in
            guard let self else { return }
            handleInvalidation()
        }

        isRecording = true
    }

    func stop() {
        logger.debug("\(#function)")

        guard isRecording else { return }

        currentFile = nil

        isRecording = false

        do {
            try tap.invalidate()
        } catch {
            logger.error("Stop failed: \(error, privacy: .public)")
        }
    }

    private func handleInvalidation() {
        guard isRecording else { return }

        logger.debug("\(#function)")
    }
}
