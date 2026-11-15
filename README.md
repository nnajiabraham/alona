# Alona

Private meeting notes. Alona records a meeting, transcribes it with a small speech model, and has a small language model write the notes. Both models run on the device, and the only network use is downloading them once.

One [Exact](https://github.com/expo/exact) app builds the web, macOS, iOS, and Android versions.

## Status

| Platform | Screens and flows (demo engine) | Real models |
|---|---|---|
| macOS | 14 of 14 flows pass | All three tiers run: sherpa-onnx and llama.cpp in a Swift module |
| Web | 8 of 8 flows pass | Lite tier runs in Chrome on WebGPU, recording from Chrome's fake microphone |
| Android | 8 of 8 flows pass on an emulator | Lite and Balanced run on an 8 GB emulator: sherpa-onnx and llama.cpp in a Kotlin package. Not run on a physical phone |
| Linux (`.deb`) | Flows pass in a container | Demo engine there (no GPU); real models are not verified |
| Windows | Built, never run | Not verified |
| iOS | Not built | Xcode 27.1 is installed on the build machine but not licensed yet |

On macOS the app also records other apps' audio, detects Zoom and Meet, lives in the menu bar, saves to a folder you choose, and imports the Swift app's recordings. Those pass their flows with stand-ins for the parts behind a permission prompt. The real capture, live detection, and notifications have not been seen working yet.

The notes pad has a formatting toolbar on every platform, for people who do not know Markdown.

No hardware microphone and no real meeting has been run on any platform. Accuracy figures come from synthetic voices.

The demo engine returns a sample transcript and sample notes, and the app says so on screen.

## Two apps, one foundation

- **Alona** is the meeting assistant at the repository root.
- **The clinical app** in `clinic/` is a patient note-taking and transcription app for health professionals on web, Android, and iOS. It is white-label: each tenant is one typed config file under `tenants/`, and `bun tools/tenant.mjs build <slug> web` turns that file into a branded build. See `tenants/README.md`.

Windows and Linux use an Electron shell (`desktop/`) around Alona's web build, because Exact cannot target either as a desktop app.

## Read next

- **Clinical guide:** open `docs/explainer/clinic.html` for how the clinical app looks under each brand, a visit step by step, and the workflows it covers.
- **Field guide:** open `docs/explainer/index.html` in a browser. It covers the system design, each flow with screenshots and videos, the brand, measured results, and developer setup.
- **Guidelines for contributors and agents:** `AGENTS.md`.
- **Why the models were chosen:** `docs/research/local-models-2026-11.md`.
- **How decisions were made:** `docs/rewrite/decisions.tsv`.

## Releases

`bun tools/release.mjs build` builds every platform's package into `release/`, and `bun tools/release.mjs publish` creates a GitHub release with notes and checksums. Every package is unsigned or ad-hoc signed.

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
