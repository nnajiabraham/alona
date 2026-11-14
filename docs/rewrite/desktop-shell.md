# Desktop shell: Windows and Linux

Alona's Windows and Linux apps are an Electron shell around the web build. The shell serves the site that `bun exact.mjs web-build` makes, so the screens, the data module, and the web engine (transformers.js and ONNX Runtime on WebGPU, in a Worker) are the same code that runs in a browser. The shell adds a window, a locked-down origin, cross-origin isolation, a microphone grant, and installers.

## Why Electron, and not Exact's hosts

- **Linux.** Exact's Linux host paints onto DRM/KMS or runs headless. It has no packaging, and its README says "Linux editing. The web and Apple hosts edit; Linux reads." Alona's notes and titles need text editing, and a `.deb` needs a desktop window.
- **Windows.** `bun exact.mjs windows` prints "a Windows build needs Windows with the MSVC Rust target; nothing was written". It cannot be built or run from the Mac, and the Rust runner would still need an inference engine for Windows that does not exist.
- **The web build already runs real models.** `docs/rewrite/web-engine-notes.md` measured Lite end to end in Chrome. A shell around it inherits that work. A shell also controls its own responses, so it can send COOP and COEP, which no Exact server sends. `docs/rewrite/spikes/web-engine.md` measured cross-origin isolation making the WASM paths 2.7 to 3.8 times faster.

## What is where

| Path | What it is |
|---|---|
| `desktop/main.js` | The main process. It serves the site over `alona://app`, sets the security policy, and opens the window. |
| `desktop/package.json`, `desktop/bun.lock` | `electron` 45.2.1 and `electron-builder` 26.18.1, pinned exactly. |
| `desktop/electron-builder.json` | The packaging: app id `com.alona.app`, product name Alona, `.deb` for x64 and arm64, NSIS for Windows x64, fuses, no publish. |
| `desktop/resources/icon.png` | 512 px, scaled from `legacy/macos-swift/Alona/Resources/alona_icon_main.png`. |
| `tools/build-desktop.mjs` | One command that builds everything (below). |
| `tools/e2e-desktop.mjs` | Drives the shell through the UI with Playwright's Electron support. |
| `tools/e2e/linux-deb.sh` | Installs the `.deb` in a clean Ubuntu 24.04 container and runs the flows there. |
| `docs/media/desktop/<platform>/` | Screenshots per step, `e2e.mp4`, `e2e.json`. Linux also has `linux-deb.log`. |

## Build

```sh
export PATH=~/.bun-1.4.2/bin:$PATH
bun install && (cd tools/e2e && bun install)
bun tools/build-desktop.mjs          # web engine, site, both .deb files, Windows installer
bun tools/build-desktop.mjs linux    # or: win, or site (only dist/desktop-site)
```

The script builds the web engine (`tools/build-web-engine.mjs`) and then the site into `dist/desktop-site`. Exact refuses to build anywhere outside `dist/` or `target/`. Then the script installs `desktop/` from its lockfile, fetches the Electron binary (Electron 45 downloads it on first use, not at install), and runs electron-builder. Outputs go to `desktop/out/` (git-ignored), with `artifacts.json` listing each file's size and SHA-256. If the NSIS step fails, the script builds a portable zip instead and says why in `artifacts.json`. On this Mac the NSIS step did not fail. electron-builder 26 ships `makensis` for macOS and edits the exe's resources without Wine.

Artifacts from the run on 2026-11-14 (`desktop/out/artifacts.json`):

| File | Size |
|---|---|
| `alona_0.1.0_amd64.deb` | 107,674,780 bytes (107.7 MB) |
| `alona_0.1.0_arm64.deb` | 102,525,728 bytes (102.5 MB) |
| `Alona-Setup-0.1.0-x64.exe` (NSIS, unsigned) | 127,006,370 bytes (127.0 MB) |

The models are not in the packages. The app downloads Lite (761,444,246 bytes) on first use, as the web app does.

## Verify

```sh
bun tools/e2e-desktop.mjs                 # this machine, unpacked shell, real models (fails on the demo engine)
bash tools/e2e/linux-deb.sh               # Ubuntu 24.04 arm64 container; ARCH=amd64 for the other .deb
```

`e2e-desktop.mjs` launches the shell with Chromium's fake capture device playing `tools/fixture/meeting-fixture.wav`. It does not use `--use-fake-ui-for-media-stream`, so the shell's own permission handler decides the microphone grant. It switches off Blink's automation flag, so `navigator.webdriver` is false and the page module picks the real engine wherever it finds a real WebGPU adapter. The drive is: first launch (device check), download, record, stop, notes, transcript, settings. Then it calls `window.open` and sets `location.href` to an outside URL and checks that both are refused. It reads every network origin from Chromium's net log (`--log-net-log`), which covers the whole browser, including requests the page never sees.

Two test-only arguments matter:

- `--disable-features=AudioServiceOutOfProcess`. Without it, the sandboxed audio service cannot open the fixture and the page gets silence. Measured inside Electron: peak sample 0 with the file, 0.99997 with Chromium's built-in beep, and 1.0 with the file once the audio service ran in process. The first Mac run recorded 56 s of silence (a 21 KB `audio.m4a`) before this was found. The same cause is the likeliest reason `tools/e2e-web.mjs` saw Chrome's fake device fail, but that is a guess and was not tested in Chrome.
- `--no-video`. Playwright's screencast stalled the page under software rendering in the container: no screenshot completed and the device check never appeared within 60 s. Without the screencast the same run passed. `linux-deb.sh` records the virtual display with `ffmpeg -f x11grab` instead.

## Verdicts

| Platform | Shell runs | Real models | Flows | Package installs | Notes |
|---|---|---|---|---|---|
| macOS (Electron 45.2.1, unpacked) | VERIFIED | VERIFIED (Metal WebGPU) | VERIFIED | not built | Not a shipping target. macOS ships the native Exact app. This run proves the shell. |
| Linux arm64 `.deb`, Ubuntu 24.04 container | VERIFIED | **NOT VERIFIED** (no GPU, demo engine) | VERIFIED with the demo engine | VERIFIED | Menu entry command opens a window titled Alona. |
| Linux x64 `.deb` | NOT VERIFIED | NOT VERIFIED | NOT VERIFIED | NOT VERIFIED | Built only. `ARCH=amd64 bash tools/e2e/linux-deb.sh` runs it under emulation; not run. |
| Windows x64 NSIS | **NOT VERIFIED** | **NOT VERIFIED** | **NOT VERIFIED** | NOT VERIFIED | Static checks only (below). |

### macOS, real models

`bun tools/e2e-desktop.mjs`, Apple Silicon, 32 GB. The figures below are from the second of two passing runs (the second ran after the spellchecker change below). Result: `docs/media/desktop/macos/e2e.json`. Every check passed:

- `crossOriginIsolated` was true and `SharedArrayBuffer` was available.
- The WebGPU adapter was `apple` / `metal-3` with `shader-f16`. The probe reported `gpu: true` and `demo: false`.
- One window, titled Alona, 1040 by 760, minimum 420 by 560.
- Download: 761,444,246 bytes in 9.5 s from huggingface.co.
- The app's own recorder wrote `audio.m4a` (911,253 bytes for 56 s). The fixture reached the app through the microphone path, with no stand-in file. This is the end-to-end MP4 decode that the Chrome e2e could not verify.
- WER: 5.36% (9 errors in 168 words). That is under the 15% bar. Chrome measured 4.17% on the fixture WAV.
- Transcribe: 3.9 s for 56.1 s of audio, plus 1.2 s model load, in 4 windows.
- Notes: 475 prompt tokens, 14.6 s to first token, 206 tokens at 42.2 tok/s. All five headings are present in the text and on screen.
- Stop to notes on screen: 29.4 s (the first run took 30.4 s).
- Peak resident size of the app's process tree: 4,575 MB. This is sampled every 0.5 s over the whole tree, so it is not directly comparable to the Chrome figure, which counted renderer and GPU processes only.
- Network origins in the net log: `https://huggingface.co` and `https://us.aws.cdn.hf.co`. Nothing else.
- The shell denied one permission, `persistent-storage`. See the change requests below.

### Linux, `.deb` in a container

`bash tools/e2e/linux-deb.sh`. Ubuntu 24.04 arm64 under Docker on the Mac, Xvfb, the `tester` user. Log: `docs/media/desktop/linux/linux-deb.log`.

- `apt-get install ./alona_0.1.0_arm64.deb` resolved and installed the declared dependencies. `ldd /opt/Alona/alona` found every library. The `chrome-sandbox` binary is `-rwsr-xr-x root`.
- The `Exec` line of `/usr/share/applications/alona.desktop` (`/opt/Alona/alona %U`), run as `tester`, opened a window titled Alona within 60 s (checked with `xdotool search --sync --name '^Alona$'`).
- `crossOriginIsolated` was true. The adapter was SwiftShader (`google` / `swiftshader`, no `shader-f16`). The probe chose the demo engine and the screen said "This browser has no WebGPU, so Alona cannot run its models here." The run then passed through first launch, download, recording, notes, transcript, and settings.
- The app recorded the microphone (`audio.m4a`, 132,953 bytes for 8 s). The notes on screen carry the five headings, but they are the demo engine's samples.
- Network origins: none.
- The container runs with `--cap-add SYS_ADMIN --security-opt seccomp=unconfined`. Under Docker's default profile, Chromium's sandbox cannot create its namespaces ("Failed to move to new namespace"). The shipped app is not given `--no-sandbox`.

Two bugs were found and fixed on the way:

1. electron-builder's default `Depends` omits ALSA. On Ubuntu 24.04 the app would not start (`libasound.so.2: cannot open shared object file`). The package now declares `libasound2t64 | libasound2`, `libgbm1`, and `libdrm2`.
2. On Linux, Chromium fetched hunspell dictionaries from `redirector.gvt1.com` as the session started. That fetch is outside `webRequest`, so the allowlist did not stop it. The net log caught it. Every session is now configured in `session-created`: spellchecker off, no languages, download URL on `alona://app`. After the fix, the net log showed no origins on Linux and only the two Hugging Face hosts on macOS.

Real models on Linux are **NOT VERIFIED**. No GPU was available.

### Windows, static checks only

- `Alona-Setup-0.1.0-x64.exe` is a "PE32 executable (GUI) Intel 80386, for MS Windows, Nullsoft Installer self-extracting archive". `win-unpacked/Alona.exe` is PE32+ x86-64.
- The exe's version resources read `ProductName` and `FileDescription` Alona, `ProductVersion` 0.1.0.0, and `CompanyName` Alona.
- `resources/app.asar` holds `main.js` and `package.json` (name `alona`, productName Alona). It also holds the site's `index.html`, `shell.html`, `modules/index.js`, `modules/worker.js`, and `modules/ort/ort-wasm-simd-threaded.asyncify.wasm`.
- The app id `com.alona.app` is set in `electron-builder.json`. It was not read back out of the compressed installer.
- Fuses read from `Alona.exe`:
  - RunAsNode: disabled.
  - NODE_OPTIONS: disabled.
  - Cookie encryption: enabled.
  - OnlyLoadAppFromAsar: enabled.
  - File-protocol extra privileges: disabled.
  - Node CLI inspect arguments: enabled (see risks).
  - Embedded asar integrity: disabled (see risks).

Running it is **NOT VERIFIED**. To verify on a Windows 11 x64 machine with a GPU:

1. Install Git, Bun 1.4.2, Node 22 or later, and Google Chrome. Clone, check out `rewrite/desktop`, and clone Exact next to the repo as `../exact`.
2. `bun install`, then `cd tools/e2e && bun install && cd ../..`.
3. `bun tools/build-desktop.mjs win`. This builds the installer natively and checks the NSIS step there.
4. Run `desktop\out\Alona-Setup-0.1.0-x64.exe`. Accept SmartScreen's unsigned-app warning. Start Alona from the Start menu. Check that the window is titled Alona and that the device check names the GPU, not the demo device.
5. `bun tools/e2e-desktop.mjs --exe "%LOCALAPPDATA%\Programs\Alona\Alona.exe" --platform windows`. It must print `e2e-desktop: pass` with `engine: real`. If the probe picks the demo engine, `e2e.json` shows the WebGPU adapter it found.
6. Record a short meeting by hand with the real microphone, and check that Windows asks for microphone access the first time.

## Security settings

- **Origin.** `alona://app` is registered as standard, secure, fetch-capable, CORS-enabled, and streamable. It is never `file://`. The handler serves a file under the site root (paths are normalized and must stay inside it). Otherwise it serves `shell.html` with 200 for an app route, or 404 for a missing file with an extension. This is Exact's static-host rule.
- **Isolation.** Every response carries `Cross-Origin-Opener-Policy: same-origin`, `Cross-Origin-Embedder-Policy: require-corp`, and `Cross-Origin-Resource-Policy: same-origin`. Hugging Face downloads still work under COEP, because the page fetches them in CORS mode and Hugging Face sends CORS headers. Measured: 761 MB downloaded and verified on macOS.
- **Renderer.** `contextIsolation: true`, `nodeIntegration: false`, `sandbox: true`, `webviewTag: false`, `spellcheck: false`, and no preload.
- **Navigation.** `will-navigate` to another origin is cancelled, and an http or https URL opens in the system browser. Other-origin main-frame redirects are cancelled. `setWindowOpenHandler` always denies. `<webview>` attachment is refused. Checked by the e2e on both platforms: after `window.open` and an outside `location.href`, there was still one window on `alona://app/`.
- **Permissions.** The request handler grants only `media` with audio-only media types, and only to `alona://app`. The check handler answers the same way. Everything else is denied and logged. Checked on macOS: audio was granted and a video request was denied (`[alona] denied permission media ["video"]`).
- **Network.** `webRequest.onBeforeRequest` cancels every `http:`, `ws:`, `wss:`, and `ftp:` request, and every `https:` request whose host is not `huggingface.co` or under `hf.co`. The spellchecker download is off, as above. There is no telemetry, no auto-update (`publish: null`, no updater module), and no crash reporter. Evidence is the Chromium net log from each e2e run, recorded in `e2e.json` as `networkOrigins`.
- **WebGPU switches.** On Linux only, the shell appends `--enable-unsafe-webgpu` and `--enable-features=Vulkan`. Chromium ships WebGPU off on Linux, and its Linux backend is Vulkan. On Windows, Chromium enables WebGPU on D3D12 by default, so no switch is set. On macOS, Metal WebGPU is on by default. Whether these switches give a real adapter on Linux hardware is NOT VERIFIED.
- **Window.** One window at 1040 by 760, minimum 420 by 560, titled Alona, with the Alona icon. A single-instance lock focuses the existing window on a second launch. The menus are File or App, Edit, View (no developer tools), and Window.

## Open risks

- **Linux and Windows run Lite only, on the web engine.** `core/models.ts` gives Balanced and Quality no `web:` entries, so the desktop apps offer Lite: Moonshine Base and Qwen3.5 0.8B, with draft-quality notes.
- **WebGPU on real Linux drivers.** The page module needs a non-software adapter with `shader-f16`. Many Linux systems lack working Vulkan, or Chromium blocklists their GPU. On those, the app shows the demo engine and its reason. It does not fail, but it cannot make real notes. Not measured on any Linux GPU.
- **Signing.** The Windows installer and exe are unsigned, so SmartScreen will warn. The `.deb` is unsigned and there is no apt repository. Updates are manual: there is no auto-update by design.
- **Fuses.** Node's inspect arguments stay enabled, because Playwright's Electron driver attaches through `--inspect`. A local user could attach a debugger to the main process. Disable that fuse for release builds once the e2e attaches over CDP instead. Embedded asar integrity is off, because it could not be tested on Windows here.
- **Memory.** The macOS run peaked at about 4.6 GB for the whole process tree with the 0.8B model. An 8 GB Windows or Linux machine was not tried.
- **Linux x64 and Windows were never launched.** Their checks above are static.
- **The container run used extra capabilities** for the sandbox. A real desktop does not need them, but the `.deb` was not run on a real desktop session (GNOME or KDE, Wayland).

## Change requests (the app and the engine were not modified)

- **Grant `persistent-storage` or not.** The page module calls `navigator.storage.persist()` after the first download, and the shell denies it because the brief allows only the microphone. Chromium can evict best-effort storage under disk pressure, which would drop downloaded models and, worse, meetings. Granting `persistent-storage` to `alona://app` in `desktop/main.js` is a one-line change. It is a policy call for the coordinator.
- **The device line says "Chrome on macOS" or "Chrome on Linux" inside the shell.** `platform()` in `modules/web/index.js` reads the user agent, which contains `Electron/45.2.1` and `Alona/0.1.0`. A check for `/Electron\//` before the Chrome check, naming it "Alona", would make Settings read "Alona on Linux".
