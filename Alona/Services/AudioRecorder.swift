import AVFoundation
import Combine
import CoreMedia
import Foundation
import ScreenCaptureKit

final class AudioRecorder: NSObject, ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var recordingDuration: TimeInterval = 0

    private let meetingFileManager: MeetingFileManager
    private let bufferQueue = DispatchQueue(label: "com.alona.audio-buffer")
    private let sampleQueue = DispatchQueue(label: "com.alona.system-audio")
    private var scStream: SCStream?
    private var audioEngine: AVAudioEngine?
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
        try await startSystemAudioCapture()
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

        await stopSystemAudioCapture()
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

    func startSystemAudioCapture() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw RecordingError.noDisplayFound
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.sampleRate = Int(sampleRate)
        configuration.channelCount = 1
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true

        scStream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        try scStream?.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        try await scStream?.startCapture()
    }

    func stopSystemAudioCapture() async {
        guard scStream != nil else { return }
        try? await scStream?.stopCapture()
        scStream = nil
    }

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

    func flushBuffersIfNeeded() {
        guard systemAudioBuffer.count >= Int(sampleRate), micAudioBuffer.count >= Int(sampleRate) else { return }
        writeSamples(count: min(systemAudioBuffer.count, micAudioBuffer.count))
    }

    func flushRemainingBuffers() {
        guard systemAudioBuffer.count > 0, micAudioBuffer.count > 0 else { return }
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

// MARK: - ScreenCaptureKit delegate

extension AudioRecorder: SCStreamOutput {
    func stream(_: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, let floatSamples = sampleBuffer.asFloatArray() else { return }
        bufferQueue.async { [weak self] in
            self?.systemAudioBuffer.append(contentsOf: floatSamples)
            self?.flushBuffersIfNeeded()
        }
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

// MARK: - CMSampleBuffer helper

private extension CMSampleBuffer {
    func asFloatArray() -> [Float]? {
        guard
            let formatDescription = formatDescription,
            let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription),
            let dataBuffer = CMSampleBufferGetDataBuffer(self)
        else { return nil }

        let frameCount = CMSampleBufferGetNumSamples(self)
        var dataPointer: UnsafeMutablePointer<Int8>?
        var length = 0

        let status = CMBlockBufferGetDataPointer(
            dataBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &length,
            dataPointerOut: &dataPointer
        )

        guard status == noErr, let dataPointer else { return nil }

        if asbd.pointee.mBitsPerChannel == 32 {
            let floatPointer = UnsafeRawPointer(dataPointer).bindMemory(to: Float.self, capacity: frameCount)
            return Array(UnsafeBufferPointer(start: floatPointer, count: frameCount))
        }

        if asbd.pointee.mBitsPerChannel == 16 {
            let intPointer = UnsafeRawPointer(dataPointer).bindMemory(to: Int16.self, capacity: frameCount)
            return (0 ..< frameCount).map { index in
                max(-1.0, min(Float(intPointer[index]) / 32767.0, 1.0))
            }
        }

        return nil
    }
}

// MARK: - Errors

enum RecordingError: LocalizedError {
    case noDisplayFound
    case permissionDenied

    var errorDescription: String? {
        switch self {
        case .noDisplayFound:
            return "Unable to locate a capture display."
        case .permissionDenied:
            return "Screen recording permission is required."
        }
    }
}
