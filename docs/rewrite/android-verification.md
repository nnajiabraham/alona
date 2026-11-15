# Alona on Android: verification report

Goal restated: Alona is one private, local-only meeting assistant for web, macOS, iOS and Android on Exact. This report checks the Android host, screens and flows on an emulator. On Android the app has no inference module, so it runs its demo engine (sample transcript and notes) and says so on screen. Model quality is out of scope.

Run on 2026-11-14. Emulator: AVD `Pixel_9` (API 35, arm64, 1080x2424, 420 dpi), already running headless as `emulator-5554`; no AVD was changed. Exact checkout `/Users/manlikeabro/Documents/repos/exact`, untouched.

## What was built, and why from a snapshot

The first build ran in the repo itself (`bun exact.mjs android`, then `--write-locks`; both succeeded, see timings). Every later `test`, `verify` and `agent` call on that APK was then refused as stale:

```
android build is stale: .../core/artifacts.json, .../core/models.ts, .../modules/apple/onnxruntime.xcframework/macos-arm64_x86_64/onnxruntime.framework/Headers/Headers and 11 more changed since .../app-release.apk was built
```

Two causes, both outside this task:
- The web-engine agent edits `core/` (inputs of the Android build) while I ran.
- `modules/apple/onnxruntime.xcframework` holds three dangling symlinks (`Versions/A/A -> A`, `Versions/A/Headers/Headers`, `Versions/A/Resources/Resources`, plus `Headers`/`Resources` links dated 10:45). Exact's freshness scan treats them as changed forever. The directory is git-ignored (`/modules/apple/*.xcframework`) and is not mine to edit. It will also stale-block any other host's drive until someone repairs it.

So I built and drove from a snapshot: `git archive HEAD` (commit `e915608`) extracted to `<scratchpad>/snap/alona`, with `<scratchpad>/snap/exact` symlinked to the Exact checkout so `file:../exact/...` resolves, and the `gradle.lockfile` and `gradle-verification.xml` from the repo copied in. All results below are from that snapshot unless stated. The snapshot has no uncommitted work from the other agent. Media was copied into this repo afterwards.

I changed one line of `app.ts` in the snapshot only, after the unmodified results were recorded. The change is the suggested fix for defect D1. Its diff is `(evidence removed after the fixes were re-verified; see git history)`:

```
-  if (probe.demo === true) return demo();
+  if (probe.demo === true || typeof probe.host !== 'string') return demo();
```

Results are labelled **HEAD** (unmodified) or **PATCHED** (with that line). Nothing in the repo's `app.ts` was touched.

## Verdicts

| Step | Verdict | Evidence |
|---|---|---|
| 1. Build and install | VERIFIED | `built in 294.7 s, installed on emulator-5554 as com.alona.app in 0.3 s` (snapshot, cold target). In-repo: Rust compiled in 2m52s, then `--write-locks`: `built in 97.7 s, installed ... in 0.3 s`. Lock files are at the repo root (new, untracked) |
| 2a. `test android` on HEAD | NOT VERIFIED (fails) | `1 passed, 2 failed`; see D1 |
| 2a'. `test android` PATCHED | VERIFIED | `3 passed, 0 failed` |
| 2b. `verify android` on HEAD | NOT VERIFIED (fails) | `verify: 17 problems (2 failed tests, 15 findings ...)`, exit 1 |
| 2b'. `verify android` PATCHED | VERIFIED with 3 findings | exit 0, `tests: 3 passed, 0 failed`, 3 findings (all `rec`, below) |
| 3. `bun tools/flows.mjs android` on HEAD | NOT VERIFIED | 1 of 5 passed (library) |
| 3'. Flows PATCHED | PARTLY VERIFIED | first full run 3 of 5 (record failed a check, library crashed the drive); library alone then passed. 4 of 5 pass overall; record fails one check on every run (D2) |
| 4. Real-time videos by real taps | VERIFIED | Real `adb shell input tap` drove first launch through download to ready, and Settings through picking Lite and downloading it. Run on the PATCHED APK (HEAD's app cannot download, D1) |
| 5. Visual review of every screenshot | VERIFIED as a review; defects listed below | Not all frames opened: I opened one per screen state (list below); the remaining flow frames repeat those states |

## Timings

| Action | Time |
|---|---|
| `exact.mjs android`, in repo, first run | 2m53s wall, 888 s CPU; stopped at the Gradle lock step |
| `exact.mjs android --write-locks` | 1m38s wall; reported `built in 97.7 s` |
| `exact.mjs android`, snapshot, cold `target/` | 4m56s wall; reported `built in 294.7 s` |
| incremental rebuild after the one-line patch | 28 s wall |
| `test android` | 26.8 s first run; about 20 s later |
| `verify android` | 18.7 s (HEAD), 18.9 s (PATCHED) |
| `flows android`, all 5, HEAD | 11m07s wall (agent calls wait out the 20 s settle bound) |
| `flows android`, all 5, PATCHED | 4m14s wall |

Machine load was low at the start (load average about 3).

## Test and verify findings

### HEAD

`test android`, tail:

```
test "first launch checks the device and recommends a tier": ok
test "continue downloads the models, then the home screen is ready to record": FAIL
  line 12: expected testId "download-card" present, it was absent (resource setup failed: The engine's probe reply names no known host: ...)
  line 16: expected testId "models-needed" absent, it was present
test "not now skips the download, and the home screen says models are needed": FAIL
  line 30: expected testId "models-needed" absent, it was present
1 passed, 2 failed
```

`verify android` full finding list: `(evidence removed after the fixes were re-verified; see git history)`, log `verify.log`. Summary:
- 7 refused at run time: `setup` and `downloading` replies, `HTTP 200, 29 bytes`, `Unavailable("The engine's probe reply names no known host: ")` (first screen, each test, relaunch).
- 6 "failed and not arranged": `setup` refused (3 tests) and `rec` refused once per test.
- 1 failed resource: `setup`. 1 other (relaunch problem, same cause).
- 1 compiler note, not counted: `app.tamber:6:3 warning [tamber-unreachable] accent-color on iOS, macOS and the web ...` (see D4).
- "not on Android yet": check's findings, the accessibility tree read, the largest text size, the scrolling probe, a test end's reload. So Android verify does not judge layout; the screenshots are captured unjudged.

### PATCHED

`verify: 3 problems (3 findings; the tests passed)`, exit 0. All three are `"<test>": resource rec was refused once`. The agent log shows why: `resource rec failed: recording.mediaRecorderState: NotSupportedError`. This is the test host standing in for the recorder (the spike's "unbound extension is substituted" behaviour). It is not an app wiring error, but `verify` counts it as a finding on every test. Also: `relaunch ... the first screen shows what it stored`. Full text: `verify-patched.log`, `verify-patched-findings.txt`.

## Flow results

HEAD (log `unpatched-head/flows-unpatched.log`, media `unpatched-head/<flow>/`): 1 of 5.

| Flow | HEAD | PATCHED |
|---|---|---|
| onboarding | FAIL: `setup.activeDownloading` expected true, got false; `setup.activeInstalled` expected true, got false | ok, 5 checks, 3 screenshots |
| record | FAIL: `recorderId` expected `"recorder-1"`, got `"recorder-1-1"`; `lib.0.status` stuck at `recorded` (3 checks) | FAIL one check: `recorderId` expected `"recorder-1"`, got `"recorder-1-1"`. The other 6 checks pass, status reaches `done`; 6 screenshots, video made |
| review | FAIL: drive crashed (`agent.mjs:527`), status stuck at `recorded` | ok, 7 checks, 5 screenshots |
| library | ok, 2 checks, 4 screenshots | run 1: drive crashed after `tap start-recording` + `clock settle` (`agent.mjs:443`, no replies; `library-run1-crashed/drive.log`). Rerun alone: ok, 4 screenshots |
| settings | FAIL: drive crashed (`agent.mjs:527`); `setup.active` expected lite, got balanced | ok, 8 checks, 5 screenshots |

The drive crashes (HEAD: review, settings; PATCHED run 1: library) are intermittent. I did not capture their stderr beyond the last stack lines, so cause is NOT established. Whether another process touched the emulator is unknown; I saw no other `exact.mjs` or `adb` process, but I did not watch for one throughout.

`tools/flows.mjs` was not changed. The existing `android` entry (no flags) works: the agent substitutes the recorder and the `--permission microphone=granted` flag is accepted.

PATCHED media is at `docs/media/android/<flow>/` (screenshots, `drive.log`, stepped `<flow>.mp4`). HEAD media is at `(evidence removed after the fixes were re-verified; see git history)`. `(evidence removed after the fixes were re-verified; see git history)` holds four extra screenshots I took with settled transitions (list, list dark, settings dark, window bars). Frame videos are one frame per step, not real-time.

## Real-time videos (step 4)

On the PATCHED APK, installed app, real taps, `adb shell screenrecord`, 1080x2424:
- `docs/media/android/real-time/onboarding.mp4` (25 s). Fresh `pm clear`, mic granted. Tap on "Download models and continue" at (540, 2132). Home showed "Downloading Balanced models · 67%" (`onboarding-02-after-tap.png`) and then the ready home. End state: `onboarding-end.png`.
- `docs/media/android/real-time/settings.mp4` (20 s). Tap gear (1004, 224), tap Lite row (484, 992), tap its Download (976, 1184). End state `settings-end.png` shows the tick on Lite and "Lite is on this device" with Remove. Also `settings-01-opened.png`, `settings-02-lite-picked.png`.

Coordinates came from my own screenshots (the app draws one canvas; I did not use uiautomator). The first take of the settings video was cut short by the 20 s limit before I tapped, so I re-recorded; only the second take is kept.

## Defects found

### Functional

**D1. On Android the app's probe fails, so setup never loads and no download can start (HEAD).** Severity: blocks onboarding on a real device.
- Evidence: `test android` and `verify android` above; agent log `request 4 (setup) failed ... The engine's probe reply names no known host:`; `fulfil ... HTTP 200, 29 bytes`. 29 bytes is the length of `{"error":"NotSupportedError"}`; I read this off the size, I did not capture the body. Logcat: `extension call 6: org.json.JSONException: No value for extension`.
- Cause (inferred from `app.ts` and logs): `native?.available` is true on Android because `@exact/recording` and `@exact/media-capture` are Kotlin extensions, but there is no inference module, so `native.later({op:'probe'})` returns an error object. `build()` in `app.ts` only falls back to the demo engine when `probe.demo === true`, then `parseDeviceFacts` throws.
- Trap: `state setup.demo` printed `true` and the launch screenshot showed "Demo device · 8 GB memory" on HEAD. Those values are the build-time placeholder (`resource setup ... else empty()`), shown because the real answer is refused. Do not read them as the app working.
- Suggested change (verified on the snapshot): in `app.ts` `build()`, use the demo engine when the probe reply has no `host`: `if (probe.demo === true || typeof probe.host !== 'string') return demo();`. With it: `test android` 3 of 3, `verify android` exit 0, flows as above. A `try/catch` around the probe would also cover a thrown reply. Related risk: `current ??= build(...)` caches a rejected promise forever.

**D2. The record flow's `recorderId` check is web-specific.** The Android recorder id is `recorder-1-1`; the flow expects `recorder-1`. Everything after it in the flow passes. I was told not to edit the steps or checks, so this stays a failing check. Suggested: compare with a prefix or a regex per target.

**D3. The library flow's "meetings" screenshots do not show the meetings list.** `library/01-meetings.png` and `02-meetings-dark.png` show the Meeting detail screen. The flow does `back`, `clock data`, then screenshots; on Android the pop transition has not finished, and `clock data` does not settle transitions (`clock settle` does). The `lib.length` check passes because it reads state, not pixels. The list with the same steps plus `clock settle` is fine: `extra/library-list-light.png`, `extra/library-list-dark.png`. The same applies to the `back` before `needs-models-again` in the settings flow; I did not inspect that frame.

### Visual (screenshots opened: yes, listed per defect)

**D4. Brand accent is not applied on Android. Filled buttons and progress bars are navy, not moss green.** `app.tamber` sets `AccentColor = light-dark(#4d6b57, #5f8a6e)`. Seen: "Record a meeting", "Stop and write notes" and "Download models and continue" are navy (about `#2a3f6e`); the download progress bar is navy; in dark mode the button is pale periwinkle with dark text. Files: `real-time/onboarding-02-after-tap.png`, `record/02-notes-while-recording.png`, `extra/library-list-dark.png`. The selected "AI notes" pill is grey-blue (`review/01-ai-notes.png`). The compile note about `accent-color` being unreachable on iOS, macOS and web is consistent with the accent only mattering on Android, so this looks like Android honouring something other than the token. Cause not confirmed.

**D5. Header bar and status area use a lavender-white (`#f9f9ff`-ish), not `surface.page` `#f4f3ee`.** Visible as a band above the page in `real-time/onboarding-02-after-tap.png`, `extra/library-list-light.png`, `review/01-ai-notes.png`. Settings and the record sheet sit on a blue-grey (`#f2f1f8`-ish) instead of `surface.page`, so settings looks off-brand next to the home screen (`real-time/settings-end.png`, `record/02-notes-while-recording.png`). Light mode only; dark mode header is dark (`extra/library-list-dark.png`).

**D6. "My notes" tab label wraps and is clipped.** In the three-way control on the Meeting screen the middle label breaks to "My / notes" and the second line is cut off. The control is also only about 83% of the screen width, with an empty gap on the right. Files: `review/01-ai-notes.png`, `library/03-confirm-delete.png`. Cause: three `flex=1` radio buttons in a row without room for the label at this width; I did not test other widths.

**D7. Empty gap between the meeting title and the tabs.** About 190 px of blank space where the `audio` player sits (`detail.audio != ""`). No player is drawn, or it draws blank. Files: `review/01-ai-notes.png`. Whether the Android host has an audio-element view at all is not established.

**D8. Settings shows web copy on Android.** The Quality tier reads "Too large for a browser. The desktop app can run it." on an Android phone. Files: `real-time/settings-01-opened.png`, `extra/settings-dark.png`. The text comes from the tier reason in `core`; the demo engine reports `web`-style limits. Wrong for a phone, though the demo engine's facts are fake anyway.

**D9. The Privacy card's text touches the card edges.** The paragraph in the last settings row runs to the rounded corners, with no vertical padding, in light and dark. Files: `real-time/settings-end.png`, `extra/settings-dark.png`. Other rows have padding.

**D10. The note field is not scrolled above the keyboard.** While typing in "Your notes" the on-screen keyboard (shown in the screenshot because the emulator IME is on) covers most of the field; only the first line is visible, and the field's focus outline is drawn across the keyboard's top rows. File: `record/02-notes-while-recording.png`. The title and stop button stay visible. The agent keeps the keyboard up after `type`, so this may be a harness artifact; I did not test it with real taps and the IME.

**D11. Meeting detail in dark mode, library flow:** `library/02-meetings-dark.png` shows a white header, near-invisible title text and unreadable tab labels. This frame was taken while the back transition and the colour-scheme switch were still in flight (D3), and the settled dark list and settings are fine (`extra/`). I did not capture a settled dark Meeting detail, so this is INCONCLUSIVE; please check it before trusting dark mode on that screen.

Not defects, noted: system bars are the standard Android 15 status bar and gesture bar, drawn over the app with correct light/dark icon colours; the bottom gesture area in `settings-end.png` is a lighter strip than the grey page. Icons (gear, back arrow, trash, microphone, tick, waveform, lock, download, adjust) all drew. Bullet lists in the notes are indented more than the body text. In HEAD screenshots with the failed setup, the "Download" action never appears.

## Repeat everything

```sh
export PATH=~/.bun-1.4.2/bin:$PATH ANDROID_HOME=~/Library/Android/sdk JAVA_HOME=~/.sdkman/candidates/java/current ANDROID_SERIAL=emulator-5554
# emulator (already running here)
$ANDROID_HOME/emulator/emulator -avd Pixel_9 -no-window -no-audio -no-snapshot-save -no-boot-anim -gpu swiftshader_indirect &
until [ "$($ANDROID_HOME/platform-tools/adb shell getprop sys.boot_completed | tr -d '\r')" = 1 ]; do sleep 5; done
# a snapshot that does not go stale while others edit core/
S=<scratch>; mkdir -p $S/snap/alona && git -C <repo> archive HEAD | tar -x -C $S/snap/alona
ln -sfn /Users/manlikeabro/Documents/repos/exact $S/snap/exact
cp <repo>/gradle.lockfile <repo>/gradle-verification.xml $S/snap/alona/
cd $S/snap/alona && bun install
bun exact.mjs android --write-locks      # first time, Maven coordinates
bun exact.mjs android
bun exact.mjs test android
bun exact.mjs verify android --shots shots
bun tools/flows.mjs android              # or: bun tools/flows.mjs android library
# PATCHED variant: apply (evidence removed after the fixes were re-verified; see git history) to app.ts, then rebuild and rerun the three lines above
# real-time videos (app installed, 1080x2424)
adb shell pm clear com.alona.app; adb shell pm grant com.alona.app android.permission.RECORD_AUDIO
adb shell screenrecord --time-limit 25 /sdcard/onb.mp4 &
adb shell am start -n com.alona.app/dev.exact.app.MainActivity
adb shell input tap 540 2132        # Download models and continue
adb exec-out screencap -p > end.png; adb pull /sdcard/onb.mp4
# settings: tap gear 1004 224, Lite row 484 992, Lite Download 976 1184
```

In the repo itself, `bun exact.mjs test android` currently refuses (stale build) because of the dangling symlinks and `core/` edits above. Repair the three links under `modules/apple/onnxruntime.xcframework/macos-arm64_x86_64/onnxruntime.framework/Versions/A/`, then rebuild.

## Files

- Media and logs: `docs/media/android/` (`<flow>/`, `unpatched-head/`, `real-time/`, `extra/`, `verify-shots-patched/`, `library-run1-crashed/`, `build*.log`, `flows-patched.log`, `verify-patched.log`, `verify-patched-findings.txt`, `patch.diff`).
- Written at the repo root by the Android build: `gradle.lockfile`, `gradle-verification.xml` (untracked).
- Not done: `bun exact.mjs feedback note ...` (the project file asks for one on workarounds). I skipped it because this task said to send nothing about the project outward and I did not check where notes go. The coordinator may want to file D1 and the stale-scan symlink problem.
