# Mac features: what was ported from the Swift app

Branch `rewrite/mac-features`, from `rewrite/clinic` at 06a9927. Six features of the Swift app, rebuilt on the Exact app. Each section says what was built, which route was chosen and which were rejected, what happens when a permission is missing, the verdict, and the checks left for a computer-use run.

Verdicts use three words. **VERIFIED** means a command ran on this Mac and its output is quoted below. **NOT VERIFIED** means nothing here ran it. **INCONCLUSIVE** means it ran but does not settle the question.

## The shape

Two new modules in `core/` hold the logic, and one new native seam serves them.

| Piece | What it is |
|---|---|
| `core/system.ts` | The `System` seam: folder I/O by absolute path, `audioInfo`, detection, capture and the mix. `NO_SYSTEM` answers "not here" on every host but macOS. `nativeSystem(native)` maps calls to `sys.*` ops. |
| `core/library.ts` | One `MeetingStore` over app storage and the person's folder. Creates go to app storage; `settle()` moves idle meetings to the folder. |
| `core/legacy.ts` | Reads the Swift app's `yyyy-MM-dd_HHmm_<slug>` folders and imports one into a store. |
| `core/desk.ts` | What Settings and Home ask: folder, import, detection, system audio. |
| `modules/apple/System.swift` | The macOS side of the seam: `SystemOps`, `Detector`, `SystemTap`, `StandInTap`, `Mixer`. `Engine.later` hands it every op that starts `sys.`. |

**Why a separate seam.** `core/engine.ts` is the inference protocol. Three engines answer it: Apple, the web Worker, and the demo engine. Only the macOS module can answer folders, detection and capture. A separate `System` keeps every engine free of ops it cannot answer, and lets every other host get `NO_SYSTEM` in one line. Both seams share the one Exact native module, because Exact gives an app one module class.

**Changes to shared files.**

- `core/host.ts`: one optional field, `HostOptions.store`, and `options.store ?? meetingStore(files)`. Nothing else.
- `core/models.ts`: unchanged.
- `core/store.ts`: `meetingStore(files, root)` takes a root, which defaults to `app:/data/meetings`. New members: `root`, `dir`, `mkdirMeeting` and `relocateAudio`.
- `core/service.ts`: two optional hooks, `finishRecording` (system audio's mix) and `onIdle` (the folder's moves). An absolute audio path is handed to the player as a `file://` URL.
- `SetupView` is unchanged. A first attempt added `host` to it, which broke the clinic's strict shape. The Mac-only UI now keys off `desk.mac` instead.

The clinic (`clinic/**`) is untouched. It still builds and passes (see the acceptance section).

## 1. Notes toolbar (every host)

**Built.** A `NotesToolbar` component above both notes editors: the one shown while recording, and My notes on a meeting. It has four buttons:

- **Timestamp** inserts `[m:ss] ` at the caret. While recording, the time is the recording's elapsed time. On a meeting, it is the player's position, from `timeupdate`.
- **Bullet** runs `format(editor, "bullet")`.
- **Action item** runs `format(editor, "task")`, which makes a `- [ ]` checkbox.
- **Heading** runs `format(editor, "heading", "2")`.

The timestamp uses `setRangeText`. Every button has `retainFocus=true`, so the caret and selection stay in the editor.

**Route.** These are the Markdown editor's own commands. The rejected route was rewriting the string in `app.ts`, which loses the caret and the undo stack.

**Limits.** Exact does not support `setRangeText` on Windows or Android yet, so the timestamp button does nothing there. The other three work.

**Verdict: VERIFIED** on web and macOS by the `toolbar` flow (8 checks each). An agent `type` replaces the whole field, so each step types a fresh value first. Media: `docs/media/web/toolbar/`, `docs/media/macos/toolbar/`.

## 2. Menu bar item (macOS)

**Built.** A button with `-exact-menu="status"` opens the menu `status-menu`. The menu has:

- A status line: "Ready to record", "Recording · m:ss" or "Writing notes…".
- Start recording or Stop recording.
- Open Alona.
- Quit Alona.

`host.macos.window.keepRunning: true` keeps the session alive when the window closes. The item is placed only when the macOS module answers (`desk.mac`).

**Route.** Exact's status item. No native code.

**Verdict: VERIFIED** by the `menubar` flow (10 checks). The flow:

1. Closes the window (`NSWindow.performClose`).
2. Starts a recording from the menu, with the window still closed.
3. Reads `Recording · 0:04` in the menu, then stops from the menu.
4. Reads "Writing notes…", opens the window from the menu, and sees the meeting finish.

Media: `docs/media/macos/menubar/`.

## 3. Meetings folder (macOS)

**Built.** Settings → Meetings folder → Choose folder… shows the system folder picker. The chosen `doc:` handle resolves through `storage.fs.realpath` to an absolute path, which is saved in `app:/data/library.json`.

- **Where meetings live.** A new meeting is always recorded into app storage. `settle()` moves each idle meeting into the folder after the pipeline finishes with it, so a move never races the pipeline. Every meeting stays one folder of plain files, and the person's files and the pipeline's files stay separate (rule 5).
- **How a move works.** The native move copies the meeting to `<dest>.moving`, renames that into place, and then removes the source. If a crash leaves both copies, the next settle keeps the destination and removes the source.
- **When the folder is missing.** The app lists app storage only, keeps recording there, and shows "The folder can't be reached". The moves wait until the folder answers again.
- **Choosing app storage again** brings the folder's meetings back.

**Route.** Absolute paths through the native seam. Two routes were rejected:

- Exact's `doc:` file system: `rm` removes one file or an empty folder, `copyFile` goes only from `doc:` to `app:`, and `readFile` stops at 16 MiB.
- A helper process: not needed.

**Other hosts.**

- **Web:** not offered. The 16 MiB read limit, and no persistent folder handle the engine's Worker can use.
- **iOS:** not offered. Exact keeps no folder handle across launches there.
- **Android:** not offered. There is no `showDirectoryPicker`.

These hosts show no folder section, because `foldersSupported` is false.

**Development builds and release builds** are both unsandboxed. Exact sandboxes only widget extensions. Absolute paths therefore work. If a later build turns on the sandbox, the folder needs a security-scoped bookmark: this is an open risk.

**Verdict: VERIFIED**, by two flows:

- The `folder` flow (9 checks) records a meeting, then chooses a folder through the picker (`type @folder-picker`). The meeting moves there and opens from there, and an edit to My notes lands in the folder's `notes.md`. A check of the files afterwards confirms the meeting is in the folder and no longer in app storage.
- The `folder-missing` flow starts with a chosen folder that does not exist. The meeting is listed from app storage, and Settings shows the folder unreachable with 1 meeting waiting.

Unit tests cover the folder being unplugged and coming back, a crash leftover, a working meeting staying put, and choosing app storage again. Media: `docs/media/macos/folder*/`.

## 4. Importing the Swift app's recordings (macOS)

**Built.** Settings → Recordings from the earlier Alona app.

- **Where it looks.** The default folder is `meetingSaveDirectory` from `com.alona.mac`'s defaults, else `~/Documents/Alona`. The folder is **not read until the person taps "Find recordings"**. Reading inside ~/Documents makes macOS ask for access, and that request should follow the person's tap, not opening Settings. "Look in another folder…" opens the picker instead.
- **What it shows.** The count found and the count not yet imported. Import copies each recording not yet imported.
- **What it imports:**
  - **Audio:** `recording.wav`, else `recording-mono.wav`.
  - **Notes:** `notes.md`, else the autosave `notes.tmp` that a crash left.
  - **Transcript:** `transcript.json`.
  - **Title:** `title.txt`, else the folder name's slug.
  - **Date:** parsed from the folder name, in the Mac's time zone.
  - `summary.md` is skipped, because the Swift app only ever wrote a placeholder there.
- **Ids.** A meeting's id is `swift-<name>-<fnv1a>`, so a second import finds the first and imports nothing twice.
- **Order.** The meeting's record is written last, so an import cut short is not a meeting yet and runs again in full.
- **Stage.** A recording with a transcript arrives `done`. One without arrives `recorded`, and the pipeline transcribes it. Either can be transcribed again, and a meeting with a transcript but no AI notes shows "Write notes".

**Verdict: VERIFIED** by the `migration` flow (11 checks) against a fixture folder the flow builds: two recordings, plus one folder that is not a meeting. The flow:

1. Shows "Not looked for yet".
2. Picks the fixture and finds 2 recordings, 2 new.
3. Imports them, leaving 0 new.
4. Lists both meetings. The one without a transcript goes through the pipeline.
5. Opens "Product sync" (status done, notes `- Ask about pricing`) and shows its transcript.
6. Writes notes for it.

A SHA-256 of every file in the fixture before and after shows the source unchanged. The owner's real recordings were never read: this Mac's `~/Documents/Alona` is empty, and no flow pointed at it. Media: `docs/media/macos/migration/`.

## 5. Meeting detection (macOS 14.2+)

**Built.** `Detector` in Swift listens without polling, through three signals:

- Core Audio's `kAudioHardwarePropertyProcessObjectList`.
- Each process's `kAudioProcessPropertyIsRunningInput`.
- NSWorkspace launch and quit notifications.

On any change it calls `context.changed("meeting")`. The `meet` resource watches that topic and asks `sys.detect` again.

**What counts as a call:**

- **Zoom:** a `us.zoom.*` process with the microphone running.
- **Teams:** a `com.microsoft.teams*` process with the microphone running.
- **A browser call:** Chrome, Arc, Edge, Brave, Firefox or Safari with the microphone running.

**What Accessibility adds:** the browser window's title names a Google Meet call, and a muted Zoom call can be found by its "Meeting" menu. These read `AXIsProcessTrusted()` and never ask.

**How it is offered.** Home shows a card: "<title> is on", with Record and Not now. With notification permission granted, a notification with a Record action also appears. Settings has a switch to turn detection off, which also stops the native listeners. Alona's own process is excluded.

**Routes rejected:**

- Polling `ps` or window lists, which keeps the CPU awake.
- Apple Events to read browser tabs. Exact has no Automation grant, and it would prompt.
- ScreenCaptureKit window titles, which prompt for Screen Recording.

**When permissions are missing.**

- **No permissions:** Zoom and Teams are found, and Meet shows as "A call in Google Chrome" (or whichever browser has the microphone).
- **No notification permission:** the card only. "Also notify me" asks for permission when tapped.

**Verdict.**

- **The UI path: VERIFIED.** The `detection` flow (8 checks) writes a fixture marker that the module reads under the agent. The card appears, Record starts a recording titled from the call, and the offer goes away. Turning the switch off clears it.
- **The real listeners: NOT VERIFIED.** No Zoom, Teams or Meet call ran on this Mac. The agent build skips the real detector, so drives repeat.
- **The notification and its Record action: NOT VERIFIED.** The permission was not granted under the agent.

## 6. System audio (macOS 14.2+)

**Built.** Settings → System audio → "Record other people in the call" (off by default).

- **Recording.** The microphone stays on `@exact/recording` on every host, for its waveform, its permission flow and its agent drives. The native module records only what the Mac plays. `SystemTap` uses a `CATapDescription` that excludes Alona's own process, a private aggregate device, and an IOProc that passes each buffer to `ExtAudioFileWriteAsync`, which writes `system.m4a` (AAC). Nothing builds up in memory.
- **Alignment.** The offset is measured from the start request to the tap's first callback.
- **Mixing.** At Stop, `Mixer` mixes the microphone and system files into `audio-mixed.m4a`, 4096 frames at a time, at 48 kHz mono AAC. It writes `*.partial` and then renames, so memory stays the same for any length.
- **Failure.** If the mix fails, the meeting keeps the microphone file.
- **Health.** A tap that delivers only zeros, which is what a denied permission gives, sets health to `silent`. Settings then says so and links to the privacy pane.

These fix both Swift-app defects: the whole-file mix at Stop, and unbounded buffers.

**Why the native module does not record both sources.** Moving the microphone into the module would cost the Exact recorder's waveform, permission prompt and agent substitution on every host, for one platform's feature. Two files mixed at Stop cost one pass over the audio, in constant memory.

**Route.** Ranked, the routes were:

1. **A new Exact grant row. Chosen.** It is kept as a patch, because the grant table has no `NSAudioCaptureUsageDescription` and Exact refuses hand-written Info.plist keys.
2. A helper executable through `@exact/child-process`. Not needed: the tap runs in the app process, and the usage key must be in the app's Info.plist anyway.
3. ScreenCaptureKit audio. Rejected: it asks for Screen Recording, a heavier permission.

**When the permission is missing.** The tap starts, but macOS hands it silence. The recording is the microphone mixed with silence, so nothing is lost, and Settings shows the "silent" warning. With the switch off, nothing native runs at all.

**Verdict.**

- **The path up to the permission: VERIFIED.** Under the agent, `StandInTap` writes a 1500 Hz tone in place of the Mac's sound; the agent's microphone is a 440 Hz tone. The `system-audio` flow records with the switch on. The meeting keeps `audio-mixed.m4a`, and Settings reads health `heard`. Band levels from ffmpeg: mixed at 440 Hz −12.3 dB, mic file at 440 Hz −12.3 dB, mixed at 1500 Hz −30.9 dB, mic file at 1500 Hz −81.3 dB. Both sources are in the mix.
- **The built Info.plist carries `NSAudioCaptureUsageDescription`: VERIFIED** (`plutil -p`).
- **The real Core Audio tap: NOT VERIFIED.** It cannot run without the System Audio Recording prompt.
- **Memory over a long recording:** see the acceptance section.

## Exact patch

`tools/patches/exact-3baa28f-audio-capture.patch` adds one row, `audio-capture`, to `runner/src/device.rs`. Its macOS key is `NSAudioCaptureUsageDescription`, and it does nothing on tvOS. Exact's device tests pass with it: `cargo test --lib device`, 11 passed.

**When to apply it.** Apply it to any Exact checkout that builds Alona for macOS or iOS, until Exact has the row:

```sh
cp -cR /path/to/exact /tmp/exact-alona && git -C /tmp/exact-alona apply tools/patches/exact-3baa28f-audio-capture.patch
EXACT=/tmp/exact-alona bun exact.mjs mac
```

Without the patch, a native bake refuses `device.audio-capture` with `grant-device: ... is not a device grant`. Web builds, `verify web` and the clinic build do not read the line and pass without the patch. To build a Mac app without system audio instead, remove that grant line from `app.ts`. The tap then gets no usage key, so leave the switch off.

`git apply --check` passes against the shared checkout at 3baa28f. The check was the only thing run there; the checkout itself was not changed. The xcode26 patch is independent of this one.

## Permission prompts, in the order a person meets them

| Prompt | When | If denied |
|---|---|---|
| Microphone | First Record | The existing "microphone denied" screen; no recording |
| Documents folder ("Alona would like to access files in your Documents folder") | Tapping **Find recordings** (default folder in ~/Documents), or a meetings folder inside ~/Documents, ~/Desktop or a removable volume. Picking through the folder panel usually grants it without a prompt | Import finds nothing; folder shows unreachable |
| System Audio Recording | First recording with System audio on | Recording continues with the microphone; Settings shows "silent" |
| Notifications | Tapping **Also notify me** | Card on Home only |
| Accessibility (optional) | Only if the person opens the pane from Settings; Alona never calls the prompting API | Meet calls show as "A call in <browser>"; muted Zoom calls are missed |

## Checks for a computer-use run

Build with the patch (`EXACT=<patched copy> bun exact.mjs mac`) and open `target/clients/*/com.alona.app/macos/Alona.app` normally, not under the agent.

1. **Menu bar.**
   1. Close the window. The menu bar item stays.
   2. Choose Start recording from the menu and allow the **Microphone** prompt. The menu shows `Recording · 0:0x`.
   3. Choose Stop recording. The menu shows "Writing notes…".
   4. Choose Open Alona. The window shows the meeting.
2. **System audio.**
   1. In Settings, turn on "Record other people in the call".
   2. Play a YouTube video aloud and start recording. Allow the **System Audio Recording** prompt.
   3. Talk over the video for 30 s, then stop.
   4. Open the meeting folder in Finder: `system.m4a` and `audio-mixed.m4a` exist, and playing the meeting has both your voice and the video.
   5. Settings shows no "silent" warning.
   6. In System Settings → Privacy → System Audio Recording, turn Alona off and record again. The recording still has your voice, and Settings shows the silent warning.
3. **Detection.**
   1. Join a Zoom test meeting (zoom.us/test). Home shows "Zoom meeting is on" within a few seconds.
   2. Tap **Also notify me** and allow **Notifications**.
   3. Leave and rejoin. A notification with **Record** appears, and pressing Record starts a recording titled "Zoom meeting".
   4. Join a Google Meet in Chrome. Home shows "A call in Google Chrome is on", or the Meet title if Accessibility is on.
   5. Turn detection off in Settings. The card goes away.
   6. Check that Activity Monitor shows Alona near 0% CPU while idle with detection on.
4. **Meetings folder.**
   1. Choose a folder on an external drive, and record a meeting. After the notes are written, the meeting's folder is on the drive.
   2. Eject the drive. Settings shows the folder unreachable, recording still works, and the meetings on the drive are no longer listed.
   3. Reinsert the drive. The new meeting moves there.
5. **Import.**
   1. In Settings, tap **Find recordings** and allow the **Documents** prompt. The count matches the folders in `~/Documents/Alona`, or in the folder the Swift app used.
   2. Tap Import. Every recording appears with its date and title, and `ls -lR` of the source folder is identical before and after.
   3. Tap Import again. Nothing new appears.

## Acceptance

Filled from runs on this Mac (Apple Silicon, 8 GB, macOS 26). Commands ran from the worktree with Bun 1.4.2. `EXACT` points at the patched copy for the macOS runs, and is unset (shared checkout) for the web runs.

| Check | Verdict | Command | Output tail |
|---|---|---|---|
| Unit tests | VERIFIED | `bun test` | `101 pass · 0 fail` (core 71, incl. 30 new in `core/desktop.test.ts`) |
| Web verify | VERIFIED | `bun exact.mjs verify web` | `verify: clean in 15.7 s; contract verify: done; 0 findings` |
| Web flows | VERIFIED | `bun tools/flows.mjs web` | `7 passed, 0 failed` (6 old + toolbar) |
| macOS flows | VERIFIED | `EXACT=<patched> bun tools/flows.mjs macos` | `13 passed, 0 failed` (6 old + toolbar, menubar, folder, folder-missing, migration, detection, system-audio) |
| Real models | VERIFIED | `EXACT=<patched> bun tools/e2e-native.mjs lite` | `word error rate: 4.2% (7 of 168)`; idle after cycles 93, 88, 89 MB; five headings; `e2e: ok` |
| System audio in the recording | VERIFIED up to the permission; real tap NOT VERIFIED | `system-audio` flow | mix has the 440 Hz mic band (−12.3 dB) and the 1500 Hz system band (−30.9 dB vs −81.3 dB in the mic file) |
| Memory over 10 minutes | VERIFIED for recording; see note | `EXACT=<patched> bun tools/e2e-native.mjs --long 10` | footprint by minute (MB): `46, 48, 50, 51, 53, 54, 55, 57, 58, 62, 63`; mix 600.5 s; `long recording: ok` |
| Clinic | VERIFIED | `bun tools/tenant.mjs verify default web` | `verify: clean in 26.8 s` (after deleting a stale `.exact/tenants/default/app/target/web-dist`) |

**Memory note.** While recording, the footprint rises about 1.7 MB a minute (46 → 63 MB over 10 minutes). The figures come from `docs/media/macos-real/long-recording-10min.json`. Under the agent this is Exact's recorder and the app; the real tap is not running. From Stop until the meeting is done, the footprint peaks at about 1.2 GB. The peak is not the mix. Two 2-minute runs: system audio on, 1148 MB; microphone only, 1240 MB (`--long 2 --mic-only`). The source of the peak is somewhere in the stop path that predates this branch, and it is not identified. It is listed as an open risk.

## Open risks

- About 1.2 GB peak footprint between Stop and done, with or without system audio (see the memory note). It predates this branch, and its source is not identified.

- The real Core Audio tap, the real detector, and notifications have not run on this Mac. Each is listed above for a computer-use run.
- If a release build of the Mac app is ever sandboxed, the meetings folder and the import need security-scoped bookmarks instead of absolute paths.
- The tap's offset is the delay to its first callback. The device's own output latency is not counted, so the two sources can be tens of milliseconds apart. That is fine for transcription, but audible on a careful listen.
- A tap that never delivers a buffer reports `silent`, the same as a denial. Health cannot tell "denied" from "nothing played".
- Teams' and Zoom's bundle ids are matched by prefix. A renamed helper would be missed.
- Without the patch, a native build of this branch fails until the grant line is removed (see the Exact patch section).
