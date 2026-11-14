# Web inference engine

The web host's engine answers the protocol in `core/engine.ts` through `native.later`, with real models on WebGPU. It follows the Apple engine (`modules/apple/Engine.swift`). It holds one model in memory at a time, checks for cancel during work, and counts a model file as installed only after it has been verified.

## What is where

| Path | What it is |
|---|---|
| `modules/web/index.js` | The page module, hand-written. It holds `later(request)`, the job table, the device probe, downloads into the Cache API, and reading and decoding the recording. Nothing at its top level touches a browser API, because Exact imports it in Bun at build time. |
| `modules/web/sha256.js` | Incremental SHA-256. Web Crypto can't hash a stream. |
| `engine/web/` | The worker's package. `@huggingface/transformers` 4.3.2 and `onnxruntime-web` 1.31.0-dev.20260914-8d85527a0 are pinned exactly, with `bun.lock`. `src/worker.js` holds model loading, windowed speech-to-text, generation, partial text, and cancel. |
| `tools/build-web-engine.mjs` | Installs `engine/web` (frozen lockfile) and bundles the worker to `modules/web/worker.js`. It copies the ORT asyncify wasm pair to `modules/web/ort/` and fails if the version transformers.js resolves differs from the pin or if the bundle doesn't carry it. Its outputs are git-ignored. |
| `tools/pin-models.mjs` | Adds `moonshine-base.onnx` (runtime `transformers-moonshine`, 7 files, 157.5 MB) and `qwen3.5-0.8b.onnx` (runtime `transformers-qwen`, 8 files, 603.9 MB). `bun tools/pin-models.mjs <id>…` re-pins only the ids you name. |
| `core/models.ts` | Lite has `web:` entries. Balanced and Quality have none, so browsers are offered Lite only. Balanced on web (Qwen3.5-2B) was not tried. |
| `tools/e2e-web.mjs`, `tools/e2e/` | The real-model check in installed Chrome. `tools/e2e` is a tools-only package holding `playwright-core` 1.64.0. |
| `tools/fixture/` | The 53 s fixture and its reference text. |

Rebuild: `bun tools/build-web-engine.mjs`. Run the check: `cd tools/e2e && bun install && cd ../.. && bun tools/e2e-web.mjs`.

## Behavior

- **probe** returns `host: 'web'` and these facts:
  - `memoryGB` from `navigator.deviceMemory`
  - `cores`
  - `gpu`: true only for a WebGPU adapter that is neither a fallback nor a software adapter (SwiftShader, llvmpipe) and that supports `shader-f16`
  - `gpuMaxBufferGB`
  - `storageFreeGB`: quota minus usage
  - `formFactor`
  - `iosBrowser`: also covers iPadOS, which reports itself as a Mac with touch
  - a description such as "Chrome on macOS"

  It adds `demo: true` when `navigator.webdriver` is true or when no real adapter was found. Exact's agent runs headless Chrome on SwiftShader, so `test web` and `flows.mjs` get the demo engine and download nothing. Checked: the agent's `setup.deviceLine` reads "Demo device".
- **download** fetches each file on the page, not in the worker, so `unload` cannot kill a download. Each file is streamed and hashed (SHA-256 of every file, including the 437 MB weights) and its byte count is checked against the pin. Only a file that passes both checks is put into `transformers-cache` under the exact URL transformers.js reads. So "installed" means every file is cached with the pinned size. `navigator.storage.persist()` is requested after the first successful download. In the e2e profile it returned `persisted: false`.
- **No network at inference.** The worker replaces `env.fetch` with a function that answers 404, so a file missing from the cache fails the load ("Could not locate file") instead of downloading. Before loading, it sets `env.remotePathTemplate` to the pinned revision. That is needed because transformers.js 4.3.2 fetched `resolve/main/config.json` even when `revision` was passed.
- **transcribe** reads the recording from Exact's IndexedDB (`exact-storage:*`, store `files`, key = the `app:/` path). It retries for 60 s if the file is not there yet. It decodes to 16 kHz mono with `OfflineAudioContext` and transfers the samples to the worker. The worker cuts windows of 12 to 20 s, each ending at the quietest 30 ms frame. It skips windows with under 0.3 s above the noise floor and trims each window to its speech, padded by 0.2 s. Segments carry those real times, and progress advances as each window finishes.
- **generate** tokenizes the raw prompt without adding special tokens. It samples with temperature 0.7, top-k 20, and top-p 0.8, applies a presence penalty of 1.5 over the last 64 generated tokens (a custom logits processor matching the Swift Writer's llama.cpp penalty), and uses `random.seed(42)`. It stops at `<|im_end|>` or `<|endoftext|>`, posts partial text every 200 ms, and cancels through `InterruptableStoppingCriteria`.
- **unload** waits for the job in flight, then terminates the Worker. A job that needs a different model also terminates the Worker first. The spike found that only termination returns memory.

## Measured (`bun tools/e2e-web.mjs`, Chrome 157, Apple Silicon, 32 GB, Metal WebGPU)

These numbers come from the run whose output is in `docs/media/web-real/e2e.json`. Method:

- WER is word-level edit distance after lowercasing and stripping punctuation.
- Times are `performance.now()` in the worker.
- TTFT is from the start of `generate()` to the first streamed token.
- Memory is the `ps` RSS of the profile's renderer and GPU processes, sampled every 0.5 s. The after-unload value is read 3 s after `unload`.

| | Run 1 (after recording) | Run 2 ("Transcribe again") |
|---|---|---|
| WER | 4.17% (7 / 168) | 4.17% (7 / 168) |
| Transcribe 53 s of audio (model load) | 3.84 s (1.18 s) | 4.47 s (1.25 s) |
| Notes: prompt tokens, TTFT, decode | 466, 14.1 s, 41.4 tok/s, 272 tokens | 466, 14.3 s, 41.4 tok/s, 272 tokens |
| Stop (or click) to notes on screen | 38.1 s | 29.8 s |
| Peak RSS, renderer + GPU | 3,952 MB (3,087 + 865) | 4,072 MB (3,143 + 928) |
| RSS 3 s after `unload` | 2,101 MB (1,725 + 376) | 2,148 MB (1,756 + 393) |

Download: 761,444,246 bytes in 19.5 s on this network. Run 1's "decode" time (8.0 s) includes the engine waiting for the recording that the e2e wrote (see below), so it is not a decode time. Run 2's decode took 8 ms. After `unload`, memory rose by 47 MB between runs; two runs are not enough to call that a trend. Both runs' notes have all five headings. Run 1's notes are in `e2e.json`. They attribute "I will own the login fix" without the owner's name, and they list a sign-off that nobody mentioned, which is draft quality from the 0.8B model.

## Not verified

- **The microphone and the app's recorder in this run.** On this Mac, Chrome's fake capture device never answers `getUserMedia`, even for a camera on a blank page and under Chrome for Testing. The likeliest cause is macOS microphone permission for a browser started by this tool. The e2e then replaces `getUserMedia` with a Web Audio stream that plays the fixture. In that mode the app's recorder left no `audio.m4a` for the meeting, although `meeting.json` was written. A manual 5 s and 40 s recording with the same replacement did write `audio.m4a` (AAC in MP4, 650 KB for 40 s). When the file is missing, the e2e writes the fixture WAV at the meeting's audio path and says so in `e2e.json` (`recording`). So decoding a real MP4 recording through the engine is **NOT VERIFIED** end to end. Decoding of the WAV is verified.
- Safari, Firefox, iOS, Android, 8 GB machines, eviction, resumable downloads (an interrupted file is fetched again in full), and the render server's CSP for Hugging Face fetches.
- Balanced (Qwen3.5-2B ONNX) on web.

## Risks

- The page module reads Exact's private IndexedDB layout. Exact needs a supported way for a page module to read an `app:/` file.
- Prefill is slow. TTFT was 14.5 s for 466 tokens. The Lite one-shot budget of 3,000 tokens would wait well over a minute before the first token (an estimate from the spike's linear rate, not measured).
- Peak RSS was about 3.9 GB for the 0.8B model.
- An hour-long recording decodes to about 230 MB of samples in one buffer (not measured).
