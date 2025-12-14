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
    private var actualCaptureSampleRate: Double = 48000 // Will be set from actual mic format

    private let targetSampleRate: Double = 16000
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
    /// Prepare dual-channel writer - format will be updated once we know the actual mic sample rate
    func prepareDualChannelWriter(in directory: URL, sampleRate: Double = 48000) throws {
        let dualChannelURL = directory.appendingPathComponent("recording.wav")
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channelCount,
            interleaved: false
        )!
        dualChannelFile = try AVAudioFile(forWriting: dualChannelURL, settings: format.settings)
        logger.info("Prepared dual-channel writer at \(sampleRate) Hz")
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
            if format.mSampleRate == actualCaptureSampleRate {
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

    // MARK: - Microphone Capture with Voice Processing

    /// Start microphone capture - captures at native sample rate without real-time conversion
    /// Sample rate conversion is done during post-processing (mono mix creation)
    func startMicrophoneCapture() throws {
        logger.info("=== Starting Microphone Capture ===")

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode

        // Get the hardware format BEFORE enabling voice processing
        let hardwareFormat = inputNode.inputFormat(forBus: 0)
        logger.info("Hardware input format: \(hardwareFormat.sampleRate) Hz, \(hardwareFormat.channelCount) ch")

        // Only enable voice processing if we have a valid hardware format
        var voiceProcessingEnabled = false
        if hardwareFormat.sampleRate > 0 && hardwareFormat.channelCount > 0 {
            do {
                try inputNode.setVoiceProcessingEnabled(true)
                voiceProcessingEnabled = true
                logger.info("Voice processing enabled (AEC, noise suppression, AGC)")
            } catch {
                logger.warning("Failed to enable voice processing: \(error.localizedDescription)")
            }
        } else {
            logger.warning("Skipping voice processing - invalid hardware format")
        }

        // Get the format AFTER voice processing is enabled (it may change)
        var captureFormat = inputNode.outputFormat(forBus: 0)
        logger.info("Output format after voice processing: \(captureFormat.sampleRate) Hz, \(captureFormat.channelCount) ch")

        // If format is invalid after voice processing, disable it and use hardware format
        if captureFormat.sampleRate == 0 || captureFormat.channelCount == 0 {
            logger.warning("Invalid format after voice processing, disabling VP and using hardware format")
            if voiceProcessingEnabled {
                try? inputNode.setVoiceProcessingEnabled(false)
                voiceProcessingEnabled = false
            }
            captureFormat = hardwareFormat
        }

        // Final fallback if still invalid
        if captureFormat.sampleRate == 0 || captureFormat.channelCount == 0 {
            logger.error("Both formats invalid! Using 48kHz mono fallback")
            captureFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48000,
                channels: 1,
                interleaved: false
            )!
        }

        // Store the actual capture sample rate for writing
        actualCaptureSampleRate = captureFormat.sampleRate
        logger.info("Final capture format: \(captureFormat.sampleRate) Hz, \(captureFormat.channelCount) ch")

        // Re-prepare the dual channel writer with the actual capture sample rate
        if let directory = currentMeetingDirectory {
            do {
                try prepareDualChannelWriter(in: directory, sampleRate: actualCaptureSampleRate)
            } catch {
                logger.error("Failed to re-prepare dual channel writer: \(error.localizedDescription)")
            }
        }

        // Track if we've logged the first buffer
        var hasLoggedFirstBuffer = false
        var totalSamplesReceived = 0

        // Install tap at NATIVE sample rate - NO conversion during capture
        // This is the key fix: we capture exactly what the mic gives us
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: captureFormat) { [weak self] buffer, _ in
            guard let self else { return }

            // Log first buffer for debugging
            if !hasLoggedFirstBuffer {
                hasLoggedFirstBuffer = true
                self.logger.info("*** FIRST BUFFER *** frames: \(buffer.frameLength), format: \(buffer.format.sampleRate) Hz, \(buffer.format.channelCount) ch")
            }

            guard buffer.frameLength > 0 else {
                self.logger.warning("Received empty buffer")
                return
            }

            // Extract samples directly - no conversion
            guard let channelData = buffer.floatChannelData else {
                self.logger.error("No float channel data in buffer!")
                return
            }

            // If stereo, downmix to mono; otherwise use channel 0
            let samples: [Float]
            if buffer.format.channelCount >= 2, let ch0 = buffer.floatChannelData?[0], let ch1 = buffer.floatChannelData?[1] {
                // Stereo: average the two channels
                samples = (0 ..< Int(buffer.frameLength)).map { i in
                    (ch0[i] + ch1[i]) / 2.0
                }
            } else {
                // Mono: use channel 0 directly
                samples = Array(UnsafeBufferPointer(start: channelData[0], count: Int(buffer.frameLength)))
            }

            totalSamplesReceived += samples.count

            self.bufferQueue.async {
                self.micAudioBuffer.append(contentsOf: samples)
                if self.captureSystemAudio == false {
                    self.systemAudioBuffer.append(contentsOf: samples)
                }
                self.flushBuffersIfNeeded()
            }
        }

        do {
            try engine.start()
            logger.info("Audio engine started successfully")
        } catch {
            logger.error("Failed to start audio engine: \(error.localizedDescription)")
            throw error
        }

        audioEngine = engine
        logger.info("=== Microphone capture started (VP: \(voiceProcessingEnabled), rate: \(captureFormat.sampleRate) Hz) ===")
    }

    func stopMicrophoneCapture() {
        guard let engine = audioEngine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        audioEngine = nil
    }

    // MARK: - Buffer Management

    func flushBuffersIfNeeded() {
        // Flush in ~1 second chunks based on actual capture sample rate
        let flushThreshold = Int(actualCaptureSampleRate)
        guard micAudioBuffer.count >= flushThreshold else { return }

        if captureSystemAudio {
            guard systemAudioBuffer.count >= flushThreshold else { return }
        }

        let count = min(systemAudioBuffer.count, micAudioBuffer.count)
        if count > 0 {
            writeSamples(count: count)
        }
    }

    func flushRemainingBuffers() {
        let micCount = micAudioBuffer.count
        let sysCount = systemAudioBuffer.count
        logger.debug("Flushing remaining buffers - mic: \(micCount), system: \(sysCount)")
        guard micAudioBuffer.count > 0 else {
            logger.warning("No mic samples to flush")
            return
        }
        if captureSystemAudio {
            guard systemAudioBuffer.count > 0 else {
                logger.warning("No system audio samples to flush (captureSystemAudio=true)")
                return
            }
        } else if systemAudioBuffer.isEmpty {
            logger.debug("Copying mic buffer to system buffer (mic-only recording)")
            systemAudioBuffer = micAudioBuffer
        }
        let count = min(systemAudioBuffer.count, micAudioBuffer.count)
        logger.info("Writing \(count) samples to file")
        writeSamples(count: count)
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

    /// Creates a mono mix from the dual-channel recording, resampling to target sample rate (16kHz) for transcription
    func createMonoMix(in directory: URL) async throws {
        logger.info("Creating mono mix in \(directory.lastPathComponent)")

        let dualURL = directory.appendingPathComponent("recording.wav")
        let monoURL = directory.appendingPathComponent("recording-mono.wav")

        guard FileManager.default.fileExists(atPath: dualURL.path) else {
            logger.error("Source file doesn't exist: \(dualURL.path)")
            return
        }

        let sourceFile = try AVAudioFile(forReading: dualURL)
        let sourceSampleRate = sourceFile.processingFormat.sampleRate
        logger.info("Source file: \(sourceFile.length) frames at \(sourceSampleRate) Hz")

        // Target format for Whisper transcription (16kHz mono)
        // swiftformat:disable:next redundantSelf
        let targetRate = self.targetSampleRate
        let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetRate,
            channels: 1,
            interleaved: false
        )!

        let monoFile = try AVAudioFile(forWriting: monoURL, settings: monoFormat.settings)

        let sourceFrameCount = AVAudioFrameCount(sourceFile.length)
        guard sourceFrameCount > 0 else {
            logger.warning("Source file has 0 frames")
            return
        }

        guard
            let sourceBuffer = AVAudioPCMBuffer(
                pcmFormat: sourceFile.processingFormat,
                frameCapacity: sourceFrameCount
            )
        else {
            logger.error("Failed to create source buffer")
            return
        }

        try sourceFile.read(into: sourceBuffer)
        logger.info("Read \(sourceBuffer.frameLength) frames from source")

        // First, downmix stereo to mono at source sample rate
        let intermediateFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sourceSampleRate,
            channels: 1,
            interleaved: false
        )!

        guard let intermediateBuffer = AVAudioPCMBuffer(
            pcmFormat: intermediateFormat,
            frameCapacity: sourceBuffer.frameLength
        ) else {
            logger.error("Failed to create intermediate buffer")
            return
        }

        intermediateBuffer.frameLength = sourceBuffer.frameLength

        // Downmix stereo to mono
        if
            let ch0 = sourceBuffer.floatChannelData?[0],
            let ch1 = sourceBuffer.floatChannelData?[1],
            let monoData = intermediateBuffer.floatChannelData?[0]
        {
            AudioSampleMath.downmix(system: ch0, mic: ch1, destination: monoData, frameCount: Int(sourceBuffer.frameLength))
        } else {
            logger.error("Failed to access channel data for downmix")
            return
        }

        // Now resample from source rate to target rate (16kHz)
        if sourceSampleRate != targetRate {
            logger.info("Resampling from \(sourceSampleRate) Hz to \(targetRate) Hz")

            guard let converter = AVAudioConverter(from: intermediateFormat, to: monoFormat) else {
                logger.error("Failed to create resampling converter")
                return
            }

            // Calculate output frame count based on sample rate ratio
            let ratio = targetRate / sourceSampleRate
            let outputFrameCount = AVAudioFrameCount(Double(intermediateBuffer.frameLength) * ratio)

            guard let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: monoFormat,
                frameCapacity: outputFrameCount
            ) else {
                logger.error("Failed to create output buffer")
                return
            }

            var error: NSError?
            let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return intermediateBuffer
            }

            if status == .error {
                logger.error("Resampling failed: \(error?.localizedDescription ?? "unknown")")
                return
            }

            logger.info("Resampled to \(outputBuffer.frameLength) frames")
            try monoFile.write(from: outputBuffer)
        } else {
            // No resampling needed, write directly
            try monoFile.write(from: intermediateBuffer)
        }

        logger.info("Mono mix created successfully")
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
