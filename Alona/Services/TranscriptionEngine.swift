@preconcurrency import AVFoundation
import Combine
import Foundation
import OSLog
import SwiftWhisper

protocol TranscriptionProcessing {
    var progressPublisher: AnyPublisher<Double, Never> { get }
    func transcribe(audioURL: URL) async throws -> TranscriptionResult
    func unloadModelIfIdle()
}

final class TranscriptionEngine: NSObject, ObservableObject, TranscriptionProcessing {
    @Published private var progressValue: Double = 0
    private var whisper: Whisper?
    private var lastUsedTime: Date?
    private var unloadTimer: Timer?
    private var activeTranscriptions = 0
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Alona", category: "TranscriptionEngine")

    /// Time after which the model is unloaded if idle (default: 2 minutes)
    private let idleUnloadInterval: TimeInterval = 120

    var progressPublisher: AnyPublisher<Double, Never> {
        $progressValue.eraseToAnyPublisher()
    }

    var isModelLoaded: Bool {
        whisper != nil
    }

    func transcribe(audioURL: URL) async throws -> TranscriptionResult {
        activeTranscriptions += 1
        defer {
            activeTranscriptions -= 1
            lastUsedTime = Date()
            scheduleIdleUnload()
        }

        let frames = try await convertAudioToPCM(url: audioURL)
        try loadModelIfNeeded()
        guard let whisper else {
            throw TranscriptionError.modelNotLoaded
        }

        progressValue = 0
        whisper.delegate = self
        let segments = try await whisper.transcribe(audioFrames: frames)
        let mapped = segments.map { segment in
            TranscriptionSegment(
                startTime: TimeInterval(segment.startTime) / 1000.0,
                endTime: TimeInterval(segment.endTime) / 1000.0,
                text: segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        let text = mapped.map(\.text).joined(separator: " ")
        progressValue = 1.0
        return TranscriptionResult(text: text, segments: mapped)
    }

    /// Unloads the Whisper model to free memory if no transcriptions are active
    func unloadModelIfIdle() {
        // Must run on main thread for thread safety
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.unloadModelIfIdle()
            }
            return
        }

        guard activeTranscriptions == 0 else {
            let count = activeTranscriptions
            logger.debug("Cannot unload model - \(count) active transcriptions")
            return
        }

        if whisper != nil {
            logger.info("Unloading Whisper model to free memory...")
            whisper = nil
            // Force memory cleanup
            #if DEBUG
                logger.debug("Model reference released, memory should be freed by ARC")
            #endif
        } else {
            logger.debug("Model already unloaded or was never loaded")
        }
    }

    private func scheduleIdleUnload() {
        // Must schedule timer on main thread to ensure RunLoop is active
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.unloadTimer?.invalidate()
            self.unloadTimer = Timer.scheduledTimer(withTimeInterval: self.idleUnloadInterval, repeats: false) { [weak self] _ in
                self?.unloadModelIfIdle()
            }
            // Ensure the timer is added to the common RunLoop mode
            if let timer = self.unloadTimer {
                RunLoop.main.add(timer, forMode: .common)
            }
            self.logger.debug("Scheduled model unload timer for \(self.idleUnloadInterval) seconds")
        }
    }
}

extension TranscriptionEngine: WhisperDelegate {
    func whisper(_: Whisper, didUpdateProgress progress: Double) {
        progressValue = progress
    }

    func whisper(_: Whisper, didErrorWith _: Error) {
        progressValue = 0
    }
}

private extension TranscriptionEngine {
    func loadModelIfNeeded() throws {
        guard whisper == nil else { return }
        guard let url = ModelLocator.existingModelURL() else {
            throw TranscriptionError.modelNotFound
        }
        whisper = Whisper(fromFileURL: url)
    }

    func convertAudioToPCM(url: URL) async throws -> [Float] {
        let audioFile = try AVAudioFile(forReading: url)
        let sourceFormat = audioFile.processingFormat
        let frameCount = AVAudioFrameCount(audioFile.length)
        guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount) else {
            throw TranscriptionError.bufferAllocationFailed
        }
        try audioFile.read(into: sourceBuffer)

        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000.0,
            channels: 1,
            interleaved: false
        )!

        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw TranscriptionError.conversionFailed
        }

        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        let convertedCapacity = AVAudioFrameCount(Double(frameCount) * ratio) + 1
        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: convertedCapacity) else {
            throw TranscriptionError.bufferAllocationFailed
        }

        var error: NSError?
        converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
            outStatus.pointee = .haveData
            return sourceBuffer
        }

        if let error {
            throw error
        }

        guard let channelData = convertedBuffer.floatChannelData?[0] else {
            throw TranscriptionError.noChannelData
        }
        return Array(UnsafeBufferPointer(start: channelData, count: Int(convertedBuffer.frameLength)))
    }
}

enum TranscriptionError: LocalizedError {
    case modelNotFound
    case modelNotLoaded
    case conversionFailed
    case bufferAllocationFailed
    case noChannelData

    var errorDescription: String? {
        switch self {
        case .modelNotFound:
            return "Whisper model not found. Use StartupView → Download Model or run 'make download-model'."
        case .modelNotLoaded:
            return "Unable to load Whisper model."
        case .conversionFailed:
            return "Failed to convert audio to 16kHz mono."
        case .bufferAllocationFailed:
            return "Unable to allocate audio buffer."
        case .noChannelData:
            return "Audio buffer missing channel data."
        }
    }
}
