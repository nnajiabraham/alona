# Alona

Private meeting notes. Alona records a meeting, transcribes it with a small speech model, and has a small language model write the notes. Both models run on the device, and the only network use is downloading them once.

One [Exact](https://github.com/expo/exact) app builds the web, macOS, iOS, and Android versions.

## Status

| Platform | Screens and flows (demo engine) | Real models |
|---|---|---|
| macOS | 6 of 6 flows pass | All three tiers run: sherpa-onnx and llama.cpp in a Swift module |
| Web | 6 of 6 flows pass | Lite tier runs in Chrome on WebGPU, recording from Chrome's fake microphone |
| Android | 6 of 6 flows pass on an emulator | Demo engine only; the native bridge is not built |
| iOS | Not built | Needs Xcode 27.1 on the build machine |

No hardware microphone and no real meeting has been run on any platform. Accuracy figures come from synthetic voices.

The demo engine returns a sample transcript and sample notes, and the app says so on screen.

## Read next

- **Field guide:** open `docs/explainer/index.html` in a browser. It covers the system design, each flow with screenshots and videos, the brand, measured results, and developer setup.
- **Guidelines for contributors and agents:** `AGENTS.md`.
- **Why the models were chosen:** `docs/research/local-models-2026-11.md`.
- **How decisions were made:** `docs/rewrite/decisions.tsv`.

## Quick start

```sh
git clone https://github.com/expo/exact.git ../exact
git -C ../exact checkout 3baa28ffa5e2598f2eca2ff5d830fa2b444e741f
bun ../exact/scripts/exact.mjs setup
# Only on Xcode older than 27.1, for the macOS build:
git -C ../exact apply "$PWD/tools/patches/exact-3baa28f-xcode26.patch"
bun install && bun exact.mjs update
bun exact.mjs web
```

The field guide lists the extra steps for macOS, Android, and the web engine.

The original Swift app is in `legacy/macos-swift/`.
