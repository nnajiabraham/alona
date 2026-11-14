# Spike S3: Exact on Android

Goal restated: Alona is one app (web, macOS, iOS, Android) built on Exact. It records a meeting, transcribes it with a small local speech model, and a small local LLM writes the notes. Nothing leaves the device. This spike asks whether an Exact app builds, runs and can be driven on an Android emulator here, and how app-owned native code for local inference would be reached on Android.

Run on 2026-11-14, Exact checkout `/Users/manlikeabro/Documents/repos/exact` at `3baa28ff` (its working tree had 11 uncommitted files, all under `host/apple/`, edited by the concurrent macOS spike; none touch Android). Emulator: AVD `Pixel_9`, API 35, `arm64-v8a`, 4 cores, 2 GB RAM (`MemTotal: 2022068 kB`), started headless with `-no-window -no-audio -gpu swiftshader_indirect`. Screenshot: [android-host.png](android-host.png) (the spike app as `agent android` draws it).

## Verdicts

| Step | Verdict | Evidence |
|---|---|---|
| 1a. Build, install, `test android`, screenshot | VERIFIED | `built in 399.4 s, installed on emulator-5554 ... in 3.5 s`; `2 passed, 0 failed`; screenshot written (43 KB, read back, shows the placeholder) |
| 1b. `adb shell screenrecord` | VERIFIED | `/sdcard/spike.mp4` pulled, `ISO Media, MP4 v2`, 147 822 bytes for 5 s; the 14 s recorder flow is 512 621 bytes |
| 2. Is there a `native.later` answerer on Android | VERIFIED (Rust only), with a serious conflict | Echo prototype round trip driven by the agent. The Rust seam and the Kotlin seam are different mechanisms. See below |
| 3. Third-party native libraries | PARTLY VERIFIED | Maven AAR with an arm64 `.so` loaded from a Kotlin extension on device: verified. Rust crates and CMake builds inside the Android crate: NOT VERIFIED (read from build scripts only). Package prebuilt `library` on Android: refused by Exact |
| 4a. Microphone through `@exact/media-capture` and `@exact/recording` | VERIFIED on the emulator | M4A and WAV takes recorded by real taps on the installed APK, headers read back |
| 4b. RAM and SoC facts | VERIFIED on Android (two ways), NOT VERIFIED on the other hosts | `@exact/device` exposes neither. See table below |

## Timings

All on a machine with load average above 100 (the macOS spike was building at the same time), so read them as upper bounds.

| Action | Time |
|---|---|
| First Android build (Rust cdylib for `aarch64-linux-android` plus Gradle) | 399.4 s reported (6m44s wall). Gradle part: 1m28s |
| `test android` first run (2 tests) | 11.1 s total; later runs 4.1 s |
| `agent android "screenshot ..."` | 5.4 s |
| Incremental rebuild, one Contract or Kotlin edit | 15 to 52 s |
| Adding the mic packages with `--write-locks` (downloads Maven graph) | 97.3 s |
| Adding `org.tensorflow:tensorflow-lite:2.16.1` with `--write-locks` | 85.3 s |
| APK size (release, one ABI) | 35.9 MB; `libexactcanvas.so` is 30.7 MB of it (`unzip -l`) |

## How native code is reached on Android

There are four seams. Only the last two worked for the mic and for new native code in one app, as tested.

**1. Rust `NativeModule` shim (`native.call`, `native.later`).** This is the Android twin of the Swift `ExactModule` and `modules/web/index.js`. A package whose `exact.json` has `"native": {"rust": "native/lib.rs", "class": "Echo"}` is `#[path]`-included into the app's Android crate and attached with `.with_native(exact_native)`.
- Trait: `exact_js::NativeModule` with `call` (sync, 100 ms budget) and `later() -> Option<LaterHandler>` for long work such as "a transcription, a model's answer" (`js/src/native.rs:47`, `:63`, doc comment on `later`).
- Bake joins the shim and writes the factory: `js/bake/src/lib.rs:249`.
- The generated Android crate attaches it: `scripts/app-shells.mjs:152` (the `module(false)` template the Android crate at `:229` uses).
- Docs: `docs/contract-for-agents.md:3062` ("A package's native module, library and web assets"). The shim "names only `exact_js` and `std`".
- I made a local package `@alona/echo-native` (`file:` dependency), a Rust shim that answers `native.later({op:"echo"})` from a thread of its own after 300 ms, and `native.call({op:"facts"})`. The agent drove it on the device: reply text `native heard "ping" for com.example.alona-android-spike-ad5bb3 on thread ThreadId(12) (android)`, and `facts` returned `os=android arch=aarch64 cores=4 memTotalKb=2022068 socModel=ranchu socManufacturer=AOSP model=sdk_gphone64_arm64`. `test android` passed 3 of 3 with it. Variant files are in `variants/shim/`.
- **Conflict (measured, cause not proven):** with this shim in `package.json`, `native.later` works but every `@exact/*` Kotlin package fails on the device with `NotSupportedError` (`recording.mediaRecorderState`, `media-capture.microphoneStatus`, `device.powerState`, and my own Kotlin package `kt-echo`). Removing the shim, with nothing else changed, made the microphone work. Both directions were run on the production APK; logcat lines are in "Open risks". My reading of the source is that both use the runner's one native slot (`host/painted/src/presenter/requests.rs:471` `handle_modules` installs "the native slot's one handler" for Kotlin extensions), and the docs say the slot is one per app (`bake-native-twice`, `docs/contract-for-agents.md:3090`). I did not confirm that by reading the runner side.

**2. Kotlin extension package (a module implementation).** This is how `@exact/recording`, `@exact/device` and `@exact/media-capture` work. Not `native.later`: the app's Contract names sources and sends from the package (`use ktEcho from "@alona/kt-echo"`), and Kotlin answers them.
- Roster written by the build: `scripts/agent-android.mjs:1129` (`extensionArgs`), loaded by name in `host/android/canvas/.../Extensions.kt:445`, extension made at `:622`.
- Contract of the class: `ExactExtension.later(name, args, reply)`, replies on the main thread, errors as `{"error": code}` (`Extensions.kt:13`, README `host/android/README.md:677` "Module implementations").
- I wrote `@alona/kt-echo` (an `interface` `exact.json`, an `android/exact.json` implementation, one Kotlin file, modelled on `packages/recording`). It answered `ktEcho` (reply after 300 ms from a worker thread) and `deviceFacts` on the production APK by real tap: `kotlin heard "hello native" ...` and `ram=2070597632 soc=AOSP ranchu abis=arm64-v8a cores=4`. It ran in the same APK as media-capture, recording and device with no conflict, and the mic still recorded afterwards.
- Under the agent an extension must be bound with `--bind kt-echo` or it is told it runs under the agent and answers `NotSupportedError`. `test android` has no bind flag I could find, so extension flows are driven with `agent android --bind`.

**3. Kotlin hatches and module views** (`modules/android/Hatches.kt`, `exact.app.Modules`). UI-side only (a view in a node's box, picker tweaks, input observers): `host/android/README.md:650`. Not a data seam. Not used.

**4. Rust data crate** (`exact new --rust`, `docs/reference.md:4106` "Rust data sources"; the Android crate is a plain Cargo `cdylib`, `apps/native-fixture/android/Cargo.toml`). The app's own `data/` crate then holds any Rust dependency. Not built in this spike (it needs the copied-up workspace and a full recompile). NOT VERIFIED.

## How native libraries can be linked

Evidence for each route:

| Route | Status | Evidence |
|---|---|---|
| Maven AAR through `app.json` `host.android.maven` | VERIFIED | Added `org.tensorflow:tensorflow-lite:2.16.1`; the APK then holds `lib/arm64-v8a/libtensorflowlite_jni.so` (3 401 664 bytes) and `System.loadLibrary("tensorflowlite_jni")` from `kt-echo` on the device returned loaded (screenshot text: `kotlin heard "hello native | libtensorflowlite_jni.so loaded"`). Coordinates are pinned, locked in `gradle.lockfile` and checked against `gradle-verification.xml` (`host/android/README.md:724`, `host/android/app/build.gradle.kts:255`). Repositories are Google and Maven Central only (`host/android/settings.gradle.kts:7`) |
| Rust crates (whisper-rs, llama-cpp-2, sherpa-rs) in the app's Cargo workspace for `aarch64-linux-android` | NOT VERIFIED | Build script evidence only. The app's Rust is built into the single `libexactcanvas.so` (`scripts/agent-android.mjs:1007`) and the target is fixed at `aarch64-linux-android` (`:53`). The toolchain env sets `CC`, `CXX`, `AR`, the linker, `ANDROID_NDK_HOME` and `c++_static` (`:130` to `:139`), which is what `cc` builds need; a `cmake` build (llama.cpp, whisper.cpp) was not tried, so toolchain-file handling is unknown. The 16 KB page alignment is enforced and fails the build if a rustflags table drops it (`:996` to `:1000`) |
| Package prebuilt `library` (`native.library` in `exact.json`) | REFUSED by Exact | `js/bake/src/library.rs:68` and `scripts/package-libraries.mjs:107`: "Android's APK carries none yet (LLP 1154 D6)" |
| Loose `.so` into `jniLibs` | NOT AVAILABLE to an app | Gradle's `jniLibs` is the build's staged dir with Exact's own libraries only (`host/android/app/build.gradle.kts:89`; `scripts/agent-android.mjs:1005` to `:1009`). An AAR's own `.so` files are packaged by Gradle (that is how the TFLite one arrived) |
| ABI | `arm64-v8a` only | `host/android/app/build.gradle.kts:58`. An Intel emulator cannot run this |

Public lookups (not tested by me, no project data sent): `com.k2fsa.sherpa.onnx:sherpa-onnx-android` has a Maven Central page, so it may fit the AAR route, but I did not resolve it or check its version, size or ABI content. llama.cpp publishes no official AAR; several third-party AARs exist on Central (for example `dev.ffmpegkit-maintained:llama-android`, `com.arm:ai-chat`), with unknown maintenance and no checks by me. The model files (hundreds of MB) are not in any of these.

Exact also ships Android implementations of two system services, not our own models: `@exact/speech-recognition` (Android `SpeechRecognizer`; `processLocally=true` uses the on-device recognizer where available; file and track input are `NotSupportedError` today per the header of `packages/speech-recognition/android/SpeechRecognition.kt`) and `@exact/language-model` (ML Kit GenAI Prompt API over AICore Gemini Nano, `packages/language-model/android/LanguageModel.kt`). Neither was run here.

## Microphone

Flow built from `apps/recorder`, trimmed: `getUserMedia(audio=true)`, `startMediaRecorder(stream, path, mimeType)`, `stopMediaRecorder`. Grants: `device.microphone purpose.microphone`, `fs.read` and `fs.write app:/data/takes`; a `strings/en.json` purpose key. Packages added with `bun exact.mjs add @exact/media-capture`, `@exact/recording`, `@exact/device`.

- Drove it with `adb shell input tap` on the production APK after `adb shell pm grant ... RECORD_AUDIO`. The app showed the green mic indicator while recording.
- M4A (default): `app:/data/takes/take-1.m4a | audio/mp4 | 62171 bytes | 5018 ms`. File header read back by the app through `storage.fs.readFile`: `....ftypmp42`. That is about 99 kbit/s, matching the module's 96 kbit/s AAC-LC default (`packages/recording/android/Recording.kt:360`).
- WAV (`mimeType="audio/wav"`): `app:/data/takes/take-2.wav | audio/wav | 436634 bytes | 5027 ms`, header `RIFF....WAVE`. About 86.9 kB/s, which is close to 44.1 kHz mono 16-bit (inferred from size and duration; I did not parse the header). Speech models want 16 kHz, so resampling is needed whichever file we keep.
- Where it lands: the logical path is `app:/data/takes/` and it resolves under the app's private storage (`Native.appRoot`, `Extensions.kt:171`). The emulator image is a production build (`adb root` refused), so I could not pull the file or give the absolute path. Audio content was NOT checked (`-no-audio` emulator); the sizes show bytes were written, not that speech was captured.
- Live PCM exists for a Kotlin extension: `AudioSource.tap { ShortArray, count }` hands 16-bit PCM blocks on the capture thread (`host/android/canvas/.../Tracks.kt:93`). That is the hook for streaming STT. Not exercised.
- Running a bound mic under the agent: unbound, the agent uses a substitute (the first `agent` run showed permission tickets and WAV only, per `Recording.kt:103`). Real mic is only exercised on the installed app or with `--bind`.
- Traps hit: `microphoneStatus` showed `state=prompt` while the OS permission was granted when the answer was a kept or substituted one; an extension error `{"error": code}` surfaces in the Contract as a failure with code `shape` (field missing), not the real code, so surface `failure(x).message` and read logcat tag `exact`.

## Device facts: what each host exposes

`@exact/device` (`packages/device/exact.json`) has three sources only: `getBattery`, `connection`, `powerState` (thermal state). A grep over `packages/*/exact.json`, `android/` and `apple/` for total memory, `physicalMemory`, `deviceMemory`, `hardwareConcurrency`, `SOC_MODEL` and `MemoryInfo` found no RAM or SoC source in any Exact package.

| Host | RAM | SoC or chip | Status |
|---|---|---|---|
| Android, Kotlin extension | `ActivityManager.MemoryInfo.totalMem` returned `2070597632` | `Build.SOC_MODEL` and `SOC_MANUFACTURER` (API 31+) returned `ranchu` and `AOSP` (emulator values) | VERIFIED (screenshot) |
| Android, Rust shim | `/proc/meminfo` `MemTotal` = `2022068 kB` | `getprop ro.soc.model` = `ranchu` | VERIFIED, but see the shim conflict |
| iOS, macOS | Swift `ExactModule` could call `ProcessInfo.physicalMemory` | `sysctl` or `uname` | NOT VERIFIED here (no Apple run in this spike) |
| Web | `modules/web/index.js` runs in the page: `navigator.deviceMemory` (Chromium only, coarse, capped) and `navigator.hardwareConcurrency` | none | NOT VERIFIED here; general browser behaviour |

The emulator reports an emulated SoC, so real SoC naming on phones is untested. A capability gate (which model size to offer) probably needs total RAM and an approximate class, not the SoC string.

## Commands

Environment for every command:

```sh
export PATH=~/.bun-1.4.2/bin:$PATH
export ANDROID_HOME=~/Library/Android/sdk JAVA_HOME=~/.sdkman/candidates/java/current ANDROID_SERIAL=emulator-5554
cd <spike>/alona-android-spike
```

```sh
# check what Android needs
bun /Users/manlikeabro/Documents/repos/exact/scripts/exact.mjs setup --check --platform android
# boot the emulator headless (does not touch the AVD)
$ANDROID_HOME/emulator/emulator -avd Pixel_9 -no-window -no-audio -no-snapshot-save -no-boot-anim -gpu swiftshader_indirect &
until [ "$($ANDROID_HOME/platform-tools/adb shell getprop sys.boot_completed | tr -d '\r')" = 1 ]; do sleep 5; done
# build and install (first time 400 s; add --write-locks when Maven coordinates change)
bun exact.mjs android
bun exact.mjs android --write-locks
# tests and drive
bun exact.mjs test android
bun exact.mjs agent android --reset-storage "clock settle" tree "tap ping" "clock settle" "state echoed"
bun exact.mjs agent android --bind kt-echo --bind device "type draft ping" "tap kt-ping" "clock settle" "clock +1000" "clock settle" "state ktEchoed"
# screenshot, two ways
bun exact.mjs agent android "screenshot .exact/shot.png"
$ANDROID_HOME/platform-tools/adb exec-out screencap -p > shot.png
# screen video (max 180 s per file)
adb shell screenrecord --time-limit 14 /sdcard/flow.mp4 & ; adb shell input tap X Y ; wait; adb pull /sdcard/flow.mp4
# real mic on the installed app
adb shell pm grant com.example.alona_android_spike_ad5bb3 android.permission.RECORD_AUDIO
adb shell am start -n com.example.alona_android_spike_ad5bb3/dev.exact.app.MainActivity
adb logcat -d | grep -E ' exact *: '
```

Switching the shim on: `cp variants/shim/package.json package.json && bun install && bun exact.mjs android`.

## Open risks

1. **The native slot conflict is the biggest.** One app cannot, as tested, have both a Rust `native.later` shim and the Kotlin `@exact/*` packages. Logcat with the shim present: `resource rec failed: recording.mediaRecorderState: NotSupportedError`, `resource dev failed: kt-echo.deviceFacts: NotSupportedError`, `request 3 (mic) failed ... microphoneStatus: field 'available' is missing`. Without it: `media-capture: stream-1-1 opened`, `recording: recorder-1-1 recording ... take-1.m4a`. One A/B on one emulator, with a debug copy of `media-capture` (one extra log line) in the dependency list for the earlier runs. The root cause is read from source, not proven, and Exact's authors should confirm whether this is a bug or a rule.
2. **Android's route to our own native code is a Kotlin extension, which means a Kotlin or JNI bridge in front of the C++ or Rust inference code.** The Rust-in-process route (data crate or shim) is unproven for heavy C++ dependencies. Neither was run with a real inference library.
3. **No prebuilt-library support on Android** (`library.rs:68`), `arm64-v8a` only, and the Android host is early (admitted 2026-10-07).
4. **Kept and substituted answers can lie.** A resource that reads `native.call` is kept across launches (`docs/recipes/native-module.md`), and I saw the facts line persist after I removed the shim. Same for `mic state=prompt` while granted. Production code must not trust them without a fresh read.
5. **Emulator limits.** 2 GB RAM, emulated SoC, no mic audio checked, headless GPU `swiftshader_indirect`. Nothing here measures inference speed, thermals, memory pressure or background recording (a foreground service claim is needed; `Recording.kt` and `media-capture` mention it, untested).
6. **Heavy build.** 5.2 GB `target/` for one app; the first build took 400 s under load. `exact.mjs` needs the Exact checkout on this path.
7. **App-id and test fragility.** My shim test asserted the thread id; I dropped it from the final tests. `test android` cannot bind extensions, so Kotlin-backed flows have no regression test in the standard harness.
8. **Kotlin extension replies hit the Contract as `shape` failures** when they return an error object; error codes are invisible unless logged.
9. **`clock settle` gives up after 20 s on a native request still in flight**; use `clock +N` then `clock settle`.

## Spike code

`/private/tmp/claude-501/-Users-manlikeabro-Documents-repos-alona/6b40fa8d-2378-4789-9c09-a3bb732155a9/scratchpad/spikes/android/`

- `alona-android-spike/` the app: `app.contract`, `app.ts`, `app.test.contract`, `strings/en.json`, `kt-echo/` (Kotlin extension), `echo-native/` (Rust shim, not in the final `package.json`), `variants/shim/` (package.json and tests with the shim), `gradle.lockfile`, `gradle-verification.xml`.
- `media-capture-debug/` a copy of `packages/media-capture` with two log lines, used once to find the conflict; the final app depends on the real package.
- `spike.mp4` (5 s, step 1), `recorder-flow.mp4` (14 s, mic flow), `baseline.png`, `echo.png`, `tflite.png`, `final.png`, `coexist-shim.png`, `logs/` (build and test logs).
- Nothing in the Exact checkout was edited; no git state was changed anywhere; no AVD was changed. The only network traffic was Maven downloads for the lock files and two public web searches.
