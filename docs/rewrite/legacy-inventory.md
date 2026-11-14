# Alona legacy app inventory

Read-only inventory of the Swift/SwiftUI macOS app as of commit `3f9f4cc` (main, last commit 2026-01-11). Nothing was built or run. Every claim cites `path:line` relative to the repo root. Items marked **inferred** come from reading code, not from running it. Items marked **unverified** could not be settled from the code alone.

Source: 8,947 lines of Swift in `Alona/` and `AlonaTests/`. Bundle id `com.alona.mac` (`Alona.xcodeproj/project.pbxproj:516`). Deployment target macOS 14.6 (`Alona/Info.plist:19-20`, pbxproj:443). `Package.swift:10` says 14.2 for the SPM test target.

## 1. Feature list

Status key: implemented, partial, stub, absent. "Absent" rows are things the README, PRD or RFC-001 mention that the code does not do.

| # | Feature | Status | Evidence and caveats |
|---|---------|--------|----------------------|
| 1 | Zoom meeting detection | implemented | Mic-activity signal first, Accessibility menu-item probe second (`MeetingDetector.swift:174-206`). Title is always the literal "Zoom Meeting" (:189, :204). |
| 2 | Google Meet detection | implemented, Chrome only | AppleScript over Chrome tabs (`MeetingDetector.swift:209-238`, script :350-377). Safari, Edge, Arc, Firefox are not checked. |
| 3 | Microsoft Teams detection | stub | `MeetingApp.teams` exists (:12) and `isAnyMeetingAppUsingMicrophone` mentions Teams (`MicrophoneActivityTracker.swift:93-97`), but nothing calls either. |
| 4 | Floating "Meeting Detected" popup | implemented | `MeetingPopupWindow.swift:17-59`, `MeetingDetectedPopup.swift:5-99`. Ignore / Record buttons, 7 s auto-dismiss. |
| 5 | System notification with "Start Recording" action | implemented | `MeetingNotificationManager.swift:30-60`. Fires in addition to the popup (`MeetingDetector.swift:248-255`). |
| 6 | Manual start/stop recording | implemented | Startup hero card tap (`StartupView.swift:88-90, 375-383`), menu bar button (`MenuBarView.swift:97, 241-252`), notes window Stop (`MeetingNotesView.swift:54-57`). |
| 7 | Auto-start recording on detection | absent | PRD journey says "Recording auto-starts" (`docs/PRD...md:42`). Code only prompts (RFC-001:1180 says "preserving manual control"). |
| 8 | Auto-stop when the meeting ends | absent | No code path calls `stopRecording` from detector state. Only three user-driven callers exist (rows above). |
| 9 | Pause/resume recording | absent | PRD:58, :100. No such API on `AudioRecordingController` (`AudioRecorder.swift:8-14`). |
| 10 | Microphone capture | implemented | `AudioRecorder.swift:385-513`. |
| 11 | System audio capture | implemented, off by default | Global CoreAudio process tap (:192-282). Toggle default false (`AppState.swift:77`). |
| 12 | Dual-channel and 16 kHz mono WAV output | implemented | Section 5. |
| 13 | Notes editor during recording | implemented | Plain `NSTextView`, monospaced, not rich text (`MeetingNotesView.swift:237-258`). Toolbar inserts timestamp, bullet, action item (:98-145). |
| 14 | Markdown rendering or markdown-aware editing | absent | No parsing or preview anywhere. File is named `notes.md` but content is plain text (Section 2.7). |
| 15 | Notes autosave | implemented | 2 s debounce to `notes.tmp` (`AppState.swift:221-241`). |
| 16 | Notes crash recovery | partial, ineffective | `recoverNotesFromTemp` runs only at start of a new recording in a fresh folder (`AppState.swift:130`), so it never finds a draft. No launch-time scan. |
| 17 | Editable meeting title | implemented | Notes window (`MeetingNotesView.swift:76-81`) and Recordings detail (`RecordingsBrowserView.swift:101-105`). Writes `title.txt`. Folder is not renamed. |
| 18 | Local Whisper transcription | implemented, with a defect | `TranscriptionEngine.swift:45-71`. Selected model is ignored (Section 8, D2). |
| 19 | Transcription queue, cancel, progress | implemented, in memory only | `AppState.swift:262-367`, `TranscriptionQueueView.swift`. Queue is lost on quit. |
| 20 | Regenerate transcript | implemented | `RecordingsBrowserView.swift:198-203` calls `AppState.swift:190-192`. Overwrites transcript and summary. |
| 21 | AI summary | stub | `PlaceholderSummaryProvider` (`SummaryManager.swift:19-40`). Section 2.8. |
| 22 | Summary display in UI | absent | `summary.md` is written (`MeetingFileManager.swift:100-103`) and never read. No view references it. |
| 23 | Recordings browser | implemented, minimal | List, title edit, play, transcript view, notes edit, regenerate. No delete, search, export, reveal in Finder, summary, or seek bar. |
| 24 | Audio playback | implemented, minimal | `RecordingAudioPlayer.swift:12-28`. Button is labelled Pause but calls `stop()` (`RecordingsBrowserView.swift:135-140`). |
| 25 | Settings: system-audio toggle, save folder | implemented | `SettingsView.swift:56-123`. Changing folder does not move existing meetings. |
| 26 | Whisper model download, select, delete | implemented, weak validation | `ModelManager.swift:408-477`. Section 8, D3. |
| 27 | Permission status and request UI | implemented | `OnboardingView.swift`, `PermissionManager.swift`. |
| 28 | First-run onboarding | absent | `AppState.showOnboarding` (`AppState.swift:11`) has no readers. Onboarding window opens only from the Startup "Permissions" button (`StartupView.swift:196-200`). |
| 29 | Menu bar extra with recent recordings | implemented | `AlonaApp.swift:73-80`, `MenuBarView.swift`. Shows 3 newest (:152). |
| 30 | Error display to the user | absent | `AppState.recordingError` is set at five error sites and cleared once (`AppState.swift:137, 141, 156, 258, 391, 401`) and read by no view (grep `recordingError` outside AppState returns nothing). `transcriptionState` is also unread (its only view, `TranscriptionProgressView`, is never instantiated). |
| 31 | Retention policy, auto-delete, Reveal in Finder, completion notification | absent | PRD:119-122, RFC-001:1081-1085 (unchecked boxes). |
| 32 | Parakeet / LM Studio / remote LLM providers | absent | PRD:15, :115-116 only. |

README status check. "Meeting Detection: automatically detects" is true for detection, false if read as auto-recording. "Audio Capture: records system audio and microphone" is true only when the user turns on the toggle. "Notes & Summaries ... not complete yet" is accurate (row 21). The README lists 5 models (`README.md:102-108`); the code has 11 (`ModelManager.swift:9-19`).

## 2. User flows

### 2.1 First launch
1. `main.swift:8-41` starts `AlonaApp.main()` unless `XCTestConfigurationFilePath` is set (test mode uses a minimal AppKit app).
2. `AlonaApp.init` creates `AppState`, `PermissionManager` (which runs `refreshAllPermissions` immediately, `PermissionManager.swift:74-81`), and `MeetingDetector`, then calls `startMonitoring()` (`AlonaApp.swift:19-49`).
3. Creating `MeetingDetector` touches `MeetingNotificationManager.shared`, whose init requests notification authorization (alert, sound) (`MeetingNotificationManager.swift:23-28, 76-82`).
4. `AppDelegate.applicationDidFinishLaunching` calls `AXIsProcessTrustedWithOptions(prompt: true)` if Accessibility is not granted, on every launch (`AppDelegate.swift:35-39, 51-64`).
5. The default `WindowGroup` opens `StartupView` (`AlonaApp.swift:54-64`). The Dock icon is visible (`Info.plist:29-30`, `LSUIElement` false). Closing all windows keeps the app alive (`AppDelegate.swift:42-45`).
6. There is no wizard. The user sees Startup with a permission summary and model status footer (`StartupView.swift:220-278`).

### 2.2 Permissions
Four types (`PermissionManager.swift:11-53`).

| Permission | Check | Request | Used for |
|------------|-------|---------|----------|
| Microphone | `AVCaptureDevice.authorizationStatus` (:211-222) | `AVCaptureDevice.requestAccess` (:158-162) | Mic capture. Also prompted implicitly when `AVAudioEngine` starts. |
| System Audio Recording | Private TCC `TCCAccessPreflight("kTCCServiceAudioCapture")` via `dlopen` (:285-318), cached in UserDefaults `systemAudioPermissionGranted` (:230, :235) | Private `TCCAccessRequest` (:245-277), else opens the Privacy_ScreenCapture pane | Process tap. |
| Accessibility | `AXIsProcessTrusted` (:320-322) | Prompt plus open pane plus 30 s poll (:170-190) | Zoom menu probe. |
| Automation | Runs AppleScript `tell application "System Events" to get name of every process` on a background task; error -1743 or any error means denied (:138-153) | Same script, opens pane on denial (:191-202) | Chrome tab reads, Zoom probe. |

The Onboarding window lists each with status badge, "Request Access", "Open Settings", "Refresh" (`OnboardingView.swift:39-84`). Status is not re-polled automatically; `refreshAllPermissions` runs on Startup `.task` (`StartupView.swift:37-41`), menu bar `.task` (`MenuBarView.swift:39-44`), and Refresh.

### 2.3 Meeting detection to popup
1. `startMonitoring` installs a 2 s timer and an `NSWorkspace.didActivateApplication` observer, and starts `MicrophoneActivityTracker` (its own 2 s timer) (`MeetingDetector.swift:45-68`, `MicrophoneActivityTracker.swift:22-33`).
2. Each tick reads cached mic-usage flags on the main thread, then runs a detached utility task (:70-84).
3. Zoom check (:174-206). Zoom counts as running if bundle id is `us.zoom.xos`, `us.zoom.ZoomHelperAgent`, or `us.zoom.Workplace`. If the tracker says a Zoom id (`us.zoom.xos`, `ZoomHelperAgent`, `Workplace`, `us.zoom.videomeetings`, `MicrophoneActivityTracker.swift:82-85`) has audio input running, Zoom is "detected". Otherwise, if `AXIsProcessTrusted()`, run an AppleScript that looks for menu item "Leave Meeting" or "End Meeting" under the Meeting menu of `zoom.us` or `Zoom Workplace` (:305-343). Without trust the result is `.permissionDenied`.
4. Google Meet check (:209-238). Chrome must be running (`com.google.Chrome`). AppleScript walks every window and tab, matches URLs starting `https://meet.google.com/`, excludes `/lookup/`, `authuser`, `/new`, and requires a hyphen in the path (:350-377). Returns the tab title with " - Google Meet" removed (:291-295). The mic flag is accepted but ignored (:209).
5. Zoom wins if both are detected (:112-116).
6. `handleDetection` sets `isInMeeting`, `detectedApp`, `meetingTitle`. If the identifier `"<bundleId>|<title>"` differs from the last one notified, it shows the popup and posts a system notification (:241-258).
7. Popup: borderless floating `NSWindow`, 340x80, top-right of `NSScreen.main`, all Spaces (`MeetingPopupWindow.swift:34-71`). Buttons: Ignore (dismiss only), Record (calls `onStartRecording`, then dismiss). Auto-dismiss after 7 s (`MeetingDetectedPopup.swift:83-85`).
8. Record posts `.meetingNotificationStartRecording` with the title (`MeetingDetector.swift:272-278`). `AppState` observes it and calls `startRecording(meetingTitleOverride:)` unless already recording (`AppState.swift:106-117`). The notification action does the same (`MeetingNotificationManager.swift:46-59`). Tapping the notification body and tapping its action button both start recording.
9. Clearing: no detection for 3 consecutive polls while the app is still running, or immediately if the app is not running, resets state and `lastNotificationIdentifier` (:136-164). A later re-detection re-notifies.
10. Startup also shows an inline "Meeting Detected!" card with Record and Dismiss. Dismiss stores `dismissedDetectionIdentifier` (`StartupView.swift:133-166, 319-323`, `AppState.swift:170-188`). The popup's Ignore does not touch this field.

### 2.4 Start recording
1. Title resolution: override or current `meetingTitle`, trimmed; if empty or equal to "No meeting detected", use `"MMM d, yyyy 'at' h:mm a"` of now (`AppState.swift:245-251, 213-218`).
2. `AudioRecorder.startRecording` creates the meeting folder (Section 4), starts the mic first, opens the WAV, starts the system tap if enabled, starts a 1 s duration timer (`AudioRecorder.swift:81-120`).
3. `AppState` stores `currentMeetingDirectory`, loads `notes.tmp` if present (never present), sets title, writes `title.txt`, clears `recordingError`, resets `transcriptionState`, and sets `notesWindowRequestID = UUID()` (`AppState.swift:125-143`).
4. `StartupView` or `MenuBarView` sees the new id and focuses or opens the `meeting-notes` window (`StartupView.swift:42-44`, `MenuBarView.swift:51-53`). Both observe it, and `focusOrOpen` is idempotent (`StartupWindowController.swift:16-23`). If neither view is alive the window may not open (**unverified**).
5. On error, only `recordingError` is set; nothing is shown (Section 1 row 30).

### 2.5 Stop recording
1. `AppState.stopRecording` awaits `AudioRecorder.stopRecording` (`AppState.swift:145-163`). That stops tap, mic, timer; flushes buffers on `bufferQueue.sync`; closes files; then builds `recording-mono.wav` before returning (`AudioRecorder.swift:123-158`). The user's Stop button stays blocked on this (menu bar uses `recordingActionInFlight`, `MenuBarView.swift:241-252`).
2. Saves final notes to `notes.md` and deletes `notes.tmp` (`MeetingFileManager.swift:78-82`). Errors set `recordingError`.
3. Clears `notesDraft`, enqueues an automatic job with `showProgressInMainUI: true`, clears `currentMeetingDirectory` (`AppState.swift:159-162`).

### 2.6 Transcription queue and progress
1. `enqueueTranscription` builds a `TranscriptionJob(state: .pending)` capturing title and notes text at that moment (`AppState.swift:262-280`).
2. `processQueue` runs one job at a time (`activeJobTask` guard, :283). FIFO by array order.
3. States: pending, preparing, processing(0..1), summarizing, completed(date), failed(msg), cancelled (:421-438). Progress comes from the engine's shared `CurrentValueSubject` and is attributed to `activeJobID` (:354-367).
4. `runPostProcessing` reads `recording-mono.wav`, transcribes, saves transcript files, sets summarizing, calls the summary provider, saves `summary.md` (:369-394).
5. On finish or failure the queue moves on; when no pending job remains it calls `unloadModelIfIdle()` (:283-288), which unloads the Whisper model immediately after every batch (the 2-minute timer at `TranscriptionEngine.swift:35` is effectively unused).
6. Cancel: pending jobs flip to cancelled at once. For the active job the Task is cancelled, but cancellation is only checked between steps (`AppState.swift:371-374, 385`), so an in-flight Whisper call likely runs to completion first (**inferred**; SwiftWhisper source not read).
7. UI: the Queue window lists all jobs of this session with state, progress bar for processing, error text, Cancel for busy jobs (`TranscriptionQueueView.swift:23-97`). Failed jobs have no Retry button. Regenerate in Recordings is the only retry.

### 2.7 Notes during a meeting
- Editor: `NSTextView`, plain text, monospaced 13 pt, smart quotes and dashes off (`MeetingNotesView.swift:244-252`). Two-way bound to `AppState.notesDraft` (:152, :280-283).
- Toolbar inserts at the cursor via `NotesInsertion` (:294-305): `"[mm:ss] "` from `recordingDuration` (Timestamp, disabled when not recording, :112, :197-200), `"• "` (:202-204), `"☐ "` (:206-208). These are not Markdown list or task syntax.
- Autosave: every `notesDraft` change, if different from `lastSavedNotesDraft`, cancels and re-arms a 2 s sleep task that writes `notes.tmp` (`AppState.swift:221-241`). Writes only if a meeting directory is set (:254).
- Finalize: stop writes `notes.md` verbatim (Section 2.5). Footer shows a word count and a static "Auto-saved" label that does not reflect save state (`MeetingNotesView.swift:165-187`).
- Markdown handling: none. The summary placeholder is Markdown, but notes are stored and displayed as raw text. The only notes path outside a live session is the Recordings detail `TextEditor`, which writes `notes.md` on every keystroke (`RecordingsBrowserView.swift:253-278`).

### 2.8 Summary generation (what it actually does)
`SummaryManager` forwards to `PlaceholderSummaryProvider` (`SummaryManager.swift:7-17`). The provider sleeps 1 s, then returns a fixed Markdown template (:19-40): `# Meeting Summary`, `*Generated: <date>*`, `## Highlights` with a fixed bullet plus the first 200 characters of transcript, `## Notes Snapshot` with the first 200 characters of notes, `## Next Steps` with a fixed unchecked task "Replace placeholder generator with ML-powered provider." Empty inputs become `*Transcript pending*` or `*No notes provided*`. No model, no prompt, no metadata. The protocol `SummaryProviding.generateSummary(transcript:notes:) async throws -> String` (:3-5) is the only extension seam. Tests pin the headings and truncation (`SummaryManagerTests.swift:36-84`).

### 2.9 Recordings browser and playback
1. Open from Startup, menu bar. Loads `meetingEntries()` synchronously on appear and on Refresh, selects the first (`RecordingsBrowserView.swift:24, 308-317`).
2. Sidebar: title and date. Detail: editable title, date, audio row, transcript, notes (:68-94).
3. Audio: finds `recording.wav`, else `recording-mono.wav` (`MeetingFileManager.swift:159-169`). Play uses `AVAudioPlayer` on the whole file; no scrubber, no duration (`RecordingAudioPlayer.swift:12-28`). Selection change and window disappear stop playback.
4. Transcript: shows `transcript.txt` as one block (monospaced 12 pt). Segment JSON and timestamps are never displayed. While a job for that folder is busy it shows "Transcribing..." instead of Regenerate (:189-206).
5. Notes: editable, saved on each change (:263-266).

### 2.10 Settings
Window `settings-window`, fixed 700x500, sidebar with two tabs (`SettingsView.swift:14-47`).
- General: "Capture system audio" toggle (writes UserDefaults, updates recorder) and save folder with `NSOpenPanel` (:69-122). Copy says disabling it hides the macOS "Currently Sharing" banner (:73-77).
- Transcription Models: active model badge, list of 3 recommended models or all 11, per-row select (tap), download, cancel, delete, retry; a 100-line download log (:149-199, :424-471).
- Not present: LLM settings, language, autosave interval, auto-start, notification toggles, retention.

### 2.11 Model download and selection
1. Selection persists to UserDefaults `selectedWhisperModel` (`ModelManager.swift:330-335`). Default `large-v3-turbo` (:118, :365).
2. Availability: user dir `~/Library/Application Support/Alona/Models/ggml-<id>.bin` first, then bundle `Resources/Models` (:170-179). Bundle models are gitignored (`Alona/Resources/Models/.gitignore`), so a fresh clone has none.
3. Download: `URLSession.downloadTask` GET to `https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-<id>.bin`, 60 s request timeout, 3600 s resource timeout, 1 connection per host, no resume (:429-451). Progress delegate updates per-model `DownloadInfo` (bytes, speed, ETA) and logs every 10 percent (:486-505, :632-660).
4. Completion copies the temp file and moves it into the user dir, replacing any existing file, then marks available (:598-615, :511-531).
5. The Startup footer shows selected-model status with a Download button (`StartupView.swift:234-259`).
6. Transcription does not honour the selection (D2).

## 3. Meeting lifecycle state machine

Three independent machines exist. No single enum models the lifecycle; state is spread across `AppState.isRecording` (set by the recorder's publisher, `AppState.swift:82-87`), `currentMeetingDirectory`, `transcriptionJobs`, and `MeetingDetector`.

### 3.1 Detection (`MeetingDetector.swift`)
| State | Meaning |
|-------|---------|
| NotInMeeting | `isInMeeting=false`, title "No meeting detected" |
| InMeeting(app, title) | set by `handleDetection` (:241-258) |
| InMeeting, stale | still true while `missedDetectionCount` < 3 and app is running (:138-155) |

| Event | From | To | Side effects |
|-------|------|----|--------------|
| Detect zoom or meet | any | InMeeting | popup and notification only if identifier changed |
| Same identifier again | InMeeting | InMeeting | none |
| Title changes | InMeeting | InMeeting (new id) | new popup and notification |
| Miss, app running, count<3 | InMeeting | InMeeting | count++ |
| Miss, count>=3 or app not running | InMeeting | NotInMeeting | clears identifier |

The detector never talks to recording state. Popups can appear while recording (no `isRecording` check in `handleDetection`).

### 3.2 Recording (`AppState` plus `AudioRecorder`)
| State | Condition |
|-------|-----------|
| Idle | `isRecording=false`, `currentMeetingDirectory=nil` |
| Recording | recorder started, directory set |
| Finalizing | inside `stopRecording`: tap stop, flush, mono mix, notes save (not an explicit state; UI shows nothing) |

| Event | Transition | Effects |
|-------|------------|---------|
| StartRequested(title?) | Idle to Recording | folder created, notes window requested (`AppState.swift:125-143`) |
| StartRequested while Recording | no guard in `AppState.startRecording`; `AudioRecorder` returns the existing folder (:82-84) but `AppState` would reload the draft. UI paths prevent it, except the notification path which checks `!isRecording` (:111). |
| Start error | stays Idle | `recordingError` set, possible resource leak (D10) |
| TitleEdited | Recording | `title.txt` rewritten (`AppState.swift:165-168, 396-403`) |
| NotesEdited | Recording | debounced `notes.tmp` |
| SystemAudioToggledOff | Recording | tap stopped, mic duplicated into both channels (`AudioRecorder.swift:32-41`). Toggling on mid-recording does nothing until next start. |
| StopRequested | Recording to Finalizing to Idle | `notes.md` written, job enqueued |

### 3.3 Post-processing job (`TranscriptionJob.State`, `AppState.swift:421-438`)
`pending -> preparing -> processing(p) -> summarizing -> completed(date)`; any step may go to `failed(msg)`; `pending` or active may go to `cancelled`. `isBusy` is true for pending, preparing, processing, summarizing. A parallel UI enum `TranscriptionState` (idle, preparing, processing, summarizing, completed, failed) mirrors the job flagged `showProgressInMainUI` (`AppState.swift:294-297, 311-337, 406-413`); nothing reads it. A manual regenerate has `showProgressInMainUI=false` (:191). Jobs are never removed. They live in `AppState.transcriptionJobs` until quit.

## 4. Data shapes

### 4.1 Per-meeting folder
Base dir: UserDefaults `meetingSaveDirectory` (plain path string, `MeetingFileManager.swift:27, 44-54`), default `~/Documents/Alona` (:31-34). No security-scoped bookmark; no `.entitlements` file found in the repo (the app appears unsandboxed, **inferred**).

Folder name `yyyy-MM-dd_HHmm_<slug>` using the device's local time (:56-66). Collision appends `-1`, `-2`, ... (:67-71). Slug: every character that is not a letter, digit (Unicode `alphanumerics`) or hyphen becomes `-`, runs of `-` collapse, ends trimmed, empty becomes "Meeting", cut to 50 characters (:171-196). Example: `2025-11-27_1030_Product-Sync/`.

| File | Writer | Format | When |
|------|--------|--------|------|
| `title.txt` | `saveTitle` (:152-157) | UTF-8, trimmed, "Untitled meeting" if empty | at folder creation, on every title edit |
| `recording.wav` | `AudioRecorder.prepareDualChannelWriter` (:165-174) | 2-channel Float32 WAV at the mic's native rate (often 48 kHz); L=system, R=mic | opened at start, closed at stop |
| `recording-mono.wav` | `createMonoMix` (:620-736) | 1-channel Float32 WAV, 16 kHz, `(L+R)/2` | at stop, before job enqueue; errors swallowed by `try?` (:156) |
| `notes.tmp` | `saveNotesDraft` (:105-108) | UTF-8 text | autosave while recording |
| `notes.md` | `saveNotes` (:78-82) | UTF-8 plain text | at stop; also Recordings editor on each edit; deletes `notes.tmp` |
| `transcript.txt` | `saveTranscript` (:84-98) | UTF-8; segment texts joined with a single space | after transcription |
| `transcript.json` | same | pretty-printed, sorted keys: `[{"start": Double sec, "end": Double sec, "text": String}]` (`TranscriptSegmentRecord`, :3-7) | after transcription |
| `summary.md` | `saveSummary` (:100-103) | UTF-8 Markdown | after summary |

No manifest, index, database, or per-meeting JSON exists. Meeting identity is the folder URL (`MeetingEntry.id`, :9-23). Created time is the filesystem creation date (:138-139), so copying a folder reorders it. Not stored anywhere: duration, source app, model used, language, speaker labels, summary provenance, job status, or which channel held which stream beyond the L/R convention.

### 4.2 Other persisted state
| Location | Key or path | Value |
|----------|-------------|-------|
| UserDefaults | `meetingSaveDirectory` | path string |
| UserDefaults | `AppState.captureSystemAudio` | Bool, default false (`AppState.swift:77, 211`) |
| UserDefaults | `selectedWhisperModel` | `WhisperModel` raw string |
| UserDefaults | `systemAudioPermissionGranted` | Bool cache (`PermissionManager.swift:230, 268`) |
| File | `~/Library/Application Support/Alona/Models/ggml-<id>.bin` | Whisper weights (`ModelManager.swift:151-161`) |

### 4.3 Whisper model catalog (`ModelManager.swift:9-55, 121-125`)
| Id | Size MB | Speed label | Multilingual |
|----|---------|-------------|--------------|
| tiny.en | 75 | ~10x | no |
| tiny.en-q5_1 | 31 | ~10x | no |
| base.en | 142 | ~7x | no |
| base.en-q5_1 | 57 | ~7x | no |
| small.en | 466 | ~4x | no |
| small.en-q5_1 | 182 | ~4x | no |
| medium.en | 1500 | ~2x | no |
| medium.en-q5_0 | 515 | ~2x | no |
| large-v3 | 2900 | ~1x | yes |
| large-v3-turbo (default) | 1600 | ~2x | yes |
| large-q5_0 | 1030 | ~1.5x | yes |

Recommended in UI: large-v3-turbo, small.en, base.en. Sizes and speed labels are hard-coded estimates, not measured.

### 4.4 Main in-memory types
| Type | Fields | Cite |
|------|--------|------|
| `TranscriptionResult` | `text: String`, `segments: [TranscriptionSegment]` | `Models/TranscriptionResult.swift:3-6` |
| `TranscriptionSegment` | `startTime`, `endTime` (seconds, from whisper ms / 1000), `text` (trimmed) | :8-12, `TranscriptionEngine.swift:62-67` |
| `TranscriptionJob` | `id: UUID`, `directory: URL`, `title`, `notes`, `requestedAt`, `state`, `source` (automatic or manual), `showProgressInMainUI` | `AppState.swift:415-448` |
| `MeetingEntry` | `directory`, `title`, `createdAt` | `MeetingFileManager.swift:9-23` |
| `ModelStatus` | available, downloading(progress, `DownloadInfo`), notDownloaded, failed(msg) | `ModelManager.swift:236-254` |
| `DownloadInfo` | bytes downloaded, total, bytes/s, start, last update | :257-303 |
| `DownloadLogEntry` | id, timestamp, message, type (info, progress, warning, error, success); capped at 100 | :306-325, :353 |
| `PermissionType` / `PermissionStatus` | microphone, systemAudio, accessibility, automation / granted, denied, notDetermined | `PermissionManager.swift:11-67` |
| `MeetingApp` | zoom `us.zoom.xos`, googleMeet `com.google.Chrome`, teams `com.microsoft.teams` | `MeetingDetector.swift:9-21` |
| `RecordingError`, `TranscriptionError` | error enums with user-facing strings | `AudioRecorder.swift:772-808`, `TranscriptionEngine.swift:200-221` |

## 5. Audio pipeline

### 5.1 Capture
- Microphone: `AVAudioEngine` input node, tap on bus 0 with buffer size 4096 at the node's native format (`AudioRecorder.swift:385-454`). Stereo is averaged to mono; mono uses channel 0 (:478-487). Rate is whatever the hardware reports; fallback 48 kHz mono if both format queries return 0 (:432-440).
- Voice processing (AEC, noise suppression, AGC) is enabled only when system audio capture is off, because it degraded system audio (:395-415, RFC-001:1546-1554). In dual mode there is no echo cancellation, so speaker bleed into the mic is not handled (**inferred**).
- System audio: `CATapDescription(stereoGlobalTapButExcludeProcesses: [])` with `.unmuted` (:197-199). This taps all system output, not just Zoom or Chrome, and does not exclude Alona. A private aggregate device named "Alona-Tap-Only" holds only the tap, with drift compensation off (:221-237). An IOProc on a user-initiated queue receives interleaved Float32 (:258-264). The tap's `kAudioTapPropertyFormat` provides rate and channels (`CoreAudioUtils.swift:103-105`).
- System buffers are downmixed to mono by `(L+R)/2` and linearly resampled to the mic rate per callback buffer (:284-329, :332-355). No anti-alias filter.
- Meeting detection uses a different CoreAudio call: process list with `kAudioProcessPropertyIsRunningInput` and `BundleID` (`CoreAudioUtils.swift:76-91`, `MicrophoneActivityTracker.swift:56-74`).

### 5.2 Mixing and file output
- Two `[Float]` arrays (mic, system) on a serial `bufferQueue` (:45, :61-62). Every append calls `flushBuffersIfNeeded` (:524-542). In dual mode it writes only when both have at least one second of samples (rate x 1), writing `min(count)` frames. In mic-only mode the mic samples are also appended to the system array so both channels carry the mic (:493-497).
- Pairing is by sample count and arrival order, not timestamps (:538-540, :589-617).
- `writeSamples` fills a 2-channel Float32 non-interleaved buffer (ch0=system, ch1=mic) and writes to `recording.wav` (:589-617). `removeFirst(count)` trims both arrays.
- On stop, leftover samples are written; a missing side is copied from the other, or zero-padded (:544-587).
- `createMonoMix` reads the whole stereo file into one buffer, averages the channels, converts to 16 kHz with `AVAudioConverter` in a single call, and writes `recording-mono.wav` (:631-735).

### 5.3 What Whisper receives
`TranscriptionEngine.convertAudioToPCM` reads `recording-mono.wav` fully, converts again to 16 kHz mono Float32 (a no-op at that point), and returns one `[Float]` (`TranscriptionEngine.swift:158-197`). `whisper.transcribe(audioFrames:)` (SwiftWhisper) runs with default parameters; no language, threads, or prompt are set (:61). The model is loaded lazily and held until unload (:145-156, :74-99).

### 5.4 Playback
`AVAudioPlayer` on `recording.wav` (stereo, so L=system R=mic play as left and right) (`RecordingAudioPlayer.swift:16-19`, `MeetingFileManager.swift:159-169`).

## 6. Screens and windows

| Window | Type and size | Content and controls | Cite |
|--------|---------------|----------------------|------|
| Startup | default `WindowGroup`, content-sized, min 440x420; Cmd+N removed | Hero status card (tap toggles recording; red pulse and mm:ss when recording; orange when meeting detected); detection card with Record and Dismiss; nav cards Recordings, Settings, Queue; Permissions button; Current Notes button while recording; footer with model status plus Download and a 4-row permission list | `StartupView.swift`, `AlonaApp.swift:54-69` |
| Menu bar extra | `MenuBarExtra` `.window` style, 300 pt wide, SF Symbol `note.text` | Header "Alona" plus status; orange or red card with Start or Stop Recording while detected or recording; "Recent Recordings" (3, links to browser); footer Recordings, Startup, Quit (Cmd+Q). Syncs `appState.meetingTitle` from detector. | `MenuBarView.swift`, `AlonaApp.swift:73-80` |
| Meeting popup | borderless `NSWindow`, floating, all Spaces, 340x80, top-right of main screen | Video icon, "Meeting Detected: <title>", Ignore, Record; 7 s auto-dismiss | `MeetingPopupWindow.swift`, `MeetingDetectedPopup.swift` |
| System notification | `UNUserNotification` | Title "<App> meeting detected"; body names the meeting; action "Start Recording" | `MeetingNotificationManager.swift:30-44, 63-74` |
| Meeting notes | `WindowGroup id: meeting-notes`, default 420x380, min 480x400 | Recording status bar with Stop; editable title; date; toolbar Timestamp, Bullet, Action; editor; word count; static "Auto-saved" | `MeetingNotesView.swift`, `AlonaApp.swift:90-96` |
| Recordings | `WindowGroup id: recordings`, default 700x420, `NavigationSplitView` | Sidebar list plus refresh; detail with title, audio, transcript (Regenerate), notes editor | `RecordingsBrowserView.swift`, `AlonaApp.swift:98-104` |
| Settings | `WindowGroup id: settings-window`, fixed 700x500 | General and Transcription Models tabs (Section 2.10) | `SettingsView.swift` |
| Transcription queue | `WindowGroup id: transcription-queue`, 480x420, min 460x420 | Job list with state, progress, error, Cancel | `TranscriptionQueueView.swift` |
| Onboarding / Permissions | `WindowGroup id: onboarding`, min 420x420 | Four permission rows; Refresh and Close | `OnboardingView.swift` |
| `TranscriptionProgressView` | not a window; component | Never instantiated anywhere. Its copy says "Generating placeholder summary" (:108). | `TranscriptionProgressView.swift` |

Window reuse: `WindowFocusController` tags each `NSWindow` with an identifier and focuses an existing window instead of opening a duplicate (`StartupWindowController.swift:5-33, 55-78`). Design tokens (colors, 4 pt spacing, radii, icon sizes, 1.2 s pulse) are in `Alona/DesignSystem.swift`; they match `docs/design_system/design_system_guidelines.md` (primary #388E3C, recording #FF3B30, detected #FF9500, success #34C759, transcription #C0CA33). Mockup PNGs in `docs/design_system/` predate the palette change (guidelines:110).

## 7. Platform-specific pieces that cannot port as-is

| Piece | What it does for the user | Cite |
|-------|---------------------------|------|
| CoreAudio process tap plus private aggregate device | Records what the user hears from other participants without a virtual driver or a screen-share indicator | `AudioRecorder.swift:192-282` |
| Private TCC SPI (`dlopen` of TCC.framework) | Shows and requests "System Audio Recording" status accurately | `PermissionManager.swift:279-318` |
| CoreAudio per-process input-running flag | Primary signal that Zoom is in a call, works without Accessibility | `MicrophoneActivityTracker.swift:56-74` |
| Accessibility plus AppleScript to System Events | Detects Zoom's "Leave Meeting" menu when the mic is muted | `MeetingDetector.swift:305-343` |
| AppleScript to Chrome | Finds the Meet tab and its title | `MeetingDetector.swift:209-238, 350-377` |
| `NSWorkspace` running-app list and activation notifications | Knows whether Zoom or Chrome is running | `MeetingDetector.swift:51-58, 177-180` |
| `AVAudioEngine` voice processing | Echo cancellation for mic-only recording | `AudioRecorder.swift:399-415` |
| `MenuBarExtra`, Dock icon, `NSStatusItem`-style window | Always-available control and recent list | `AlonaApp.swift:73-80` |
| Borderless floating `NSWindow` | Granola-style detection popup over other apps | `MeetingPopupWindow.swift:34-59` |
| `UNUserNotificationCenter` actionable notification | Start recording from a banner | `MeetingNotificationManager.swift` |
| System Settings deep links (`x-apple.systempreferences:`) | Jump to the right privacy pane | `PermissionManager.swift:17-30` |
| `NSTextView` bridge | Cursor-aware snippet insertion | `MeetingNotesView.swift:229-290` |
| SwiftWhisper (whisper.cpp bindings, `master` branch, pinned by revision `c340197`) | On-device speech to text | `Package.swift:17`, `Package.resolved` |
| UserDefaults, `~/Documents`, `~/Library/Application Support` | Settings and storage paths | Section 4 |

## 8. Known defects, TODOs, and risky areas

Severity is my judgment. D-numbers are referenced above.

| ID | Issue | Cite | Notes |
|----|-------|------|-------|
| D1 | User never sees recording or post-processing errors | `AppState.swift:141, 156-157, 258, 391, 401`; no view reads `recordingError` | High. A failed start (permission, device) looks like nothing happened. |
| D2 | Transcription ignores the selected model. `loadModelIfNeeded` iterates `WhisperModel.allCases` and takes the first file found (tiny.en first); `loadModel(for:)` has no caller | `TranscriptionEngine.swift:145-156, 130-143`; callers: none | High. A user with turbo selected and tiny.en also downloaded gets tiny.en. |
| D3 | Download validates nothing: no HTTP status check, no size or hash check; an error page saved by `didFinishDownloadingTo` would be marked available. No resume. New `URLSession` per download, never invalidated | `ModelManager.swift:436-439, 598-615` | High. **Inferred** for the error-page case. |
| D4 | TLS challenge handler returns `.useCredential` with the server's own trust without evaluating it, which disables certificate validation for the model download | `ModelManager.swift:682-694` | High (security). Whisper weights are loaded into native code afterwards. |
| D5 | Summary is a placeholder and `summary.md` is never shown | `SummaryManager.swift:19-40`; no readers | Known. README flags it. |
| D6 | Teams is declared but not implemented | `MeetingDetector.swift:12` | Low. |
| D7 | Zoom permission-denied flag is overwritten by the Meet branch, so the hint rarely shows | `MeetingDetector.swift:118-134` | Low. `automationPermissionDenied` has no reader in `Views/` either. |
| D8 | `NSAppleScript` is run on detached background tasks. Apple documents it as main-thread only | `MeetingDetector.swift:220-221, 313-314`, `PermissionManager.swift:141-142` | Medium. RFC-001:1215-1218 moved it off main to avoid UI freezes; stability **unverified**. |
| D9 | Detection polls have no in-flight guard. Each 2 s tick spawns a detached task; a slow AppleScript (many Chrome tabs, or Zoom menu scripting) can overlap | `MeetingDetector.swift:60-84` | Medium. Also Zoom UI probe runs every 2 s whenever Zoom is running and the mic is idle. |
| D10 | Partial-start leak. If the system tap fails after the mic engine and WAV were started, the error propagates without stopping the engine or deleting the empty folder | `AudioRecorder.swift:98-106` | Medium. `isRecording` stays false while `AVAudioEngine` keeps running (**inferred**). |
| D11 | Unbounded in-memory audio. Dual mode writes only when both buffers have 1 s; if the tap delivers no callbacks (for example no audio playing), the mic buffer is never flushed until stop | `AudioRecorder.swift:524-542` | High risk, **unverified** whether the tap emits silent buffers. |
| D12 | Stop-time memory spike. `createMonoMix` loads the full stereo file and allocates a mono copy and a resampled copy. 48 kHz stereo Float32 is about 384 KB/s, roughly 1.4 GB per hour, plus about 0.7 GB intermediate. Transcription then reads the 16 kHz file again (about 230 MB per hour) | `AudioRecorder.swift:646-662, 665-679`, `TranscriptionEngine.swift:159-196` | High for long meetings. Arithmetic is mine. |
| D13 | Stop blocks on the mono mix; errors in it are swallowed (`try?`), and then transcription fails on a missing file | `AudioRecorder.swift:155-157`, `AppState.swift:370` | Medium. |
| D14 | Mic and system tracks are paired by sample count with per-buffer linear resampling that truncates `Int(count*ratio)`. Drift and clicks are possible when rates differ | `AudioRecorder.swift:314-318, 338-340, 538-540` | Medium, **inferred**. No timestamp alignment. |
| D15 | Global tap captures all apps' audio (music, notifications), and no exclusion of Alona's own sound | `AudioRecorder.swift:197` | Medium (privacy and transcript quality). |
| D16 | Duration is a 1 s tick counter, not wall clock or audio length. Ticks can be missed when the main run loop is busy. Notes timestamps use it | `AudioRecorder.swift:176-183`, `MeetingNotesView.swift:197-200` | Low. |
| D17 | Cancelling an active job cannot interrupt Whisper | `AppState.swift:200-203, 374` | Medium, **inferred**. |
| D18 | Transcription queue and job history are in memory only and never pruned; a quit during processing leaves a folder with audio and no transcript, and nothing resumes it | `AppState.swift:23, 278` | Medium. |
| D19 | Notes recovery never works (fresh folder per recording); orphaned `notes.tmp` after a crash has no UI or launch scan. A crash mid-recording may leave a WAV with an unfinalised header (**unverified**) | `AppState.swift:130`, `MeetingFileManager.swift:56-76` | Medium. |
| D20 | `lastSavedNotesDraft` is not reset per recording, so first notes equal to the previous meeting's last saved text skip autosave | `AppState.swift:223, 49` | Low. |
| D21 | Recordings notes editor writes `notes.md` synchronously on the main thread on every change, including when selection changes reload the text; a stale-closure cross-write to the wrong folder is possible (**unverified**) | `RecordingsBrowserView.swift:263-278` | Medium. Comment says "debounced"; it is not. |
| D22 | `meetingEntries()` scans the folder and reads each `title.txt` on the main thread at each open and menu appearance; cost grows with meeting count | `MeetingFileManager.swift:125-145`, `MenuBarView.swift:194-196`, `RecordingsBrowserView.swift:308-317` | Low now, grows. |
| D23 | Popup can show during an active recording, and a stale 7 s timer from an earlier popup can dismiss a newer one | `MeetingDetector.swift:241-258`, `MeetingDetectedPopup.swift:83-85` | Low. |
| D24 | `MenuBarView.syncMeetingTitleFromDetector` overwrites `appState.meetingTitle` during recording, so the notes title field shows the detector title while `title.txt` keeps the user's edit | `MenuBarView.swift:233-239` | Low. |
| D25 | Accessibility prompt fires on every launch until granted, before the user sees any explanation | `AppDelegate.swift:35-39` | Low (UX). |
| D26 | Dead code: `ProcessTap`, `ProcessTapRecorder`, `AudioCapturePermission` (behind `ENABLE_TCC_SPI`, which no build file defines), `TranscriptionProgressView`, `AppState.showOnboarding`, `notesAutosaveScheduler` parameter, `Package.swift` source path `Utilities` which does not exist | `ProcessTap.swift`, `AudioCapturePermission.swift`, `AppState.swift:11, 43`, `Package.swift:40` | Remove, do not port. |
| D27 | `AudioRecorder.captureSystemAudio` defaults true but `AppState` forces false on init, so true defaults appear only in tests that construct `AudioRecorder` directly | `AudioRecorder.swift:32`, `AppState.swift:77-79` | Low. |
| D28 | SwiftWhisper is tracked by branch `master`. Whether its vendored whisper.cpp reads the `large-v3-turbo` and q5 ggml files is not established here | `Package.swift:17` | **Unverified**; check before choosing a runtime. |
| D29 | `Task.sleep`-based unload timer code path is redundant: models unload as soon as the queue drains | `AppState.swift:285-287`, `TranscriptionEngine.swift:101-115` | Low. Reload cost on every batch. |
| D30 | Main-thread work in `startRecording`: folder creation, `AVAudioEngine` start with optional voice processing, and tap creation all run on `@MainActor` | `AudioRecorder.swift:80-120` | Low to medium. |

## 9. Behaviour the tests pin

115 test functions in 10 files (counted by grep, not run). The ones a rewrite should keep as acceptance cases:
- Folder naming, collision suffix, special characters, 300-character titles, empty title, Unicode title, missing metadata files (`MeetingFileManagerTests.swift:7-19, 114-167, 191-203`).
- `notes.tmp` draft, then `notes.md` removes the draft (:21-38, `AppStateTests.swift:219-254`).
- Transcript JSON round trip and plain-text join (`MeetingFileManagerTests.swift:40-63`).
- Meeting list sorted newest first; saved titles override folder names (:65-92).
- `recording.wav` preferred over `recording-mono.wav` for playback (:94-107).
- Notification de-duplication by `app|title`; re-notify after clear (`MeetingDetectorTests.swift:21-65`).
- Title normalization strips " - Google Meet" and falls back to "Google Meet" (:13-19).
- Autosave skips duplicate content; capture-system-audio persists; timestamp title fallback format `MMM d, yyyy 'at' h:mm a` (`AppStateTests.swift:74-100, 148-170, 389-441`).
- Job queue reaches `completed` for manual and automatic jobs (:119-146, :359-387).
- Placeholder summary structure and 200-character truncation (`SummaryManagerTests.swift:36-84`).
- Resampler behaviours: down, up, same rate, empty, invalid (`AudioTests.swift:111-195`).
- Model catalog: default, sizes, file names, URLs, quantized and multilingual flags, 11 cases (`TranscriptionTests.swift:93-157`).

## 10. Not determined

- Whether the process tap delivers callbacks during silence (D11).
- Whether `NSAppleScript` off the main thread is stable in practice (D8).
- Whether the bundled whisper.cpp supports large-v3-turbo and q5 models (D28).
- Whether a crashed recording leaves a playable WAV (D19).
- Actual transcription speed, memory use, and model-load time. Table 4.3 labels are hard-coded.
- Entitlements and signing setup. No `.entitlements` file was found; release signing and notarization are not in the repo.
- Whether the notes window opens when both Startup and the menu bar popover are closed (Section 2.4).
- Content of `docs/prompts/` and `docs/research/` (not in the requested read list).
