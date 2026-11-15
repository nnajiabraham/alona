// Speech-to-text with sherpa-onnx. A recording is read and resampled in
// one-second pieces and fed to a voice activity detector, and each stretch of
// speech is decoded as soon as the detector closes it. Memory stays flat for
// a meeting of any length, and silence never reaches the decoder.
import AVFoundation
import Foundation
import SherpaOnnxC

final class Speech {
    private let recognizer: OpaquePointer, vad: OpaquePointer
    private static let rate = 16000.0, window = 512

    init(_ artifact: Artifact) throws {
        let p = { (name: String) in strdup(ModelStore.path(artifact, name))! }
        // sherpa copies its strings while it builds, so they only need to outlive the two create calls.
        let tokens = p("tokens.txt"), provider = strdup("cpu")!, method = strdup("greedy_search")!, vadModel = p("silero_vad.onnx")
        var owned = [tokens, provider, method, vadModel]
        defer { owned.forEach { free($0) } }

        var config = SherpaOnnxOfflineRecognizerConfig()
        config.feat_config = SherpaOnnxFeatureConfig(sample_rate: Int32(Speech.rate), feature_dim: 80)
        config.model_config.tokens = UnsafePointer(tokens)
        config.model_config.num_threads = Int32(max(1, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))
        config.model_config.provider = UnsafePointer(provider)
        config.decoding_method = UnsafePointer(method)
        switch artifact.runtime {
        case "sherpa-moonshine":
            let encoder = p("encoder_model.ort"), decoder = p("decoder_model_merged.ort")
            owned += [encoder, decoder]
            config.model_config.moonshine.encoder = UnsafePointer(encoder)
            config.model_config.moonshine.merged_decoder = UnsafePointer(decoder)
        case "sherpa-transducer":
            let encoder = p("encoder.int8.onnx"), decoder = p("decoder.int8.onnx"), joiner = p("joiner.int8.onnx"), type = strdup("nemo_transducer")!
            owned += [encoder, decoder, joiner, type]
            config.model_config.transducer.encoder = UnsafePointer(encoder)
            config.model_config.transducer.decoder = UnsafePointer(decoder)
            config.model_config.transducer.joiner = UnsafePointer(joiner)
            config.model_config.model_type = UnsafePointer(type)
        default:
            throw EngineError("This build cannot run the speech model \(artifact.id).")
        }
        guard let recognizer = SherpaOnnxCreateOfflineRecognizer(&config) else {
            throw EngineError("The speech model could not be loaded.")
        }
        var vadConfig = SherpaOnnxVadModelConfig()
        vadConfig.silero_vad.model = UnsafePointer(vadModel)
        vadConfig.silero_vad.threshold = 0.5
        vadConfig.silero_vad.min_silence_duration = 0.4
        vadConfig.silero_vad.min_speech_duration = 0.25
        vadConfig.silero_vad.window_size = Int32(Speech.window)
        // Moonshine drifts on long inputs, so a stretch of speech is cut at 20 s.
        vadConfig.silero_vad.max_speech_duration = 20
        vadConfig.sample_rate = Int32(Speech.rate)
        vadConfig.num_threads = 1
        vadConfig.provider = UnsafePointer(provider)
        guard let vad = SherpaOnnxCreateVoiceActivityDetector(&vadConfig, 60) else {
            SherpaOnnxDestroyOfflineRecognizer(recognizer)
            throw EngineError("The voice detector could not be loaded.")
        }
        self.recognizer = recognizer; self.vad = vad
    }

    deinit {
        SherpaOnnxDestroyOfflineRecognizer(recognizer)
        SherpaOnnxDestroyVoiceActivityDetector(vad)
    }

    /// Transcribes the file at `url`. `onSegment` hears each segment and the fraction of the file read so far.
    func transcribe(_ url: URL, cancelled: () -> Bool, onSegment: ([String: Any]?, Double) -> Void) throws {
        let file = try AVAudioFile(forReading: url)
        let source = file.processingFormat
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Speech.rate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: source, to: target),
              let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(source.sampleRate)) else {
            throw EngineError("The recording's audio format is not supported.")
        }
        let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Speech.rate) + 4096)!
        SherpaOnnxVoiceActivityDetectorReset(vad)
        var pending: [Float] = []
        var atEnd = false

        while !atEnd {
            if cancelled() { throw EngineError("Cancelled.") }
            if file.framePosition < file.length { try file.read(into: input) } else { input.frameLength = 0 }
            let ended = input.frameLength == 0
            atEnd = ended
            var fed = false, failure: NSError?
            output.frameLength = 0
            converter.convert(to: output, error: &failure) { _, status in
                if ended { status.pointee = .endOfStream; return nil }
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return input
            }
            if let failure { throw failure }
            if let samples = output.floatChannelData?[0] {
                pending.append(contentsOf: UnsafeBufferPointer(start: samples, count: Int(output.frameLength)))
            }
            var offset = 0
            pending.withUnsafeBufferPointer { buffer in
                while offset + Speech.window <= buffer.count {
                    SherpaOnnxVoiceActivityDetectorAcceptWaveform(vad, buffer.baseAddress! + offset, Int32(Speech.window))
                    offset += Speech.window
                }
            }
            pending.removeFirst(offset)
            if atEnd { SherpaOnnxVoiceActivityDetectorFlush(vad) }
            let read = file.length > 0 ? Double(file.framePosition) / Double(file.length) : 1
            while SherpaOnnxVoiceActivityDetectorEmpty(vad) == 0 {
                if cancelled() { throw EngineError("Cancelled.") }
                guard let segment = SherpaOnnxVoiceActivityDetectorFront(vad) else { break }
                let start = Double(segment.pointee.start) / Speech.rate, count = segment.pointee.n
                let text = decode(segment.pointee.samples, count)
                SherpaOnnxDestroySpeechSegment(segment)
                SherpaOnnxVoiceActivityDetectorPop(vad)
                if !text.isEmpty {
                    onSegment(["start": start, "end": start + Double(count) / Speech.rate, "text": text], read)
                }
            }
            onSegment(nil, read)
        }
    }

    private func decode(_ samples: UnsafePointer<Float>?, _ count: Int32) -> String {
        guard let stream = SherpaOnnxCreateOfflineStream(recognizer) else { return "" }
        defer { SherpaOnnxDestroyOfflineStream(stream) }
        SherpaOnnxAcceptWaveformOffline(stream, Int32(Speech.rate), samples, count)
        SherpaOnnxDecodeOfflineStream(recognizer, stream)
        guard let result = SherpaOnnxGetOfflineStreamResult(stream) else { return "" }
        defer { SherpaOnnxDestroyOfflineRecognizerResult(result) }
        return result.pointee.text.map { String(cString: $0) }?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
