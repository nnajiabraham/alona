import AudioToolbox
import AVFoundation
import Combine
import Foundation
import OSLog

protocol AudioRecordingController: AnyObject {
    var isRecordingPublisher: AnyPublisher<Bool, Never> { get }
    var recordingDurationPublisher: AnyPublisher<TimeInterval, Never> { get }
    var captureSystemAudio: Bool { get set }
    func startRecording(meetingTitle: String) async throws -> URL
    func stopRecording() async
}

/// Audio recorder that uses CoreAudio Process Taps (macOS 14.4+) for system audio capture.
/// This triggers "System Audio Recording Only" permission instead of "Screen & System Audio Recording".
final class AudioRecorder: NSObject, ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var recordingDuration: TimeInterval = 0
    var captureSystemAudio: Bool = true {
        didSet {
            if captureSystemAudio == false, systemAudioActive {
                Task { [weak self] in
                    await self?.stopSystemAudioCapture()
                    self?.systemAudioActive = false
                }
            }
        }
    }

    private let meetingFileManager: MeetingFileManager
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Alona", category: "AudioRecorder")
    private let bufferQueue = DispatchQueue(label: "com.alona.audio-buffer", qos: .userInitiated)
    private let systemAudioQueue = DispatchQueue(label: "com.alona.system-audio", qos: .userInitiated)

    // CoreAudio Process Tap state
    private var processTap: ProcessTap?
    private var processTapID: AudioObjectID = .unknown
    private var aggregateDeviceID: AudioObjectID = .unknown
    private var deviceProcID: AudioDeviceIOProcID?
    private var systemAudioActive = false

    // Microphone capture
    private var audioEngine: AVAudioEngine?

    // File writing
    private var dualChannelFile: AVAudioFile?
    private var durationTimer: Timer?
    private var systemAudioBuffer: [Float] = []
    private var micAudioBuffer: [Float] = []
    private var currentMeetingDirectory: URL?

    private let sampleRate: Double = 16000
    private let channelCount: AVAudioChannelCount = 2

    init(meetingFileManager: MeetingFileManager) {
        self.meetingFileManager = meetingFileManager
        super.init()
    }

    @MainActor
    func startRecording(meetingTitle: String) async throws -> URL {
        guard !isRecording else {
            return currentMeetingDirectory ?? meetingFileManager.baseDirectory
        }

        let directory = try meetingFileManager.createMeetingDirectory(title: meetingTitle)
        currentMeetingDirectory = directory
        systemAudioBuffer.removeAll(keepingCapacity: true)
        micAudioBuffer.removeAll(keepingCapacity: true)

        try prepareDualChannelWriter(in: directory)
        if captureSystemAudio {
            try await startSystemAudioCapture()
            systemAudioActive = true
        } else {
            systemAudioActive = false
        }
        try startMicrophoneCapture()
        startDurationTimer()

        DispatchQueue.main.async {
            self.isRecording = true
            self.recordingDuration = 0
        }

        return directory
    }

    @MainActor
    func stopRecording() async {
        guard isRecording else { return }

        if systemAudioActive {
            await stopSystemAudioCapture()
            systemAudioActive = false
        }
        stopMicrophoneCapture()
        stopDurationTimer()

        bufferQueue.sync {
            flushRemainingBuffers()
        }

        dualChannelFile = nil
        DispatchQueue.main.async {
            self.isRecording = false
        }

        if let directory = currentMeetingDirectory {
            try? await createMonoMix(in: directory)
        }
    }
}

// MARK: - Private helpers

private extension AudioRecorder {
    func prepareDualChannelWriter(in directory: URL) throws {
        let dualChannelURL = directory.appendingPathComponent("recording.wav")
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channelCount,
            interleaved: false
        )!
        dualChannelFile = try AVAudioFile(forWriting: dualChannelURL, settings: format.settings)
    }

    func startDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.recordingDuration += 1
            }
        }
    }

    func stopDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = nil
    }

    // MARK: - CoreAudio Process Tap System Audio Capture

    func startSystemAudioCapture() async throws {
        logger.debug("Starting system audio capture with CoreAudio Process Tap")

        // Create a process tap for global system audio (excluding our own process)
        let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        tapDescription.uuid = UUID()
        tapDescription.muteBehavior = .unmuted

        var tapID: AudioObjectID = .unknown
        var err = AudioHardwareCreateProcessTap(tapDescription, &tapID)

        guard err == noErr else {
            logger.error("Failed to create process tap: \(err)")
            throw RecordingError.processTapCreationFailed(err)
        }

        logger.debug("Created process tap #\(tapID)")
        processTapID = tapID

        // Get system output device
        let systemOutputID = try AudioDeviceID.readDefaultSystemOutputDevice()
        let outputUID = try systemOutputID.readDeviceUID()
        let aggregateUID = UUID().uuidString

        // Create aggregate device with the tap
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Alona-System-Audio-Tap",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID],
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapDescription.uuid.uuidString,
                ],
            ],
        ]

        aggregateDeviceID = .unknown
        err = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateDeviceID)

        guard err == noErr else {
            logger.error("Failed to create aggregate device: \(err)")
            // Cleanup tap
            AudioHardwareDestroyProcessTap(processTapID)
            processTapID = .unknown
            throw RecordingError.aggregateDeviceCreationFailed(err)
        }

        let createdDeviceID = aggregateDeviceID
        logger.debug("Created aggregate device #\(createdDeviceID)")

        // Get the tap's stream format
        let tapFormat = try tapID.readAudioTapStreamBasicDescription()
        logger.debug("Tap format: \(tapFormat.mSampleRate) Hz, \(tapFormat.mChannelsPerFrame) channels")

        // Create I/O proc to receive audio data
        err = AudioDeviceCreateIOProcIDWithBlock(&deviceProcID, aggregateDeviceID, systemAudioQueue) { [weak self] _, inInputData, _, _, _ in
            guard let self else { return }
            processSystemAudioBuffer(inInputData, format: tapFormat)
        }

        guard err == noErr else {
            logger.error("Failed to create device I/O proc: \(err)")
            cleanupSystemAudioCapture()
            throw RecordingError.ioProcCreationFailed(err)
        }

        // Start capture
        err = AudioDeviceStart(aggregateDeviceID, deviceProcID)

        guard err == noErr else {
            logger.error("Failed to start audio device: \(err)")
            cleanupSystemAudioCapture()
            throw RecordingError.deviceStartFailed(err)
        }

        logger.info("System audio capture started successfully")
    }

    func processSystemAudioBuffer(_ bufferList: UnsafePointer<AudioBufferList>, format: AudioStreamBasicDescription) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))

        for buffer in buffers {
            guard let data = buffer.mData else { continue }

            let frameCount = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size

            // Convert to our target sample rate if needed
            if format.mSampleRate == sampleRate {
                let floatPtr = data.assumingMemoryBound(to: Float.self)
                let samples = Array(UnsafeBufferPointer(start: floatPtr, count: frameCount))

                // If stereo, downmix to mono
                let monoSamples: [Float]
                if format.mChannelsPerFrame == 2 {
                    monoSamples = stride(from: 0, to: samples.count, by: 2).map { i in
                        (samples[i] + samples[min(i + 1, samples.count - 1)]) / 2.0
                    }
                } else {
                    monoSamples = samples
                }

                bufferQueue.async { [weak self] in
                    self?.systemAudioBuffer.append(contentsOf: monoSamples)
                    self?.flushBuffersIfNeeded()
                }
            } else {
                // TODO: Resample if needed - for now assume matching rates
                let floatPtr = data.assumingMemoryBound(to: Float.self)
                let channelCount = Int(format.mChannelsPerFrame)
                let sampleCount = frameCount / max(channelCount, 1)

                var monoSamples = [Float]()
                monoSamples.reserveCapacity(sampleCount)

                for i in 0 ..< sampleCount {
                    if channelCount == 2 {
                        let left = floatPtr[i * 2]
                        let right = floatPtr[i * 2 + 1]
                        monoSamples.append((left + right) / 2.0)
                    } else {
                        monoSamples.append(floatPtr[i])
                    }
                }

                bufferQueue.async { [weak self] in
                    self?.systemAudioBuffer.append(contentsOf: monoSamples)
                    self?.flushBuffersIfNeeded()
                }
            }
        }
    }

    func stopSystemAudioCapture() async {
        logger.debug("Stopping system audio capture")
        cleanupSystemAudioCapture()
    }

    func cleanupSystemAudioCapture() {
        if aggregateDeviceID.isValid {
            if let deviceProcID {
                AudioDeviceStop(aggregateDeviceID, deviceProcID)
                AudioDeviceDestroyIOProcID(aggregateDeviceID, deviceProcID)
                self.deviceProcID = nil
            }
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = .unknown
        }

        if processTapID.isValid {
            AudioHardwareDestroyProcessTap(processTapID)
            processTapID = .unknown
        }

        logger.debug("System audio capture cleaned up")
    }

    // MARK: - Microphone Capture

    func startMicrophoneCapture() throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        let desiredFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!

        let converter = AVAudioConverter(from: inputFormat, to: desiredFormat)

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard
                let self,
                let converter,
                let convertedBuffer = AVAudioPCMBuffer(
                    pcmFormat: desiredFormat,
                    frameCapacity: AVAudioFrameCount(buffer.frameLength)
                )
            else { return }

            var error: NSError?
            converter.convert(to: convertedBuffer, error: &error) { _, status in
                status.pointee = .haveData
                return buffer
            }

            if let channelData = convertedBuffer.floatChannelData?[0] {
                let samples = Array(UnsafeBufferPointer(start: channelData, count: Int(convertedBuffer.frameLength)))
                self.bufferQueue.async {
                    self.micAudioBuffer.append(contentsOf: samples)
                    if self.captureSystemAudio == false {
                        self.systemAudioBuffer.append(contentsOf: samples)
                    }
                    self.flushBuffersIfNeeded()
                }
            }
        }

        try engine.start()
        audioEngine = engine
    }

    func stopMicrophoneCapture() {
        guard let engine = audioEngine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        audioEngine = nil
    }

    // MARK: - Buffer Management

    func flushBuffersIfNeeded() {
        guard micAudioBuffer.count >= Int(sampleRate) else { return }
        if captureSystemAudio {
            guard systemAudioBuffer.count >= Int(sampleRate) else { return }
            writeSamples(count: min(systemAudioBuffer.count, micAudioBuffer.count))
        } else {
            writeSamples(count: min(systemAudioBuffer.count, micAudioBuffer.count))
        }
    }

    func flushRemainingBuffers() {
        guard micAudioBuffer.count > 0 else { return }
        if captureSystemAudio {
            guard systemAudioBuffer.count > 0 else { return }
        } else if systemAudioBuffer.isEmpty {
            systemAudioBuffer = micAudioBuffer
        }
        writeSamples(count: min(systemAudioBuffer.count, micAudioBuffer.count))
    }

    func writeSamples(count: Int) {
        guard
            let format = dualChannelFile?.processingFormat,
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))
        else { return }

        buffer.frameLength = AVAudioFrameCount(count)
        if let ch0 = buffer.floatChannelData?[0], let ch1 = buffer.floatChannelData?[1] {
            for index in 0 ..< count {
                ch0[index] = systemAudioBuffer[index]
                ch1[index] = micAudioBuffer[index]
            }
        }

        try? dualChannelFile?.write(from: buffer)
        systemAudioBuffer.removeFirst(count)
        micAudioBuffer.removeFirst(count)
    }

    func createMonoMix(in directory: URL) async throws {
        let dualURL = directory.appendingPathComponent("recording.wav")
        let monoURL = directory.appendingPathComponent("recording-mono.wav")
        let sourceFile = try AVAudioFile(forReading: dualURL)

        let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!
        let monoFile = try AVAudioFile(forWriting: monoURL, settings: monoFormat.settings)

        let frameCount = AVAudioFrameCount(sourceFile.length)
        guard
            let sourceBuffer = AVAudioPCMBuffer(
                pcmFormat: sourceFile.processingFormat,
                frameCapacity: frameCount
            ),
            let monoBuffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: frameCount)
        else { return }

        try sourceFile.read(into: sourceBuffer)
        monoBuffer.frameLength = sourceBuffer.frameLength

        if
            let ch0 = sourceBuffer.floatChannelData?[0],
            let ch1 = sourceBuffer.floatChannelData?[1],
            let monoData = monoBuffer.floatChannelData?[0]
        {
            AudioSampleMath.downmix(system: ch0, mic: ch1, destination: monoData, frameCount: Int(sourceBuffer.frameLength))
        }

        try monoFile.write(from: monoBuffer)
    }
}

// MARK: - AudioRecordingController Protocol

extension AudioRecorder: AudioRecordingController {
    var isRecordingPublisher: AnyPublisher<Bool, Never> {
        $isRecording.eraseToAnyPublisher()
    }

    var recordingDurationPublisher: AnyPublisher<TimeInterval, Never> {
        $recordingDuration.eraseToAnyPublisher()
    }
}

// MARK: - Math helpers

enum AudioSampleMath {
    static func downmix(system: UnsafePointer<Float>, mic: UnsafePointer<Float>, destination: UnsafeMutablePointer<Float>, frameCount: Int) {
        for index in 0 ..< frameCount {
            destination[index] = (system[index] + mic[index]) / 2.0
        }
    }

    static func averagedMono(system: [Float], mic: [Float]) -> [Float] {
        let count = min(system.count, mic.count)
        return (0 ..< count).map { (system[$0] + mic[$0]) / 2.0 }
    }
}

// MARK: - Errors

enum RecordingError: LocalizedError {
    case noDisplayFound
    case permissionDenied
    case processTapCreationFailed(OSStatus)
    case aggregateDeviceCreationFailed(OSStatus)
    case ioProcCreationFailed(OSStatus)
    case deviceStartFailed(OSStatus)
    case tapUnavailable
    case streamDescriptionUnavailable
    case formatCreationFailed
    case bufferCreationFailed

    var errorDescription: String? {
        switch self {
        case .noDisplayFound:
            return "Unable to locate a capture display."
        case .permissionDenied:
            return "Audio capture permission is required."
        case let .processTapCreationFailed(status):
            return "Failed to create process tap: error \(status)"
        case let .aggregateDeviceCreationFailed(status):
            return "Failed to create aggregate device: error \(status)"
        case let .ioProcCreationFailed(status):
            return "Failed to create I/O proc: error \(status)"
        case let .deviceStartFailed(status):
            return "Failed to start audio device: error \(status)"
        case .tapUnavailable:
            return "Process tap is unavailable."
        case .streamDescriptionUnavailable:
            return "Tap stream description not available."
        case .formatCreationFailed:
            return "Failed to create audio format."
        case .bufferCreationFailed:
            return "Failed to create audio buffer."
        }
    }
}
