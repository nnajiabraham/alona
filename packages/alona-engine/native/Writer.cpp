#include <jni.h>
#include <llama.h>
#include <algorithm>
#include <memory>
#include <string>
#include <vector>

static void fail(JNIEnv *env, const char *message) { env->ThrowNew(env->FindClass("java/lang/IllegalStateException"), message); }
extern "C" JNIEXPORT void JNICALL Java_alona_engine_Writer_generate(JNIEnv *env, jobject self, jstring path, jbyteArray prompt, jint limit, jint threads) {
    llama_backend_init();
    const char *file = env->GetStringUTFChars(path, nullptr);
    auto mp = llama_model_default_params(); mp.n_gpu_layers = 0;
    std::unique_ptr<llama_model, decltype(&llama_model_free)> model(llama_model_load_from_file(file, mp), llama_model_free);
    env->ReleaseStringUTFChars(path, file);
    if (!model) return fail(env, "Could not load notes model");
    const auto *vocab = llama_model_get_vocab(model.get());
    std::string input(env->GetArrayLength(prompt), '\0');
    env->GetByteArrayRegion(prompt, 0, input.size(), reinterpret_cast<jbyte *>(input.data()));
    std::vector<llama_token> tokens(input.size() + 16);
    int n = llama_tokenize(vocab, input.data(), input.size(), tokens.data(), tokens.size(), true, true);
    if (n <= 0 || limit <= 0 || n + limit + 32 > llama_model_n_ctx_train(model.get())) return fail(env, "Prompt exceeds model context");
    auto cp = llama_context_default_params(); cp.n_ctx = std::max(4096, n + limit + 32); cp.n_batch = 512; cp.n_ubatch = 128; cp.n_threads = threads; cp.n_threads_batch = threads;
    std::unique_ptr<llama_context, decltype(&llama_free)> ctx(llama_init_from_model(model.get(), cp), llama_free);
    if (!ctx) return fail(env, "Could not allocate notes context");
    auto cls = env->GetObjectClass(self);
    auto cancelled = env->GetMethodID(cls, "cancelled", "()Z");
    auto progress = env->GetMethodID(cls, "progress", "([BD)V");
    auto stop = [&]() { return env->CallBooleanMethod(self, cancelled) || env->ExceptionCheck(); };
    for (int at = 0; at < n; at += 512) {
        if (stop()) return;
        if (llama_decode(ctx.get(), llama_batch_get_one(tokens.data() + at, std::min(512, n - at)))) return fail(env, "Prompt decode failed");
    }
    std::unique_ptr<llama_sampler, decltype(&llama_sampler_free)> sampler(llama_sampler_chain_init(llama_sampler_chain_default_params()), llama_sampler_free);
    llama_sampler_chain_add(sampler.get(), llama_sampler_init_top_k(20));
    llama_sampler_chain_add(sampler.get(), llama_sampler_init_top_p(0.8f, 1));
    llama_sampler_chain_add(sampler.get(), llama_sampler_init_temp(0.7f));
    llama_sampler_chain_add(sampler.get(), llama_sampler_init_dist(42));
    std::string text; std::vector<char> piece(256);
    for (int i = 0; i < limit; ++i) {
        if (stop()) return;
        auto token = llama_sampler_sample(sampler.get(), ctx.get(), -1);
        if (llama_vocab_is_eog(vocab, token)) break;
        int len = llama_token_to_piece(vocab, token, piece.data(), piece.size(), 0, false);
        if (len < 0) { piece.resize(-len); len = llama_token_to_piece(vocab, token, piece.data(), piece.size(), 0, false); }
        if (len > 0) text.append(piece.data(), len);
        auto bytes = env->NewByteArray(text.size()); env->SetByteArrayRegion(bytes, 0, text.size(), reinterpret_cast<const jbyte *>(text.data()));
        env->CallVoidMethod(self, progress, bytes, double(i + 1) / limit); env->DeleteLocalRef(bytes);
        if (env->ExceptionCheck()) return;
        if (llama_decode(ctx.get(), llama_batch_get_one(&token, 1))) return fail(env, "Completion decode failed");
    }
}
