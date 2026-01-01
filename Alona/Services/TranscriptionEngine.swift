@preconcurrency import AVFoundation
import Combine
import Foundation
import Observation
import OSLog
import SwiftWhisper

protocol TranscriptionProcessing: Sendable {
    var progressPublisher: AnyPublisher<Double, Never> { get }
    func transcribe(audioURL: URL) async throws -> TranscriptionResult
    func unloadModelIfIdle()
}

/// TranscriptionEngine handles Whisper transcription.
/// Note: This class uses @Observable for SwiftUI observation and exposes Combine publishers
/// for protocol-based consumption. Marked as @unchecked Sendable because SwiftWhisper's
/// Whisper type is not Sendable. UI updates are dispatched explicitly.
@Observable
final class TranscriptionEngine: TranscriptionProcessing, @unchecked Sendable {
    private var progressValue: Double = 0 {
        didSet { self.progressSubject.send(self.progressValue) }
    }

    @ObservationIgnored private let progressSubject = CurrentValueSubject<Double, Never>(0)
    private var whisper: Whisper?
    private var lastUsedTime: Date?
    private var unloadTimer: Timer?
    private var activeTranscriptions = 0
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Alona", category: "TranscriptionEngine")

    /// Time after which the model is unloaded if idle (default: 2 minutes)
    private let idleUnloadInterval: TimeInterval = 120

    var progressPublisher: AnyPublisher<Double, Never> {
        self.progressSubject.eraseToAnyPublisher()
    }

    var isModelLoaded: Bool {
        self.whisper != nil
    }

    func transcribe(audioURL: URL) async throws -> TranscriptionResult {
        self.activeTranscriptions += 1
        defer {
            self.activeTranscriptions -= 1
            self.lastUsedTime = Date()
            self.scheduleIdleUnload()
        }

        let frames = try await self.convertAudioToPCM(url: audioURL)
        try self.loadModelIfNeeded()
        guard let whisper = self.whisper else {
            throw TranscriptionError.modelNotLoaded
        }

        self.progressValue = 0
        whisper.delegate = self
        let segments = try await whisper.transcribe(audioFrames: frames)
        let mapped = segments.map { segment in
            TranscriptionSegment(
                startTime: TimeInterval(segment.startTime) / 1000.0,
                endTime: TimeInterval(segment.endTime) / 1000.0,
                text: segment.text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let text = mapped.map(\.text).joined(separator: " ")
        self.progressValue = 1.0
        return TranscriptionResult(text: text, segments: mapped)
    }

    /// Unloads the Whisper model to free memory if no transcriptions are active
    func unloadModelIfIdle() {
        // Must run on main thread for thread safety with timer
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.unloadModelIfIdle()
            }
            return
        }

        guard self.activeTranscriptions == 0 else {
            let count = self.activeTranscriptions
            self.logger.debug("Cannot unload model - \(count) active transcriptions")
            return
        }

        if self.whisper != nil {
            self.logger.info("Unloading Whisper model to free memory...")
            self.whisper = nil
            // Force memory cleanup
            #if DEBUG
            self.logger.debug("Model reference released, memory should be freed by ARC")
            #endif
        } else {
            self.logger.debug("Model already unloaded or was never loaded")
        }
    }

    private func scheduleIdleUnload() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.unloadTimer?.invalidate()
            self.unloadTimer = Timer
                .scheduledTimer(withTimeInterval: self.idleUnloadInterval, repeats: false) { [weak self] _ in
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
        self.progressValue = progress
    }

    func whisper(_: Whisper, didErrorWith _: Error) {
        self.progressValue = 0
    }
}

extension TranscriptionEngine {
    private func loadModelIfNeeded() throws {
        guard self.whisper == nil else { return }
        guard let url = ModelLocator.existingModelURL() else {
            throw TranscriptionError.modelNotFound
        }
        self.whisper = Whisper(fromFileURL: url)
    }

    private func convertAudioToPCM(url: URL) async throws -> [Float] {
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
            interleaved: false)! // swiftlint:disable:this force_unwrapping

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
            "Whisper model not found. Use StartupView → Download Model or run 'make download-model'."
        case .modelNotLoaded:
            "Unable to load Whisper model."
        case .conversionFailed:
            "Failed to convert audio to 16kHz mono."
        case .bufferAllocationFailed:
            "Unable to allocate audio buffer."
        case .noChannelData:
            "Audio buffer missing channel data."
        }
    }
}
