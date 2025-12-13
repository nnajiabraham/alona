@preconcurrency import AVFoundation
import Combine
import Foundation
import SwiftWhisper

protocol TranscriptionProcessing {
    var progressPublisher: AnyPublisher<Double, Never> { get }
    func transcribe(audioURL: URL) async throws -> TranscriptionResult
}

final class TranscriptionEngine: NSObject, ObservableObject, TranscriptionProcessing {
    @Published private var progressValue: Double = 0
    private var whisper: Whisper?

    var progressPublisher: AnyPublisher<Double, Never> {
        $progressValue.eraseToAnyPublisher()
    }

    func transcribe(audioURL: URL) async throws -> TranscriptionResult {
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
