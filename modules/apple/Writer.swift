// The notes model: llama.cpp over a GGUF file, on Metal. The model stays
// loaded between requests; each request gets a context sized to its prompt,
// so a short meeting does not pay for a long meeting's memory.
import Foundation
import llama

final class Writer {
    private let model: OpaquePointer, vocab: OpaquePointer
    private static let backend: Void = { llama_backend_init() }()

    init(_ artifact: Artifact) throws {
        _ = Writer.backend
        var params = llama_model_default_params()
        params.n_gpu_layers = 999
        guard let model = llama_model_load_from_file(ModelStore.path(artifact, "model.gguf"), params) else {
            throw EngineError("The notes model could not be loaded.")
        }
        self.model = model
        vocab = llama_model_get_vocab(model)
    }

    deinit { llama_model_free(model) }

    /// Completes `prompt`, which already carries the model's chat markup. `onText` hears the text so far.
    func generate(prompt: String, maxTokens: Int, cancelled: () -> Bool, onText: (String, Double) -> Void) throws -> String {
        let utf8 = Array(prompt.utf8CString)
        var tokens = [llama_token](repeating: 0, count: utf8.count + 16)
        let count = llama_tokenize(vocab, utf8, Int32(utf8.count - 1), &tokens, Int32(tokens.count), true, true)
        guard count > 0 else { throw EngineError("The notes model could not read the prompt.") }
        tokens = Array(tokens.prefix(Int(count)))

        let needed = tokens.count + maxTokens + 32, trained = Int(llama_model_n_ctx_train(model))
        guard needed <= trained else {
            throw EngineError("This meeting is too long for the notes model (\(tokens.count) tokens of \(trained)).")
        }
        var contextParams = llama_context_default_params()
        contextParams.n_ctx = UInt32(max(4096, needed))
        contextParams.n_batch = 2048
        contextParams.n_ubatch = 512
        guard let context = llama_init_from_model(model, contextParams) else {
            throw EngineError("There is not enough memory for the notes model right now.")
        }
        defer { llama_free(context) }

        var at = 0
        while at < tokens.count {
            if cancelled() { throw EngineError("Cancelled.") }
            let n = min(2048, tokens.count - at)
            let status = tokens.withUnsafeMutableBufferPointer { llama_decode(context, llama_batch_get_one($0.baseAddress! + at, Int32(n))) }
            guard status == 0 else { throw EngineError("The notes model stopped while reading the meeting (code \(status)).") }
            at += n
        }

        // Qwen's recommended sampling for non-thinking replies. A fixed seed keeps a rerun's notes the same.
        guard let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params()) else {
            throw EngineError("The notes model could not start.")
        }
        defer { llama_sampler_free(sampler) }
        llama_sampler_chain_add(sampler, llama_sampler_init_penalties(llama_vocab_n_tokens(vocab), 64, 1.0, 0.0, 1.5))
        llama_sampler_chain_add(sampler, llama_sampler_init_top_k(20))
        llama_sampler_chain_add(sampler, llama_sampler_init_top_p(0.8, 1))
        llama_sampler_chain_add(sampler, llama_sampler_init_temp(0.7))
        llama_sampler_chain_add(sampler, llama_sampler_init_dist(42))

        var bytes: [UInt8] = [], generated = 0
        var piece = [CChar](repeating: 0, count: 256)
        while generated < maxTokens {
            if cancelled() { throw EngineError("Cancelled.") }
            var token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocab, token) { break }
            let length = llama_token_to_piece(vocab, token, &piece, Int32(piece.count), 0, false)
            if length > 0 { bytes.append(contentsOf: piece.prefix(Int(length)).map { UInt8(bitPattern: $0) }) }
            generated += 1
            onText(String(decoding: bytes, as: UTF8.self), Double(generated) / Double(maxTokens))
            guard llama_decode(context, llama_batch_get_one(&token, 1)) == 0 else { break }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
