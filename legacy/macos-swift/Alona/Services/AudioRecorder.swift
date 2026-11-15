import AudioToolbox
@preconcurrency import AVFoundation
import Combine
import Foundation
import Observation
import OSLog

protocol AudioRecordingController: AnyObject, Sendable {
    var isRecordingPublisher: AnyPublisher<Bool, Never> { get }
    var recordingDurationPublisher: AnyPublisher<TimeInterval, Never> { get }
    var captureSystemAudio: Bool { get set }
    func startRecording(meetingTitle: String) async throws -> URL
    func stopRecording() async
}

/// Audio recorder that uses CoreAudio Process Taps (macOS 14.4+) for system audio capture.
/// This triggers "System Audio Recording Only" permission instead of "Screen & System Audio Recording".
/// Note: Marked as @unchecked Sendable because it uses internal dispatch queues for thread safety.
/// Uses @Observable for SwiftUI observation and exposes Combine publishers for protocol-based consumption.
@Observable
final class AudioRecorder: @unchecked Sendable {
    private(set) var isRecording = false {
        didSet { self.isRecordingSubject.send(self.isRecording) }
    }

    private(set) var recordingDuration: TimeInterval = 0 {
        didSet { self.recordingDurationSubject.send(self.recordingDuration) }
    }

    @ObservationIgnored private let isRecordingSubject = CurrentValueSubject<Bool, Never>(false)
    @ObservationIgnored private let recordingDurationSubject = CurrentValueSubject<TimeInterval, Never>(0)
    var captureSystemAudio: Bool = true {
        didSet {
            if self.captureSystemAudio == false, self.systemAudioActive {
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

    // File writing - unified to single channel for reliability
    private var audioFile: AVAudioFile?
    private var dualChannelFile: AVAudioFile? // Deprecated, kept for compatibility
    private var durationTimer: Timer?
    private var systemAudioBuffer: [Float] = []
    private var micAudioBuffer: [Float] = []
    private var currentMeetingDirectory: URL?
    private var actualCaptureSampleRate: Double = 48000 // Will be set from actual mic format
    private var systemAudioSampleRate: Double = 48000 // Track system audio rate separately

    // Track samples written for debugging
    private var totalMicSamplesReceived: Int = 0
    private var totalSystemSamplesReceived: Int = 0
    private var totalSamplesWritten: Int = 0
    private var micCaptureStarted = false

    private let targetSampleRate: Double = 16000
    private let channelCount: AVAudioChannelCount = 2

    init(meetingFileManager: MeetingFileManager) {
        self.meetingFileManager = meetingFileManager
    }

    @MainActor
    func startRecording(meetingTitle: String) async throws -> URL {
        guard !self.isRecording else {
            return self.currentMeetingDirectory ?? self.meetingFileManager.baseDirectory
        }

        let directory = try meetingFileManager.createMeetingDirectory(title: meetingTitle)
        self.currentMeetingDirectory = directory
        self.systemAudioBuffer.removeAll(keepingCapacity: true)
        self.micAudioBuffer.removeAll(keepingCapacity: true)

        // Reset tracking counters
        self.totalMicSamplesReceived = 0
        self.totalSystemSamplesReceived = 0
        self.totalSamplesWritten = 0
        self.micCaptureStarted = false

        // Start microphone capture FIRST to establish sample rate
        try startMicrophoneCapture()

        // Now prepare the dual channel writer with the correct mic sample rate
        try prepareDualChannelWriter(in: directory, sampleRate: self.actualCaptureSampleRate)

        if self.captureSystemAudio {
            try await startSystemAudioCapture()
            self.systemAudioActive = true
        } else {
            self.systemAudioActive = false
        }
        startDurationTimer()

        DispatchQueue.main.async {
            self.isRecording = true
            self.recordingDuration = 0
        }

        let captureSys = self.captureSystemAudio
        let sampleRate = self.actualCaptureSampleRate
        self.logger.info("Recording started - captureSystemAudio: \(captureSys), sampleRate: \(sampleRate)")
        return directory
    }

    @MainActor
    func stopRecording() async {
        guard self.isRecording else { return }

        let micSamples = self.totalMicSamplesReceived
        let sysSamples = self.totalSystemSamplesReceived
        let writtenSamples = self.totalSamplesWritten
        self.logger.info(
            "Stopping recording - mic: \(micSamples), system: \(sysSamples), written: \(writtenSamples)")

        if self.systemAudioActive {
            await stopSystemAudioCapture()
            self.systemAudioActive = false
        }
        stopMicrophoneCapture()
        stopDurationTimer()

        self.bufferQueue.sync {
            flushRemainingBuffers()
        }

        let micBufCount = self.micAudioBuffer.count
        let sysBufCount = self.systemAudioBuffer.count
        let totalWritten = self.totalSamplesWritten
        self.logger.info(
            "Final stats - mic buf: \(micBufCount), sys buf: \(sysBufCount), written: \(totalWritten)")

        self.dualChannelFile = nil
        self.audioFile = nil
        DispatchQueue.main.async {
            self.isRecording = false
        }

        if let directory = currentMeetingDirectory {
            try? await createMonoMix(in: directory)
        }
    }
}

// MARK: - Private helpers

extension AudioRecorder {
    /// Prepare dual-channel writer - format will be updated once we know the actual mic sample rate
    private func prepareDualChannelWriter(in directory: URL, sampleRate: Double = 48000) throws {
        let dualChannelURL = directory.appendingPathComponent("recording.wav")
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channelCount,
            interleaved: false)! // swiftlint:disable:this force_unwrapping
        self.dualChannelFile = try AVAudioFile(forWriting: dualChannelURL, settings: format.settings)
        self.logger.info("Prepared dual-channel writer at \(sampleRate) Hz")
    }

    private func startDurationTimer() {
        self.durationTimer?.invalidate()
        self.durationTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.recordingDuration += 1
            }
        }
    }

    private func stopDurationTimer() {
        self.durationTimer?.invalidate()
        self.durationTimer = nil
    }

    // MARK: - CoreAudio Process Tap System Audio Capture

    private func startSystemAudioCapture() async throws {
        self.logger.debug("Starting system audio capture with CoreAudio Process Tap")

        // Create a process tap for global system audio (excluding our own process)
        // Using .unmuted ensures the tap LISTENS to audio without affecting playback
        let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        tapDescription.uuid = UUID()
        tapDescription.muteBehavior = .unmuted

        var tapID: AudioObjectID = .unknown
        var err = AudioHardwareCreateProcessTap(tapDescription, &tapID)

        guard err == noErr else {
            self.logger.error("Failed to create process tap: \(err)")
            throw RecordingError.processTapCreationFailed(err)
        }

        self.logger.debug("Created process tap #\(tapID)")
        self.processTapID = tapID

        // Get system output device UID - needed for tap reference
        let systemOutputID = try AudioDeviceID.readDefaultSystemOutputDevice()
        let outputUID = try systemOutputID.readDeviceUID()
        let aggregateUID = UUID().uuidString

        // Create a MINIMAL aggregate device with ONLY the tap
        // IMPORTANT: We do NOT include the output device as a sub-device
        // This prevents the aggregate device from interfering with live audio playback
        // The tap already captures the audio stream - we don't need to route through aggregate
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Alona-Tap-Only",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            // Reference the output device for the tap to know what to capture
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            // NO sub-device list - don't include output device as sub-device
            // This is the key fix: without sub-devices, audio routes normally to speakers
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: false, // Disable drift comp to reduce processing
                    kAudioSubTapUIDKey: tapDescription.uuid.uuidString,
                ],
            ],
        ]

        self.aggregateDeviceID = .unknown
        err = AudioHardwareCreateAggregateDevice(description as CFDictionary, &self.aggregateDeviceID)

        guard err == noErr else {
            self.logger.error("Failed to create aggregate device: \(err)")
            // Cleanup tap
            AudioHardwareDestroyProcessTap(self.processTapID)
            self.processTapID = .unknown
            throw RecordingError.aggregateDeviceCreationFailed(err)
        }

        let createdDeviceID = self.aggregateDeviceID
        self.logger.debug("Created tap-only aggregate device #\(createdDeviceID)")

        // Get the tap's stream format
        let tapFormat = try tapID.readAudioTapStreamBasicDescription()
        self.logger.debug("Tap format: \(tapFormat.mSampleRate) Hz, \(tapFormat.mChannelsPerFrame) channels")

        // Create I/O proc to receive audio data from the tap
        err = AudioDeviceCreateIOProcIDWithBlock(
            &self.deviceProcID,
            self.aggregateDeviceID,
            self.systemAudioQueue) { [weak self] _, inInputData, _, _, _ in
                guard let self else { return }
                self.processSystemAudioBuffer(inInputData, format: tapFormat)
            }

        guard err == noErr else {
            self.logger.error("Failed to create device I/O proc: \(err)")
            self.cleanupSystemAudioCapture()
            throw RecordingError.ioProcCreationFailed(err)
        }

        // Start capture
        err = AudioDeviceStart(self.aggregateDeviceID, self.deviceProcID)

        guard err == noErr else {
            self.logger.error("Failed to start audio device: \(err)")
            self.cleanupSystemAudioCapture()
            throw RecordingError.deviceStartFailed(err)
        }

        self.logger.info("System audio capture started successfully (tap-only mode, no playback interference)")
    }

    private func processSystemAudioBuffer(
        _ bufferList: UnsafePointer<AudioBufferList>,
        format: AudioStreamBasicDescription) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))

        for buffer in buffers {
            guard let data = buffer.mData else { continue }

            let floatPtr = data.assumingMemoryBound(to: Float.self)
            let channelCount = Int(format.mChannelsPerFrame)
            // For interleaved audio, total floats / channels = frames
            let totalFloats = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            let frameCount = channelCount > 0 ? totalFloats / channelCount : totalFloats

            guard frameCount > 0 else { continue }

            // Downmix to mono
            var monoSamples = [Float]()
            monoSamples.reserveCapacity(frameCount)

            for i in 0..<frameCount {
                if channelCount >= 2 {
                    let left = floatPtr[i * channelCount]
                    let right = floatPtr[i * channelCount + 1]
                    monoSamples.append((left + right) / 2.0)
                } else {
                    monoSamples.append(floatPtr[i])
                }
            }

            // Resample system audio to match mic sample rate if needed
            let resampledSamples: [Float] = if format.mSampleRate != self.actualCaptureSampleRate,
                                               format.mSampleRate > 0, self.actualCaptureSampleRate > 0 {
                self.resampleAudio(monoSamples, from: format.mSampleRate, to: self.actualCaptureSampleRate)
            } else {
                monoSamples
            }

            self.bufferQueue.async { [weak self] in
                guard let self else { return }
                self.systemAudioBuffer.append(contentsOf: resampledSamples)
                self.totalSystemSamplesReceived += resampledSamples.count
                self.flushBuffersIfNeeded()
            }
        }
    }

    /// Simple linear interpolation resampling for matching sample rates
    private func resampleAudio(
        _ samples: [Float],
        from sourceSampleRate: Double,
        to targetSampleRate: Double) -> [Float] {
        guard sourceSampleRate > 0, targetSampleRate > 0, !samples.isEmpty else { return samples }

        let ratio = targetSampleRate / sourceSampleRate
        let outputCount = Int(Double(samples.count) * ratio)
        guard outputCount > 0 else { return samples }

        var result = [Float](repeating: 0, count: outputCount)

        for i in 0..<outputCount {
            let srcIndex = Double(i) / ratio
            let srcIndexInt = Int(srcIndex)
            let fraction = Float(srcIndex - Double(srcIndexInt))

            let sample1 = samples[min(srcIndexInt, samples.count - 1)]
            let sample2 = samples[min(srcIndexInt + 1, samples.count - 1)]
            result[i] = sample1 + fraction * (sample2 - sample1)
        }

        return result
    }

    private func stopSystemAudioCapture() async {
        self.logger.debug("Stopping system audio capture")
        self.cleanupSystemAudioCapture()
    }

    private func cleanupSystemAudioCapture() {
        if self.aggregateDeviceID.isValid {
            if let deviceProcID {
                AudioDeviceStop(self.aggregateDeviceID, deviceProcID)
                AudioDeviceDestroyIOProcID(self.aggregateDeviceID, deviceProcID)
                self.deviceProcID = nil
            }
            AudioHardwareDestroyAggregateDevice(self.aggregateDeviceID)
            self.aggregateDeviceID = .unknown
        }

        if self.processTapID.isValid {
            AudioHardwareDestroyProcessTap(self.processTapID)
            self.processTapID = .unknown
        }

        self.logger.debug("System audio capture cleaned up")
    }

    // MARK: - Microphone Capture with Voice Processing

    /// Start microphone capture - captures at native sample rate without real-time conversion
    /// Sample rate conversion is done during post-processing (mono mix creation)
    private func startMicrophoneCapture() throws {
        self.logger.info("=== Starting Microphone Capture ===")

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode

        // Get the hardware format BEFORE enabling voice processing
        let hardwareFormat = inputNode.inputFormat(forBus: 0)
        self.logger.info("Hardware input format: \(hardwareFormat.sampleRate) Hz, \(hardwareFormat.channelCount) ch")

        // Voice processing (AEC/noise suppression) is ONLY enabled for mic-only recording
        // When capturing system audio, voice processing causes audio quality issues:
        // - AEC monitors system output and modifies it for echo cancellation
        // - This makes both playback and recorded system audio sound muffled/crackly
        var voiceProcessingEnabled = false
        let shouldEnableVP = !self.captureSystemAudio && hardwareFormat.sampleRate > 0 && hardwareFormat
            .channelCount > 0

        if shouldEnableVP {
            do {
                try inputNode.setVoiceProcessingEnabled(true)
                voiceProcessingEnabled = true
                self.logger.info("Voice processing enabled (AEC, noise suppression, AGC) - mic-only mode")
            } catch {
                self.logger.warning("Failed to enable voice processing: \(error.localizedDescription)")
            }
        } else if self.captureSystemAudio {
            self.logger.info("Voice processing DISABLED to prevent system audio quality degradation")
        } else {
            self.logger.warning("Skipping voice processing - invalid hardware format")
        }

        // Get the format AFTER voice processing is enabled (it may change)
        var captureFormat = inputNode.outputFormat(forBus: 0)
        self.logger.info(
            "Format after VP: \(captureFormat.sampleRate) Hz, \(captureFormat.channelCount) ch")

        // If format is invalid after voice processing, disable it and use hardware format
        if captureFormat.sampleRate == 0 || captureFormat.channelCount == 0 {
            self.logger.warning("Invalid format after voice processing, disabling VP and using hardware format")
            if voiceProcessingEnabled {
                try? inputNode.setVoiceProcessingEnabled(false)
                voiceProcessingEnabled = false
            }
            captureFormat = hardwareFormat
        }

        // Final fallback if still invalid
        if captureFormat.sampleRate == 0 || captureFormat.channelCount == 0 {
            self.logger.error("Both formats invalid! Using 48kHz mono fallback")
            captureFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48000,
                channels: 1,
                interleaved: false)! // swiftlint:disable:this force_unwrapping
        }

        // Store the actual capture sample rate for writing
        self.actualCaptureSampleRate = captureFormat.sampleRate
        self.logger.info("Final capture format: \(captureFormat.sampleRate) Hz, \(captureFormat.channelCount) ch")

        // Note: dual channel writer is now prepared AFTER startMicrophoneCapture() in startRecording()
        // to ensure we have the correct sample rate

        // Track if we've logged the first buffer
        var hasLoggedFirstBuffer = false

        // Install tap at NATIVE sample rate - NO conversion during capture
        // This is the key fix: we capture exactly what the mic gives us
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: captureFormat) { [weak self] buffer, _ in
            guard let self else { return }

            // Log first buffer for debugging
            if !hasLoggedFirstBuffer {
                hasLoggedFirstBuffer = true
                let rate = buffer.format.sampleRate
                let ch = buffer.format.channelCount
                self.logger.info("*** FIRST MIC BUFFER *** frames: \(buffer.frameLength), \(rate) Hz, \(ch) ch")
                self.micCaptureStarted = true
            }

            guard buffer.frameLength > 0 else {
                self.logger.warning("Received empty mic buffer")
                return
            }

            // Extract samples directly - no conversion
            guard let channelData = buffer.floatChannelData else {
                self.logger.error("No float channel data in mic buffer!")
                return
            }

            // If stereo, downmix to mono; otherwise use channel 0
            let samples: [Float] = if buffer.format.channelCount >= 2, let ch0 = buffer.floatChannelData?[0],
                                      let ch1 = buffer.floatChannelData?[1] {
                // Stereo: average the two channels
                (0..<Int(buffer.frameLength)).map { i in
                    (ch0[i] + ch1[i]) / 2.0
                }
            } else {
                // Mono: use channel 0 directly
                Array(UnsafeBufferPointer(start: channelData[0], count: Int(buffer.frameLength)))
            }

            self.bufferQueue.async {
                self.micAudioBuffer.append(contentsOf: samples)
                self.totalMicSamplesReceived += samples.count

                // For mic-only recording, duplicate to system channel
                if !self.captureSystemAudio || !self.systemAudioActive {
                    self.systemAudioBuffer.append(contentsOf: samples)
                    self.totalSystemSamplesReceived += samples.count
                }
                self.flushBuffersIfNeeded()
            }
        }

        do {
            try engine.start()
            self.logger.info("Audio engine started successfully")
        } catch {
            self.logger.error("Failed to start audio engine: \(error.localizedDescription)")
            throw error
        }

        self.audioEngine = engine
        self.logger.info(
            "=== Mic capture started (VP: \(voiceProcessingEnabled), rate: \(captureFormat.sampleRate) Hz) ===")
    }

    private func stopMicrophoneCapture() {
        guard let engine = audioEngine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.audioEngine = nil
    }

    // MARK: - Buffer Management

    private func flushBuffersIfNeeded() {
        // Flush in ~1 second chunks based on actual capture sample rate
        let flushThreshold = Int(actualCaptureSampleRate)

        // For mic-only recording, only check mic buffer
        if !self.captureSystemAudio || !self.systemAudioActive {
            guard self.micAudioBuffer.count >= flushThreshold else { return }
            // System buffer is already populated with mic data in the tap callback
        } else {
            // For dual capture, need both buffers to have enough data
            guard self.micAudioBuffer.count >= flushThreshold else { return }
            guard self.systemAudioBuffer.count >= flushThreshold else { return }
        }

        let count = min(systemAudioBuffer.count, self.micAudioBuffer.count)
        if count > 0 {
            self.writeSamples(count: count)
        }
    }

    private func flushRemainingBuffers() {
        let micCount = self.micAudioBuffer.count
        let sysCount = self.systemAudioBuffer.count
        self.logger.info("Flushing remaining buffers - mic: \(micCount), system: \(sysCount)")

        // Handle case where we have mic samples but no system samples
        if micCount > 0, sysCount == 0 {
            self.logger.debug("No system samples - duplicating mic to both channels")
            self.systemAudioBuffer = self.micAudioBuffer
        }

        // Handle case where we have system samples but no mic samples (shouldn't happen but be defensive)
        if sysCount > 0, micCount == 0 {
            self.logger.warning("No mic samples - duplicating system to both channels")
            self.micAudioBuffer = self.systemAudioBuffer
        }

        guard !self.micAudioBuffer.isEmpty, !self.systemAudioBuffer.isEmpty else {
            self.logger.error("Both buffers empty - no audio to write!")
            return
        }

        let count = min(systemAudioBuffer.count, self.micAudioBuffer.count)
        self.logger.info("Writing \(count) samples to file (mic had: \(micCount), system had: \(sysCount))")
        self.writeSamples(count: count)

        // If there are remaining samples in one buffer, write them too (padding with silence)
        if !self.systemAudioBuffer.isEmpty || !self.micAudioBuffer.isEmpty {
            let remainingMic = self.micAudioBuffer.count
            let remainingSys = self.systemAudioBuffer.count
            if remainingMic > 0 || remainingSys > 0 {
                self.logger.debug("Writing remaining samples - mic: \(remainingMic), system: \(remainingSys)")
                // Pad the shorter buffer with zeros to match
                let maxRemaining = max(remainingMic, remainingSys)
                while self.micAudioBuffer.count < maxRemaining {
                    self.micAudioBuffer.append(0)
                }
                while self.systemAudioBuffer.count < maxRemaining {
                    self.systemAudioBuffer.append(0)
                }
                self.writeSamples(count: maxRemaining)
            }
        }
    }

    private func writeSamples(count: Int) {
        guard count > 0 else { return }

        guard
            let format = dualChannelFile?.processingFormat,
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))
        else {
            self.logger.error("Failed to create buffer for writing \(count) samples")
            return
        }

        buffer.frameLength = AVAudioFrameCount(count)
        if let ch0 = buffer.floatChannelData?[0], let ch1 = buffer.floatChannelData?[1] {
            for index in 0..<count {
                ch0[index] = self.systemAudioBuffer[index]
                ch1[index] = self.micAudioBuffer[index]
            }
        }

        do {
            try self.dualChannelFile?.write(from: buffer)
            self.totalSamplesWritten += count
        } catch {
            self.logger.error("Failed to write audio: \(error.localizedDescription)")
        }

        self.systemAudioBuffer.removeFirst(count)
        self.micAudioBuffer.removeFirst(count)
    }

    /// Creates a mono mix from the dual-channel recording, resampling to target sample rate (16kHz) for transcription
    private func createMonoMix(in directory: URL) async throws {
        self.logger.info("Creating mono mix in \(directory.lastPathComponent)")

        let dualURL = directory.appendingPathComponent("recording.wav")
        let monoURL = directory.appendingPathComponent("recording-mono.wav")

        guard FileManager.default.fileExists(atPath: dualURL.path) else {
            self.logger.error("Source file doesn't exist: \(dualURL.path)")
            return
        }

        let sourceFile = try AVAudioFile(forReading: dualURL)
        let sourceSampleRate = sourceFile.processingFormat.sampleRate
        self.logger.info("Source file: \(sourceFile.length) frames at \(sourceSampleRate) Hz")

        // Target format for Whisper transcription (16kHz mono)
        // swiftformat:disable:next redundantSelf
        let targetRate = self.targetSampleRate
        let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetRate,
            channels: 1,
            interleaved: false)! // swiftlint:disable:this force_unwrapping

        let monoFile = try AVAudioFile(forWriting: monoURL, settings: monoFormat.settings)

        let sourceFrameCount = AVAudioFrameCount(sourceFile.length)
        guard sourceFrameCount > 0 else {
            self.logger.warning("Source file has 0 frames")
            return
        }

        guard
            let sourceBuffer = AVAudioPCMBuffer(
                pcmFormat: sourceFile.processingFormat,
                frameCapacity: sourceFrameCount)
        else {
            self.logger.error("Failed to create source buffer")
            return
        }

        try sourceFile.read(into: sourceBuffer)
        self.logger.info("Read \(sourceBuffer.frameLength) frames from source")

        // First, downmix stereo to mono at source sample rate
        let intermediateFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sourceSampleRate,
            channels: 1,
            interleaved: false)! // swiftlint:disable:this force_unwrapping

        guard let intermediateBuffer = AVAudioPCMBuffer(
            pcmFormat: intermediateFormat,
            frameCapacity: sourceBuffer.frameLength)
        else {
            self.logger.error("Failed to create intermediate buffer")
            return
        }

        intermediateBuffer.frameLength = sourceBuffer.frameLength

        // Downmix stereo to mono
        if
            let ch0 = sourceBuffer.floatChannelData?[0],
            let ch1 = sourceBuffer.floatChannelData?[1],
            let monoData = intermediateBuffer.floatChannelData?[0] {
            AudioSampleMath.downmix(
                system: ch0,
                mic: ch1,
                destination: monoData,
                frameCount: Int(sourceBuffer.frameLength))
        } else {
            self.logger.error("Failed to access channel data for downmix")
            return
        }

        // Now resample from source rate to target rate (16kHz)
        if sourceSampleRate != targetRate {
            self.logger.info("Resampling from \(sourceSampleRate) Hz to \(targetRate) Hz")

            guard let converter = AVAudioConverter(from: intermediateFormat, to: monoFormat) else {
                self.logger.error("Failed to create resampling converter")
                return
            }

            // Calculate output frame count based on sample rate ratio
            let ratio = targetRate / sourceSampleRate
            let outputFrameCount = AVAudioFrameCount(Double(intermediateBuffer.frameLength) * ratio)

            guard let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: monoFormat,
                frameCapacity: outputFrameCount)
            else {
                self.logger.error("Failed to create output buffer")
                return
            }

            var error: NSError?
            let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return intermediateBuffer
            }

            if status == .error {
                self.logger.error("Resampling failed: \(error?.localizedDescription ?? "unknown")")
                return
            }

            self.logger.info("Resampled to \(outputBuffer.frameLength) frames")
            try monoFile.write(from: outputBuffer)
        } else {
            // No resampling needed, write directly
            try monoFile.write(from: intermediateBuffer)
        }

        self.logger.info("Mono mix created successfully")
    }
}

// MARK: - AudioRecordingController Protocol

extension AudioRecorder: AudioRecordingController {
    var isRecordingPublisher: AnyPublisher<Bool, Never> {
        self.isRecordingSubject.eraseToAnyPublisher()
    }

    var recordingDurationPublisher: AnyPublisher<TimeInterval, Never> {
        self.recordingDurationSubject.eraseToAnyPublisher()
    }
}

// MARK: - Math helpers

enum AudioSampleMath {
    static func downmix(
        system: UnsafePointer<Float>,
        mic: UnsafePointer<Float>,
        destination: UnsafeMutablePointer<Float>,
        frameCount: Int) {
        for index in 0..<frameCount {
            destination[index] = (system[index] + mic[index]) / 2.0
        }
    }

    static func averagedMono(system: [Float], mic: [Float]) -> [Float] {
        let count = min(system.count, mic.count)
        return (0..<count).map { (system[$0] + mic[$0]) / 2.0 }
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
            "Unable to locate a capture display."
        case .permissionDenied:
            "Audio capture permission is required."
        case let .processTapCreationFailed(status):
            "Failed to create process tap: error \(status)"
        case let .aggregateDeviceCreationFailed(status):
            "Failed to create aggregate device: error \(status)"
        case let .ioProcCreationFailed(status):
            "Failed to create I/O proc: error \(status)"
        case let .deviceStartFailed(status):
            "Failed to start audio device: error \(status)"
        case .tapUnavailable:
            "Process tap is unavailable."
        case .streamDescriptionUnavailable:
            "Tap stream description not available."
        case .formatCreationFailed:
            "Failed to create audio format."
        case .bufferCreationFailed:
            "Failed to create audio buffer."
        }
    }
}
