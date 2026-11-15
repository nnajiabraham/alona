# Local models for Alona: speech-to-text and meeting-notes LLM (November 2026)

Research date: 2026-11-14. Scope: on-device speech-to-text (STT), a small LLM that turns a finished transcript plus the user's notes into meeting notes, runtimes for web, iOS, Android, and macOS, and the device-tier rule. Every model is downloaded and cached or bundled. No cloud inference.

Conventions:

- Each fact carries a source link in the same row or sentence. The Sources section lists every link.
- **UNCONFIRMED** marks a fact found only in secondary sources, or not found at all.
- **Estimate** marks a number derived here (for example, the sum of file sizes), not published by the vendor.
- WER figures are English Open ASR Leaderboard averages unless stated otherwise. Lower is better.
- "Peak RAM" figures come from a named source. Estimated figures are labeled.

## 1. Recommended tiers

STT and LLM run one after the other, never at the same time. The app unloads the STT model before it loads the LLM. Peak RAM is therefore the larger of the two numbers, not their sum.

| Tier | STT model (file) | LLM (file) | Download | Peak RAM | Minimum device | Platforms |
|---|---|---|---|---|---|---|
| **Lite** | Moonshine Streaming Small, English, MIT, 123M params, 7.84% WER. Native: [handy-computer/moonshine-streaming-small-gguf](https://huggingface.co/handy-computer/moonshine-streaming-small-gguf) `moonshine-streaming-small-Q8_0.gguf` (198.5 MB). Web and mobile SDKs: Moonshine Voice assets in [moonshine-ai/moonshine-voice-assets](https://huggingface.co/moonshine-ai/moonshine-voice-assets). Non-English: per-language Moonshine Streaming tiny or small repos (de, es, ja, zh, vi, ar, tl) under [moonshine-ai](https://huggingface.co/moonshine-ai). | Qwen3.5-0.8B, Apache-2.0, 262K context. Native: [unsloth/Qwen3.5-0.8B-GGUF](https://huggingface.co/unsloth/Qwen3.5-0.8B-GGUF) `Qwen3.5-0.8B-Q4_K_M.gguf` (533 MB). Browser: [onnx-community/Qwen3.5-0.8B-ONNX](https://huggingface.co/onnx-community/Qwen3.5-0.8B-ONNX) `q4f16` decoder (436.7 MB) plus embeddings (147.0 MB). | About 0.75 GB native. About 0.8 GB browser. Both are estimates from file sizes. | 4 GB phone, or any browser with WASM. | Web (all browsers including iOS Safari), iOS, Android, macOS |
| **Balanced** | Parakeet TDT 0.6B v3, 25 European languages, CC-BY-4.0, 6.34% WER. iOS and macOS: [FluidInference/parakeet-tdt-0.6b-v3-coreml](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml). Android and desktop: `sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8.tar.bz2` (487.2 MB) from [sherpa-onnx asr-models release](https://github.com/k2-fsa/sherpa-onnx/releases/tag/asr-models). Browser: [istupakov/parakeet-tdt-0.6b-v3-onnx](https://huggingface.co/istupakov/parakeet-tdt-0.6b-v3-onnx) int8 (encoder 652.2 MB plus decoder 18.2 MB). | Qwen3.5-2B, Apache-2.0. Native: [unsloth/Qwen3.5-2B-GGUF](https://huggingface.co/unsloth/Qwen3.5-2B-GGUF) `Qwen3.5-2B-Q4_K_M.gguf` (1.28 GB). Browser: [onnx-community/Qwen3.5-2B-ONNX](https://huggingface.co/onnx-community/Qwen3.5-2B-ONNX) `q4f16` decoder (1089.8 MB) plus embeddings (294.0 MB). | About 1.8 GB native. About 2.1 GB browser. | STT needs at least 2 GB of RAM ([card](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3)). The LLM measured 3 GB at load ([Hedy](https://hedy.ai/post/local-ai-engineering-deep-dive-hedy-3-2/)). | 6 GB phone, 8 GB laptop, or a desktop browser with WebGPU. | iOS, Android, macOS, Windows/Linux, desktop Chrome/Edge |
| **Quality** | Granite Speech 5.0 470M TurboCTC, Apache-2.0, 5.51% WER, 7 languages. [handy-computer/granite-speech-5.0-470m-turboctc-gguf](https://huggingface.co/handy-computer/granite-speech-5.0-470m-turboctc-gguf) `granite-speech-5.0-470m-turboctc-Q8_0.gguf` (506 MB). For any language outside its 7, fall back to Parakeet v3 from Balanced. | Qwen3.5-9B, Apache-2.0. [unsloth/Qwen3.5-9B-GGUF](https://huggingface.co/unsloth/Qwen3.5-9B-GGUF) `Qwen3.5-9B-Q4_K_M.gguf` (5.68 GB). The MLX alternative is [mlx-community/Qwen3.5-9B-4bit](https://huggingface.co/mlx-community/Qwen3.5-9B-4bit) (5.98 GB). | About 6.2 GB. | 8 GB at load for the LLM ([Hedy](https://hedy.ai/post/local-ai-engineering-deep-dive-hedy-3-2/)). STT RAM is UNCONFIRMED. | 16 GB+ Apple Silicon Mac. 16 GB+ Windows/Linux with a GPU. | macOS, Windows, Linux |

Diarization runs in every tier where it is available. On Apple platforms it is pyannote Community-1 through FluidAudio's `Diarizer` trait ([FluidAudio](https://github.com/FluidInference/FluidAudio)). Elsewhere it is pyannote Community-1, CC-BY-4.0 ([card](https://huggingface.co/pyannote/speaker-diarization-community-1)). Moonshine Voice also ships a Community-1 embedding model as an ONNX Runtime (`.ort`) file of 7.0 MB (`model/diarization-community1/embedding.ort` in [moonshine-voice-assets](https://huggingface.co/moonshine-ai/moonshine-voice-assets)).

Why these picks:

- **Lite STT.** Moonshine Streaming Small has the best accuracy of any official model that runs in WASM, on iOS, and on Android from one vendor. It reaches 7.84% WER at 123M params, and Medium reaches 6.65% at 245M ([card](https://huggingface.co/UsefulSensors/moonshine-streaming-medium)). The card targets "sub-1GB memory budgets". Use Medium (quantized Moonshine Voice files total about 270 MB, an estimate from [moonshine-voice-assets](https://huggingface.co/moonshine-ai/moonshine-voice-assets)) when the device has headroom.
- **Balanced STT.** Parakeet v3 has the broadest set of maintained runtimes: Core ML on the Apple Neural Engine (ANE) through FluidAudio, sherpa-onnx on Android and desktop, GGUF through transcribe.cpp, and community ONNX builds for the browser. It covers 25 European languages with automatic language detection and returns word timestamps. With local attention it handles up to 3 hours of audio ([card](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3)).
- **Quality STT.** Granite Speech 5.0 TurboCTC has lower WER than Parakeet v3 (5.51% vs 6.34%) at a smaller size. It uses non-autoregressive CTC decoding ([card](https://huggingface.co/ibm-granite/granite-speech-5.0-470m-turboctc)), so it cannot fall into the repeated-phrase loops that autoregressive decoders such as Whisper and Moonshine can. Its Q4_K_M file loses almost no LibriSpeech accuracy (1.35% vs 1.33%) at 279 MB ([GGUF page](https://huggingface.co/handy-computer/granite-speech-5.0-470m-turboctc-gguf)). It is limited to the Quality tier because its only confirmed native runtimes are transcribe.cpp and mlx-audio. Neither one confirms Android or WASM support.
- **LLM family.** Qwen3.5 has one license (Apache-2.0), one chat template, and one prompt across four sizes (0.8B, 2B, 4B, 9B). Its native context is 262,144 tokens ([Qwen3.5-2B card](https://huggingface.co/Qwen/Qwen3.5-2B)). It ships in GGUF, MLX, and transformers.js ONNX builds. The architecture puts one full-attention block after every three Gated DeltaNet blocks ([card](https://huggingface.co/Qwen/Qwen3.5-2B)). Only one layer in four keeps a growing KV cache, so a 15K-token transcript costs much less memory than it would in a standard transformer. This is an inference from the architecture, not a measurement. Hedy, a shipping local meeting app, settled on Gemma 4 and Qwen 3.5 as its two model families ([Hedy](https://hedy.ai/post/local-ai-engineering-deep-dive-hedy-3-2/)).
- **Lite LLM caveat.** No source in this research shows that a 0.8B model writes reliable meeting notes. The Lite tier uses map-reduce with small chunks (section 4). The app should label Lite output as a draft. Validate this tier on the eval set before shipping.

## 2. Capability detection and tier mapping

Run detection once at first launch and store the result. Re-run it when the OS version or app version changes. The user can override the tier in Settings, and the override always wins.

### 2.1 Signals per platform

| Platform | Signal | API | Notes |
|---|---|---|---|
| Browser | Approximate RAM | `navigator.deviceMemory` | Chromium only. Rounded to a power of 2 and clamped to implementation-defined bounds. Requires a secure context ([MDN](https://developer.mozilla.org/en-US/docs/Web/API/Navigator/deviceMemory)). Absent in Safari and Firefox, so a missing value means "unknown", not "low". |
| Browser | GPU present and its limits | `navigator.gpu.requestAdapter()`, then `adapter.limits` (`maxBufferSize`, `maxStorageBufferBindingSize`) and `adapter.info` | `adapter.info` has limited availability, and its fields may be empty ([MDN](https://developer.mozilla.org/en-US/docs/Web/API/GPUAdapter/info)). WebGPU is on by default in Safari 26 on iOS, iPadOS, and macOS ([web.dev](https://web.dev/blog/webgpu-supported-major-browsers)). |
| Browser | Storage quota | `navigator.storage.estimate()`, `navigator.storage.persist()` | WebKit allows about 60% of disk per origin on iOS 17+ and macOS 14+ ([MDN](https://developer.mozilla.org/docs/Web/API/Storage_API/Storage_quotas_and_eviction_criteria)). Safari deletes script-writable storage after 7 days without user interaction, except for home-screen web apps ([itnews](https://www.itnews.com.au/news/apple-cops-flak-for-deleting-local-browser-storage-after-7-days-539833)). Whether that rule covers OPFS is unresolved ([WebKit bug 276998](https://bugs.webkit.org/show_bug.cgi?id=276998)). |
| Browser | Address-space ceiling | Feature-detect Memory64 | Chrome 133 and Firefox 134 ship Memory64. Safari does not ([SpiderMonkey](https://spidermonkey.dev/blog/2025/01/15/is-memory64-actually-worth-using.html), [WebKit bug 300538](https://bugs.webkit.org/show_bug.cgi?id=300538)). Without it, a wasm32 heap cannot exceed 4 GB. Keep WASM-path models well under 2 GB. |
| Browser | CPU threads | `navigator.hardwareConcurrency` | Multithreaded WASM also needs cross-origin isolation (COOP and COEP headers). This was not re-verified in this research. |
| iOS / macOS | Physical RAM | `ProcessInfo.processInfo.physicalMemory`. On iOS, also `os_proc_available_memory()` for the current per-process headroom. | The Apple documentation URL for `os_proc_available_memory` returned 404 during this research, so its behavior is UNCONFIRMED here. |
| iOS / macOS | Chip | `sysctlbyname("hw.machine")` / `hw.model` | Apple Intelligence (and with it the Foundation Models framework) runs on iPhone 15 Pro and later, iPads with M1 or A17 Pro and later, and M1+ Macs ([Apple](https://support.apple.com/en-us/121115)). |
| Android | RAM | `ActivityManager.MemoryInfo.totalMem` (API 16), `advertisedMem` (API 34), `availMem`, `lowMemory` | `totalMem` excludes memory reserved below the kernel, so an "8 GB" phone reports less than 8 GB. Use `advertisedMem` when present ([Android](https://developer.android.com/reference/android/app/ActivityManager.MemoryInfo)). |
| Android | SoC | `Build.SOC_MODEL` (API 31) | Use it only to choose between GPU and CPU backends. The tier comes from RAM. |
| Rust (all native) | RAM and CPU | `sysinfo` crate | Version not checked in this research. |

### 2.2 Decision table

Evaluate the rows top to bottom. The first match wins. "RAM" means advertised RAM where the platform exposes it, otherwise total RAM.

| # | Condition | Tier |
|---|---|---|
| 1 | The user picked a tier in Settings | That tier |
| 2 | Browser on iOS or iPadOS (any engine, since all use WebKit) | Lite |
| 3 | Browser without WebGPU (`requestAdapter()` returns null) | Lite (WASM) |
| 4 | Browser with WebGPU, `deviceMemory` ≥ 8 (or missing on desktop Safari or Firefox), `maxBufferSize` ≥ 1 GiB, and quota ≥ 4 GB | Balanced |
| 5 | Any other browser | Lite |
| 6 | Native, RAM < 6 GB | Lite |
| 7 | Native phone or tablet, RAM ≥ 6 GB | Balanced (Quality is never auto-selected on mobile) |
| 8 | Native desktop, RAM ≥ 16 GB, and either Apple Silicon or a GPU with ≥ 8 GB VRAM | Quality |
| 9 | Native desktop, any other configuration | Balanced |

Two further rules apply after downloading:

- **Probe.** Transcribe a bundled 30-second clip and generate 128 tokens. If STT runs at less than 2x real time, or the LLM produces fewer than 5 tokens per second, drop one tier and tell the user. These thresholds are starting values, not measured ones. Tune them on real devices.
- **Out-of-memory recovery.** If the app is killed or an allocation fails during a summary, drop one tier for the next run, and record the event locally.

Precedent: Hedy estimates each model's footprint as weights plus KV cache plus a working buffer. It compares that against VRAM or unified memory, labels each model "Great fit", "Tight fit", or "Won't fit", and recommends only Great-fit models. On iOS it ships only its 2B to 4B models, on iPhone 15 Pro and later ([Hedy](https://hedy.ai/post/local-ai-engineering-deep-dive-hedy-3-2/)). This design copies the "never auto-pick a tight fit" rule.

## 3. Runtime per platform

Rust package versions come from the crates.io API, npm versions from the npm registry, and native versions from GitHub releases, all queried 2026-11-14.

| Platform | Task | Primary runtime | Fallback | Reason |
|---|---|---|---|---|
| Browser | STT | `@moonshine-ai/moonshine-wasm` 0.1.6 for Lite ([quickstart](https://moonshine-voice.readthedocs.io/en/latest/quickstart/)). `onnxruntime-web` 1.31.1 with the WebGPU execution provider, running the Parakeet v3 ONNX export, for Balanced. | `sherpa-onnx` 2.0.1 (npm, WASM build). Whether its WASM build loads Parakeet v3 is UNCONFIRMED. | Moonshine is the only vendor-maintained WASM STT package in this set. Parakeet in the browser exists only as community ports ([parakeet webgpu](https://huggingface.co/striimit/parakeet-tdt-0.6b-v3-webgpu), [onnx-asr-web](https://cdn.jsdelivr.net/npm/onnx-asr-web@0.1.3/README.md)). |
| Browser | LLM | `@huggingface/transformers` 4.3.2. Its WebGPU runtime was rewritten in C++ with the ONNX Runtime team, and it falls back to WASM ([blog](https://huggingface.co/blog/transformersjs-v4)). Cache with `env.useWasmCache` and the Cache API. `ModelRegistry.is_pipeline_cached` checks the cache. | `@wllama/wllama` 3.13.0 (llama.cpp compiled to WASM, loads the same GGUF files). Qwen3.5 support in wllama is UNCONFIRMED. | onnx-community publishes Qwen3.5 ONNX builds. `@mlc-ai/web-llm` 0.2.88 is current, but Qwen3.5 and Gemma 4 support in its prebuilt list is UNCONFIRMED. |
| iOS / macOS | STT | FluidAudio v0.18.3 (Swift Package Manager). It runs Parakeet v3 on the ANE at about 190x real time on an M4 Pro, and its `Diarizer` trait adds pyannote Community-1 diarization ([repo](https://github.com/FluidInference/FluidAudio)). | WhisperKit, now `argmax-oss-swift` v1.1.1, MIT license, with SpeakerKit for diarization ([repo](https://github.com/argmaxinc/WhisperKit)). Apple `SpeechTranscriber` on OS 26+ is a zero-download fallback. | The ANE keeps the GPU and CPU free while recording. whisper.cpp v1.9.5 with Core ML stays available, but Whisper is no longer the accuracy-per-byte leader. |
| macOS (Quality) | STT | transcribe.cpp v0.4.2: ggml-based, MIT license, Metal backend, bindings for Rust, Swift, TypeScript, and Python, 16 model families ([repo](https://github.com/handy-computer/transcribe.cpp)). It runs Granite Speech 5.0. | FluidAudio with Parakeet v3 | Granite has no Core ML port. |
| iOS / macOS | LLM | llama.cpp (tagged v1.0.0 on 2026-11-13) with Metal, called through Rust `llama-cpp-2` 0.1.161 | `mlx-swift-lm` 3.32.3 with MLX 4-bit weights. Apple Foundation Models (on-device, free) is a further fallback for short prompts only. | One GGUF file serves every native platform. The Foundation Models context window is 4,096 tokens per session, counting instructions, prompt, and output ([Apple TN3193](https://developer.apple.com/tutorials/data/documentation/technotes/tn3193-managing-the-on-device-foundation-model-s-context-window.md)). A 60-minute transcript does not fit. |
| Android | STT | sherpa-onnx 2.0.1 (Kotlin/JNI, or the `sherpa-onnx` Rust crate 2.0.1). It runs Parakeet v3 int8 (487.2 MB) and Moonshine. | Moonshine Voice `ai.moonshine:moonshine-voice:0.1.5` (Gradle) ([quickstart](https://moonshine-voice.readthedocs.io/en/latest/quickstart/)) | One ONNX runtime covers both the Lite and Balanced models. |
| Android | LLM | llama.cpp through `llama-cpp-2` (CPU, which is the safe default on Android) | LiteRT-LM v0.19.1 with Gemma 4 E2B (`gemma-4-E2B-it-gpu.litertlm`, 2.34 GB, [repo](https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm)). Google measured 52 tokens/s decode on the GPU of a Galaxy S26 Ultra ([Google](https://developers.googleblog.com/en/blazing-fast-on-device-genai-with-litert-lm/)). | Gemini Nano through ML Kit's Prompt API is in beta. Its input limit is under 4,000 tokens (UNCONFIRMED; seen only in a translated docs page), it runs only for the foreground app, and only on some devices ([ML Kit](https://developers.google.com/ml-kit/genai/prompt/android/get-started)). It cannot be the primary runtime. |
| Rust core | STT | `transcribe.cpp` Rust bindings (crate name UNCONFIRMED), `sherpa-onnx` 2.0.1, or `whisper-rs` 0.16.0 | `ort` 2.0.0-rc.15 (ONNX Runtime) | `sherpa-rs` 0.6.8 has not had a release since 2025-10-05. Prefer the official `sherpa-onnx` crate. |
| Rust core | LLM | `llama-cpp-2` 0.1.161 | `mistralrs` 0.8.1 on crates.io (the GitHub tag is v0.9.5). `candle-core` 0.11.1. | Bindings are tracking llama.cpp closely, with the last release on 2026-11-03. |

## 4. Long-transcript strategy

Size of the input: 9,000 to 12,000 words at about 1.3 tokens per word is roughly 12K to 16K tokens. The ratio is an estimate for English, and Qwen3.5's tokenizer was not measured. The user's notes add more.

Evidence:

- **Advertised context is not usable context.** On MRCR v2 at 128K, Gemma 4 E2B scores 19.1% and E4B scores 25.4% ([card](https://huggingface.co/google/gemma-4-E2B)). Qwen3.5-2B scores 38.7 on LongBench v2 ([card](https://huggingface.co/Qwen/Qwen3.5-2B)). Chroma tested 18 models, including Qwen3-8B, and found that performance "grows increasingly unreliable as input length grows", even on simple tasks ([Chroma](https://www.trychroma.com/research/context-rot)). Small models are not better at this.
- **The one meeting-specific small model was evaluated only up to 10K tokens.** LiquidAI tested LFM2-2.6B-Transcript on 1K-token and 10K-token transcripts, framed as 30 to 60 minute meetings ([card](https://huggingface.co/LiquidAI/LFM2-2.6B-Transcript)). No public evidence shows a 1B to 4B model staying faithful at 15K tokens.
- **Chunking tradeoffs.** For book-length inputs, hierarchical merging (summarize chunks, then merge) produced more coherent summaries. Incremental updating (a running summary) kept more detail ([BooookScore](https://arxiv.org/abs/2310.00785)). Multi-stage extraction pipelines suffer cumulative error propagation without intermediate validation, and segment-level selection let a 7B model match 72B models on long meetings ([S3, 2026](https://arxiv.org/abs/2606.08445)). FRAME sizes its chunks to whole speaker turns, not fixed token counts ([FRAME](https://arxiv.org/pdf/2509.15901)).
- **No head-to-head comparison exists.** No 2025 or 2026 paper compares chunked and one-shot summarization of meeting transcripts with small models. Alona needs its own eval (see below).

Recommended design: one-shot below a per-tier budget, map-reduce above it.

| Tier | One-shot budget (transcript plus notes) | Map chunk | Reduce input |
|---|---|---|---|
| Lite (0.8B) | 3K tokens | 1.5K tokens | Map outputs only |
| Balanced (2B) | 8K tokens | 3K tokens | Map outputs plus user notes |
| Quality (9B) | 24K tokens | 6K tokens | Map outputs plus user notes |

These budgets are starting points. Tune them with the eval harness below.

1. **Chunk on speaker-turn boundaries**, with one turn of overlap. Never split a turn.
2. **Map step: extraction, not prose.** Each chunk returns JSON with these fields: `topics[]`, `decisions[]`, `action_items[{owner, task, due}]`, `open_questions[]`, `quotes[]`, and `timestamps` for each item. Use the runtime's grammar or JSON-schema constrained decoding (llama.cpp grammars) so a small model cannot break the format. Pass the user's note headings as a "focus list" so the map step tags matching content.
3. **Reduce step.** Merge and deduplicate the items, resolve conflicting owners by preferring the later statement, then write the prose summary from the merged JSON plus the user's raw notes. The user's notes are ground truth for intent. The transcript is ground truth for facts.
4. **Validation between stages**, which answers S3's error-propagation finding. Drop any action item whose owner never speaks or is never named in its source chunk. Keep each item's timestamp so the UI can link it to audio.
5. **Fallback.** If the reduce input exceeds the budget, reduce hierarchically in groups of 4.

Build an eval harness before tuning: 20 or more real meetings (with consent), with reference decisions and action items. Score item recall, item precision, owner accuracy, and hallucinated items. Use the same harness to accept or reject the Lite tier and to compare LFM3-1.7B if its license is acceptable (section 6).

Long-form STT: run VAD (Silero, which ships in whisper.cpp, FluidAudio, and sherpa-onnx), then transcribe the speech segments. Silence never reaches the decoder, which removes the main cause of Whisper and Moonshine hallucinating on silence. Moonshine's card warns that it "can hallucinate words that are not present in the audio" on short or noisy segments ([card](https://huggingface.co/UsefulSensors/moonshine-streaming-medium)). Cap segments at 30 s for Moonshine and about 2 minutes for Granite. The Granite figure is UNCONFIRMED and comes from a secondary source ([orcarouter](https://www.orcarouter.ai/blog/granite-speech-5-0-470m-turboctc-apache-explained)). Parakeet v3 can take a whole file with local attention ([card](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3)).

## 5. Comparison of every model checked

### 5.1 Speech-to-text

| Model | Params | On-disk size (format) | English WER | Languages | License | Verdict |
|---|---|---|---|---|---|---|
| Whisper large-v3-turbo (current Alona default) | 0.8B (UNCONFIRMED here) | 1.62 GB unquantized, 874 MB q8_0, 574 MB q5_0, plus a 1.17 GB Core ML encoder ([files](https://huggingface.co/ggerganov/whisper.cpp/tree/main)) | Whisper large-v3 scores 7.44% per [Warden](https://petewarden.com/2026/02/13/announcing-moonshine-voice/). Turbo's own average was not checked. | 99 (UNCONFIRMED here) | MIT | **Rejected as default.** Larger and less accurate than Parakeet v3, Granite 5.0, and Moonshine Medium. Keep it as an optional download for languages that no other model covers. |
| distil-large-v3.5 | 756M | GGML file at [distil-large-v3.5-ggml](https://huggingface.co/distil-whisper/distil-large-v3.5) | 7.08% short-form, 11.39% long-form (turbo: 10.25%) | English | MIT | **Rejected.** Worse than turbo on long-form audio ([card](https://huggingface.co/distil-whisper/distil-large-v3.5)). |
| Moonshine Streaming Tiny | 34M | 50.5 MB Q8_0 GGUF ([files](https://huggingface.co/handy-computer/moonshine-streaming-tiny-gguf)) | 12.01% | English, plus separate tiny models for ja, de, es, vi, ar, zh, tl | MIT | Emergency tier only |
| Moonshine Streaming Small | 123M | 198.5 MB Q8_0 GGUF | 7.84% | English (and de, es, ja as separate models) | MIT | **Lite pick** |
| Moonshine Streaming Medium | 245M | 296 MB Q8_0 GGUF ([files](https://huggingface.co/handy-computer/moonshine-streaming-medium-gguf)). About 270 MB as Moonshine Voice `.ort` files (estimate). | 6.65% | English | MIT ([card](https://huggingface.co/UsefulSensors/moonshine-streaming-medium)) | Lite upgrade when RAM ≥ 4 GB |
| Moonshine legacy non-streaming, non-English | tiny/base | 30 to 120 MB (sherpa-onnx archives) | n/a | ar, ja, ko, uk, vi, zh, es | **Moonshine Community License, non-commercial** ([repo](https://github.com/moonshine-ai/moonshine)) | **Rejected** on license |
| Parakeet TDT 0.6B v2 | 0.6B | Core ML ([FluidAudio](https://github.com/FluidInference/FluidAudio)) | not checked | English | CC-BY-4.0 (UNCONFIRMED for v2) | Superseded by v3 |
| Parakeet TDT 0.6B v3 | 0.6B | GGUF: 485 MB Q4_K_M, 740 MB Q8_0 ([files](https://huggingface.co/handy-computer/parakeet-tdt-0.6b-v3-gguf)). 487 MB int8 sherpa-onnx archive. About 470 MB of Core ML encoder plus decoder weights (estimate). | 6.34% | 25 European languages, auto-detected | CC-BY-4.0 ([card](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3)) | **Balanced pick** |
| Canary-1B-v2 | 978M | not checked | 7.15% | 25 European languages, plus translation | CC-BY-4.0 ([card](https://huggingface.co/nvidia/canary-1b-v2)) | **Rejected.** Larger and worse than Parakeet v3. |
| Nemotron 3.5 ASR Streaming 0.6B | 0.6B | GGUF for NeMo-Speech.cpp | FLEURS English 7.91% to 9.72% | 40 locales | OpenMDW-1.1, commercial use allowed ([card](https://huggingface.co/nvidia/nemotron-3.5-asr-streaming-0.6b)) | **Rejected.** Listed hardware is NVIDIA GPUs on Linux only. |
| Nemotron 3.5 Transcribe | about 34B total, 4.3B active (UNCONFIRMED, [aiwiki](https://aiwiki.ai/wiki/nemotron_3_5_transcribe)) | n/a | 5.33% (UNCONFIRMED) | 40 | OpenMDW-1.1 | **Rejected.** Too large. |
| Granite Speech 5.0 470M TurboCTC | 470M | 279 MB Q4_K_M, 506 MB Q8_0 | 5.51% | en, fr, de, es, pt, it, ja | Apache-2.0 ([card](https://huggingface.co/ibm-granite/granite-speech-5.0-470m-turboctc)) | **Quality pick** |
| Granite Speech 5.0 470M TurboCTC-NC | 470M | n/a | n/a | English | CC-BY-NC-SA-4.0 (UNCONFIRMED, [gradually.ai](https://www.gradually.ai/en/ai-models/granite-speech-5.0-470m-turboctc-nc/)) | **Rejected** on license. Do not confuse it with the pick. |
| Granite Speech 4.1 2B Plus | 2B | not checked | 6.10% | en, fr, de, es, pt | Apache-2.0 ([card](https://huggingface.co/ibm-granite/granite-speech-4.1-2b-plus)) | **Rejected for now.** Built-in `[Speaker N]` attribution is attractive, but it was evaluated only up to 9 minutes and outputs no punctuation. |
| Cohere Transcribe 03-2026 | 2B | BF16 (size not checked) | 5.42% | 14 | Apache-2.0 ([blog](https://huggingface.co/blog/CohereLabs/cohere-transcribe-03-2026-release)). Gated download (UNCONFIRMED). | **Rejected.** 4x the size of Granite 5.0 for 0.09 points of WER. The vendor documents only vLLM serving. |
| Qwen3-ASR-0.6B | 0.9B per safetensors | 590 MB Q4_K_M, 850 MB Q8_0 ([files](https://huggingface.co/handy-computer/Qwen3-ASR-0.6B-gguf)) | LibriSpeech 2.11 / 4.55 (no Open ASR average) | 52 languages and dialects | Apache-2.0 ([card](https://huggingface.co/Qwen/Qwen3-ASR-0.6B)) | **Reserve.** Best option for Chinese, Japanese, and Korean. Timestamps need a separate aligner that is limited to 5 minutes. |
| Qwen3-ASR-1.7B | 1.7B | not checked | 5.40% (UNCONFIRMED, [aggregator](https://pinggy.io/blog/best_open_source_self_hosted_speech_to_text_models/)) | 52 | Apache-2.0 | Not evaluated further |
| Voxtral Mini 4B Realtime 2602 | 4B | BF16 | Long-form English: 5.05% on Meanwhile, 3.17% on TED-LIUM | 13 | Apache-2.0 ([card](https://huggingface.co/mistralai/Voxtral-Mini-4B-Realtime-2602)) | **Rejected.** The card asks for a GPU with ≥ 16 GB. Mistral deprecated it on 2026-10-31 ([docs](https://docs.mistral.ai/models/voxtral-mini-transcribe-realtime-26-02.md)). |
| Kyutai STT 1B en/fr | 1B | BF16 | not published | en, fr | CC-BY-4.0 ([card](https://huggingface.co/kyutai/stt-1b-en_fr)) | **Rejected.** Two languages, and no mobile runtime. |
| SenseVoice Small | similar to Whisper Small | n/a | n/a | zh, yue, en, ja, ko | "model-license", commercial terms unclear ([card](https://huggingface.co/FunAudioLLM/SenseVoiceSmall)) | **Rejected** pending license review |
| Apple SpeechTranscriber | system model | 0 (OS asset) | not published | Varies, query at runtime | Free on OS 26+ | Zero-download fallback on Apple platforms. Its device list and locale count are UNCONFIRMED ([callstack](https://www.callstack.com/blog/on-device-speech-transcription-with-apple-speechanalyzer)). |

Diarization options:

- **pyannote Community-1.** CC-BY-4.0, gated on Hugging Face, and lower diarization error rate than pyannote 3.1 on 10 of 12 datasets. AMI IHM drops from 18.8 to 17.0 ([card](https://huggingface.co/pyannote/speaker-diarization-community-1)). It runs through FluidAudio (Core ML), Moonshine Voice, and WhisperKit's SpeakerKit.
- **Streaming alternatives in FluidAudio.** LS-EEND handles up to 10 speakers. Sortformer handles up to 4 speakers and uses the NVIDIA Open Model License ([FluidAudio](https://github.com/FluidInference/FluidAudio)).

### 5.2 Meeting-notes LLMs

| Model | Params | Q4_K_M GGUF | Context | Long-context or task evidence | License | Verdict |
|---|---|---|---|---|---|---|
| Qwen3.5-0.8B | 0.8B | 533 MB | 262K | none for this task | Apache-2.0 | **Lite pick** |
| Qwen3.5-2B | 2B | 1.28 GB (1.2 GB per Hedy, 3 GB RAM at load) | 262K | LongBench v2: 38.7. The card warns of "thinking loops", so use non-thinking mode. | Apache-2.0 ([card](https://huggingface.co/Qwen/Qwen3.5-2B)) | **Balanced pick** |
| Qwen3.5-4B | 4B | 2.74 GB (4.5 GB RAM at load per Hedy) ([files](https://huggingface.co/unsloth/Qwen3.5-4B-GGUF)) | 262K | Hedy ships it on iPhone 15 Pro and later | Apache-2.0 | Optional upgrade for Balanced on 8 GB+ devices |
| Qwen3.5-9B | 9B | 5.68 GB (8 GB RAM at load per Hedy) | 262K | Hedy rates it equal to Gemma 4 E4B | Apache-2.0 | **Quality pick** |
| Qwen3 0.6B / 1.7B / 4B | as named | not checked | 32,768 native ([card](https://huggingface.co/Qwen/Qwen3-1.7B)) | n/a | Apache-2.0 | Superseded by Qwen3.5 |
| Gemma 4 E2B | 2.3B effective, 5.1B total | 3.11 GB ([files](https://huggingface.co/unsloth/gemma-4-E2B-it-GGUF)). 2.34 GB as `.litertlm` for GPU. About 3.3 GB as browser ONNX q4f16 (estimate). | 128K | MRCR 128K: 19.1% | Apache-2.0 ([card](https://huggingface.co/google/gemma-4-E2B)) | Android fallback through LiteRT-LM. Too large for the browser Lite tier. |
| Gemma 4 E4B | 4.5B effective, 8B total | 4.98 GB ([files](https://huggingface.co/unsloth/gemma-4-E4B-it-GGUF)) | 128K | MRCR 128K: 25.4% | Apache-2.0 | Alternative to Qwen3.5-9B for Quality. Run both through the eval harness. |
| Gemma 3 270M / 1B / 4B | as named | not checked | 1B: 32K. 4B: 128K ([card](https://huggingface.co/google/gemma-3-1b-it)). | n/a | Gemma Terms of Use | Superseded by Gemma 4 (Apache) |
| Gemma 3n E2B / E4B | n/a | not checked | UNCONFIRMED | n/a | Gemma Terms (UNCONFIRMED) | Superseded by Gemma 4. Not re-checked. |
| Phi-4-mini-instruct | 3.8B | not checked | 128K | n/a | MIT ([card](https://huggingface.co/microsoft/Phi-4-mini-instruct)) | **Rejected.** No size advantage over Qwen3.5-4B, and no browser ONNX build was found. |
| Llama 3.2 1B / 3B | as named | not checked | 128K (quantized builds: 8K) | n/a | Llama 3.2 Community License ([card](https://huggingface.co/meta-llama/Llama-3.2-3B-Instruct)) | **Rejected.** Restrictive license, older model. |
| SmolLM3-3B | 3B | not checked | 64K native, 128K with YaRN | n/a | Apache-2.0 ([card](https://huggingface.co/HuggingFaceTB/SmolLM3-3B)) | **Rejected.** Shorter native context than Qwen3.5, and no meeting-task evidence. |
| LFM2.5-1.2B-Instruct | 1.2B | 731 MB ([files](https://huggingface.co/LiquidAI/LFM2.5-1.2B-Instruct-GGUF)). 760 MB ONNX q4f16. | not checked | n/a | LFM Open License | License-gated (section 6) |
| LFM2-2.6B-Transcript | 2.6B | 1.56 GB ([files](https://huggingface.co/LiquidAI/LFM2-2.6B-Transcript-GGUF)) | not stated | Fine-tuned for meeting summaries. LiquidAI claims under 3 GB RAM and evaluated it on 1K and 10K-token transcripts. | LFM Open License. English only. ([card](https://huggingface.co/LiquidAI/LFM2-2.6B-Transcript)) | Best task-specific candidate if the license is acceptable. A/B it against Qwen3.5-2B. |
| LFM3-1.7B | 1.73B | 1.10 GB ([files](https://huggingface.co/LiquidAI/LFM3-1.7B-GGUF)). 1.38 GB ONNX q4f16. | 256K | RULER 128K: 65.56. AA-LCR: 52.83. | LFM Open License v1.0 ([card](https://huggingface.co/LiquidAI/LFM3-1.7B)) | The strongest long-context numbers at this size. License-gated. |
| Granite 4.0 1B / 350M | 1.6B / 350M | not checked | 128K / 32K | n/a | Apache-2.0 ([card](https://huggingface.co/ibm-granite/granite-4.0-1b)) | Not evaluated further |
| Apple Foundation Models | system model | 0 | 4,096 tokens per session | n/a | Free on Apple Intelligence devices | Fallback for short tasks only, such as titling or rewriting one note |
| Gemini Nano (ML Kit Prompt API) | system model | 0 | under 4,000 input tokens (UNCONFIRMED), output under 256 tokens advised | n/a | ML Kit GenAI additional terms ([Android](https://developer.android.com/ai/gemini-nano)) | **Rejected** as primary. Beta, limited to some devices, foreground only. |

Speed data: the only measured tokens-per-second figure found in this research is Gemma 4 E2B at 52 tokens/s decode on a Galaxy S26 Ultra GPU through LiteRT-LM ([Google](https://developers.googleblog.com/en/blazing-fast-on-device-genai-with-litert-lm/)). Speeds for the Qwen3.5 picks on phones and laptops are UNCONFIRMED. Measure them with the first-launch probe (section 2.2).

## 6. Licensing blockers for a commercial app

| Item | Blocker | Action |
|---|---|---|
| Parakeet v3, Canary, pyannote Community-1 (CC-BY-4.0) | Attribution is required | Credit NVIDIA and pyannote in the app's About screen and in the redistributed model folder. Commercial use is allowed. |
| pyannote Community-1 | Gated download on Hugging Face | Accept the conditions once, then host the weights on Alona's own CDN under CC-BY-4.0. Do not make each end user log in to Hugging Face. |
| LFM2.5, LFM2-Transcript, LFM3 (LFM Open License v1.0) | Commercial rights end at about $10M annual revenue ("$10M or more" in the license definition vs "exceeds" in the FAQ). The limit applies to modified models, and downstream customers are assessed separately ([Liquid docs](https://docs.liquid.ai/lfm/help/model-license)). | Legal review before shipping. Default picks avoid LFM models. |
| Moonshine legacy non-English non-streaming models | Moonshine Community License, non-commercial | Use only the streaming models (MIT). |
| Granite Speech 5.0 TurboCTC-NC | CC-BY-NC-SA-4.0 (UNCONFIRMED) | Pin the exact repo ID `ibm-granite/granite-speech-5.0-470m-turboctc`. |
| Llama 3.2 | 700M MAU cap, "Built with Llama" display, naming rules for derivatives | Not picked |
| Gemma 3 / 3n | Gemma Terms of Use | Not picked. Gemma 4 is Apache-2.0. |
| Sortformer diarizer | NVIDIA Open Model License | Not picked. Read the license before enabling it. |
| Gemini Nano | ML Kit GenAI Additional Terms | Not picked |
| SenseVoice | "model-license", terms unclear | Not picked |
| Nemotron 3.5 | OpenMDW-1.1 (commercial use allowed) | Not picked, for runtime reasons |

No default pick (Moonshine Streaming, Parakeet v3, Granite Speech 5.0, Qwen3.5) blocks commercial use. Parakeet v3 and pyannote require visible attribution.

## 7. Sources

Speech-to-text:

- https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3
- https://huggingface.co/handy-computer/parakeet-tdt-0.6b-v3-gguf
- https://huggingface.co/istupakov/parakeet-tdt-0.6b-v3-onnx
- https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml
- https://github.com/k2-fsa/sherpa-onnx/releases/tag/asr-models
- https://huggingface.co/striimit/parakeet-tdt-0.6b-v3-webgpu
- https://cdn.jsdelivr.net/npm/onnx-asr-web@0.1.3/README.md
- https://huggingface.co/nvidia/canary-1b-v2
- https://huggingface.co/nvidia/nemotron-3.5-asr-streaming-0.6b
- https://aiwiki.ai/wiki/nemotron_3_5_transcribe
- https://petewarden.com/2026/02/13/announcing-moonshine-voice/
- https://arxiv.org/abs/2602.12241
- https://github.com/moonshine-ai/moonshine
- https://moonshine-voice.readthedocs.io/en/latest/
- https://moonshine-voice.readthedocs.io/en/latest/quickstart/
- https://huggingface.co/UsefulSensors/moonshine-streaming-medium
- https://huggingface.co/moonshine-ai
- https://huggingface.co/moonshine-ai/moonshine-voice-assets
- https://huggingface.co/handy-computer/moonshine-streaming-medium-gguf
- https://huggingface.co/handy-computer/moonshine-streaming-small-gguf
- https://huggingface.co/handy-computer/moonshine-streaming-tiny-gguf
- https://github.com/ggml-org/whisper.cpp
- https://huggingface.co/ggerganov/whisper.cpp/tree/main
- https://huggingface.co/distil-whisper/distil-large-v3.5
- https://huggingface.co/ibm-granite/granite-speech-5.0-470m-turboctc
- https://huggingface.co/handy-computer/granite-speech-5.0-470m-turboctc-gguf
- https://www.orcarouter.ai/blog/granite-speech-5-0-470m-turboctc-apache-explained
- https://www.gradually.ai/en/ai-models/granite-speech-5.0-470m-turboctc-nc/
- https://huggingface.co/ibm-granite/granite-speech-4.1-2b-plus
- https://huggingface.co/blog/CohereLabs/cohere-transcribe-03-2026-release
- https://huggingface.co/Qwen/Qwen3-ASR-0.6B
- https://huggingface.co/handy-computer/Qwen3-ASR-0.6B-gguf
- https://pinggy.io/blog/best_open_source_self_hosted_speech_to_text_models/
- https://huggingface.co/mistralai/Voxtral-Mini-4B-Realtime-2602
- https://docs.mistral.ai/models/voxtral-mini-transcribe-realtime-26-02.md
- https://huggingface.co/kyutai/stt-1b-en_fr
- https://huggingface.co/FunAudioLLM/SenseVoiceSmall
- https://huggingface.co/pyannote/speaker-diarization-community-1
- https://github.com/handy-computer/transcribe.cpp
- https://github.com/FluidInference/FluidAudio
- https://github.com/argmaxinc/WhisperKit
- https://www.callstack.com/blog/on-device-speech-transcription-with-apple-speechanalyzer

LLMs:

- https://huggingface.co/Qwen/Qwen3.5-2B
- https://huggingface.co/unsloth/Qwen3.5-0.8B-GGUF
- https://huggingface.co/unsloth/Qwen3.5-2B-GGUF
- https://huggingface.co/unsloth/Qwen3.5-4B-GGUF
- https://huggingface.co/unsloth/Qwen3.5-9B-GGUF
- https://huggingface.co/mlx-community/Qwen3.5-9B-4bit
- https://huggingface.co/onnx-community/Qwen3.5-0.8B-ONNX
- https://huggingface.co/onnx-community/Qwen3.5-2B-ONNX
- https://huggingface.co/Qwen/Qwen3-1.7B
- https://huggingface.co/google/gemma-4-E2B
- https://huggingface.co/unsloth/gemma-4-E2B-it-GGUF
- https://huggingface.co/unsloth/gemma-4-E4B-it-GGUF
- https://huggingface.co/onnx-community/gemma-4-E2B-it-ONNX
- https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm
- https://huggingface.co/google/gemma-3-1b-it
- https://huggingface.co/microsoft/Phi-4-mini-instruct
- https://huggingface.co/meta-llama/Llama-3.2-3B-Instruct
- https://huggingface.co/HuggingFaceTB/SmolLM3-3B
- https://huggingface.co/ibm-granite/granite-4.0-1b
- https://huggingface.co/LiquidAI/LFM2-2.6B-Transcript
- https://huggingface.co/LiquidAI/LFM2-2.6B-Transcript-GGUF
- https://huggingface.co/LiquidAI/LFM2.5-1.2B-Instruct-GGUF
- https://huggingface.co/LiquidAI/LFM2.5-1.2B-Instruct-ONNX
- https://huggingface.co/LiquidAI/LFM3-1.7B
- https://huggingface.co/LiquidAI/LFM3-1.7B-GGUF
- https://huggingface.co/LiquidAI/LFM3-1.7B-ONNX
- https://docs.liquid.ai/lfm/help/model-license
- https://hedy.ai/post/local-ai-engineering-deep-dive-hedy-3-2/

Runtimes, platforms, and evidence for the long-transcript design:

- https://huggingface.co/blog/transformersjs-v4
- https://developers.googleblog.com/en/blazing-fast-on-device-genai-with-litert-lm/
- https://developer.android.com/ai/gemini-nano
- https://developers.google.com/ml-kit/genai/prompt/android/get-started
- https://developer.apple.com/tutorials/data/documentation/technotes/tn3193-managing-the-on-device-foundation-model-s-context-window.md
- https://support.apple.com/en-us/121115
- https://developer.mozilla.org/en-US/docs/Web/API/Navigator/deviceMemory
- https://developer.mozilla.org/en-US/docs/Web/API/GPUAdapter/info
- https://developer.mozilla.org/docs/Web/API/Storage_API/Storage_quotas_and_eviction_criteria
- https://www.itnews.com.au/news/apple-cops-flak-for-deleting-local-browser-storage-after-7-days-539833
- https://bugs.webkit.org/show_bug.cgi?id=276998
- https://bugs.webkit.org/show_bug.cgi?id=300538
- https://spidermonkey.dev/blog/2025/01/15/is-memory64-actually-worth-using.html
- https://web.dev/blog/webgpu-supported-major-browsers
- https://developer.android.com/reference/android/app/ActivityManager.MemoryInfo
- https://www.trychroma.com/research/context-rot
- https://arxiv.org/abs/2310.00785
- https://arxiv.org/abs/2606.08445
- https://arxiv.org/pdf/2509.15901
- Package versions: the crates.io API (`https://crates.io/api/v1/crates/<name>`), the npm registry (`https://registry.npmjs.org/<name>`), and GitHub releases (`https://api.github.com/repos/<owner>/<repo>/releases/latest`), all queried 2026-11-14.
