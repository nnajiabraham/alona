# Alona macOS MVP – Product Requirements Document

**Status:** Draft • 2025-11-27  
**Owner:** Abraham Nnaji  
**Reference Apps:** Granola (meeting-first AI notepad)[^granola]

---

## 1. Background
Knowledge workers with back-to-back calls rely on tools like Granola for transcription and note clean-up, but cloud bots and remote processing introduce privacy risk, latency, and compliance blockers.[^granola] Alona targets macOS users who prefer fully local capture, transcription, and note organization without meeting bots.

## 2. Objectives & Success Criteria
### 2.1 Goals
1. Detect Zoom or Google Meet sessions (automatic and manual start) and create a meeting workspace instantly.
2. Record system audio locally, transcribe it with the bundled SwiftWhisper (whisper.cpp) engine for a truly self-contained MVP, and bucket every artifact (audio, notes, transcript, enhanced summary) into a user-chosen directory tree. Phase 2 introduces the MLX-converted `mlx-community/parakeet-tdt-0.6b-v3` model for higher fidelity once the Swift port is battle-tested.[^swiftwhisper][^mlxparakeet]
3. Provide an always-on note pane tied to the active recording session, persisting drafts even if the call drops unexpectedly.
4. After each session, auto-run: audio-to-text, summary generation stub, and folder housekeeping—no manual export steps.

### 2.2 Non-goals (MVP)
- Speaker diarization, sentiment tagging, or call analytics beyond transcript text.
- Video capture or screen recording.
- Multi-user sync, cloud backup, or collaboration features.

### 2.3 Success Metrics
- **Detection latency:** <5 seconds from meeting start to recording prompt.
- **Transcription kickoff:** ≤30 seconds after audio file close.
- **Storage guarantees:** 100% of sessions create `audio.wav`, `notes.md`, `transcript.json`, `summary.md` files inside the meeting folder.
- **User trust:** clear permission prompts for Accessibility, Screen Recording, and Microphone; zero outbound traffic except optional Phase 2 LLM calls.

---

## 3. User Personas & Journeys
| Persona | Needs | Pain Today |
| --- | --- | --- |
| "Research PM" | capture insights from 8+ vendor calls/day, search later | Cloud meeting bots blocked by security, transcription delays |
| "Consultant" | fast recap for follow-up emails, offline flights | Manual exports from Zoom, scattered notes |
| "Founder" | want minimal overhead, prefer local AI | Tools like Granola require cloud, can't run offline |

**Primary Journey:**  
1. Launches Alona, sets default "Meeting Vault" directory.  
2. Joins Zoom → Alona detects `zoom.us` process, opens mini window with session title, timer, note field.  
3. Recording auto-starts (user can pause).  
4. During call, user types quick bullets; autosave occurs every 2 seconds.  
5. Call ends / user clicks stop → app closes audio stream, writes `YYYYMMDD-HHMM-<title>/raw/audio.wav`.  
6. Background job: run Parakeet transcription, produce JSON+text; stub summary run writes placeholder markdown.  
7. Finder notification links to the folder; user can reopen workspace later.

---

## 4. Functional Requirements
1. **Default Save Location UI**: picker + validation, fallback to `~/Documents/Alona`.
2. **Meeting Detection**:
   - Multi-signal pipeline: (a) `NSWorkspace` notifications/watchdogs to observe `zoom.us` lifecycle events, (b) 2 s timer that probes `lsof -i 4UDP -p <pid>` to confirm Zoom is exchanging media, (c) Accessibility + AppleScript queries that read Chromium/Safari tab URLs for `meet.google.com`, and (d) manual "New Session" entry for unsupported tools.[^nsworkspace]
   - Onboarding checklist guides users through granting Accessibility + Automation permissions so the heuristics stay reliable.
3. **Recording Pipeline**:
   - System audio: subscribe to the meeting window via `ScreenCaptureKit` and write a 16 kHz mono WAV suitable for MLX inference; fall back to a bundled BlackHole Multi-Output device when Screen Recording permission is unavailable.[^screencapture][^blackhole]
   - Microphone audio: run `AVAudioEngine` taps on the default input, optionally write dual-channel WAVs (Ch1 system, Ch2 mic) before downmixing for transcription.[^avfoundation]
   - Provide visible state (menu bar indicator, pause/resume, timer) whenever either capture path is active.
4. **Notes Surface**:
   - Rich-text-lite editor (Markdown subset) with autosave drafts to `notes.tmp` and final `notes.md` on stop.
5. **Transcription Job**:
   - After recording, invoke the bundled SwiftWhisper (whisper.cpp) engine with a default `ggml-base.en` checkpoint to produce `.json` (timestamps) and `.txt` artifacts entirely offline—no Python runtime required.[^swiftwhisper]
   - Settings expose model-size tradeoffs (tiny/base/small) plus an opt-in preview flag for the future MLX Parakeet port; the transcript schema stays identical so summaries remain engine-agnostic.[^mlxparakeet]
6. **Enhanced Summary Stub**:
   - Call `generateEnhancedSummary(sessionId)` that currently writes deterministic dummy data (timestamp + placeholder).  
   - Provide "Regenerate" button; future integration can call LM Studio or remote OpenAI.
7. **Folder Layout**:
   - Every session creates a single flat folder named `YYYY-MM-DD_HHMM_<slug>/` (e.g., `2025-11-27_1030_Product-Sync/`) so multiple meetings per day never collide.
   - Files inside the folder stay at the root for easy Finder browsing:
     ```
     recording.wav          # dual-channel (system + mic) PCM WAV
     recording-mono.wav     # downmixed copy handed to the transcription worker
     notes.md               # final notes (autosave temp lives in same folder)
     transcript.txt         # human-readable text
     transcript.json        # structured segments with timestamps
     summary.md             # enhanced summary (placeholder in MVP)
     ```
8. **Settings & Permissions**: wizard to request Accessibility, Automation, Screen Recording, Microphone, plus toggles for auto-start, push notifications, and model selection; surface Info.plist copy so users understand each entitlement.
9. **UI Shell**: menu bar extra for status/actions, floating notes window that opens when a session starts, Finder quick links, and autosave cadence controls mirrored from the Claude/Gemini explorations.
10. **Error Handling**: inline toasts for detection failures, permission issues, transcription crashes.

---

## 5. Technical Approach & Research
### 5.1 Platform Choice
- **Swift/SwiftUI** (primary): direct access to `NSWorkspace`, `ScreenCaptureKit`, and sandbox entitlements with minimal bridging overhead; aligns with System Settings UI patterns.[^swiftui]
- **React Native macOS** is possible but would require handwritten native modules for detection, audio graph management, and GPU-accelerated ASR, negating the speed advantage. Recommendation: native Swift for MVP; revisit RN shell only if future cross-platform goals emerge.

### 5.2 Meeting Detection Layer
- `NSWorkspace` notifications + `NSRunningApplication` metadata detect Zoom lifecycle changes, while a watchdog timer re-polls every 2 s so transient foreground switches do not hide meetings.[^nsworkspace]
- When Zoom is running, `lsof -i 4UDP -p <pid>` verifies the process has active RTP flows before auto-starting a recording, reducing false positives.
- For Google Meet, Accessibility + AppleScript queries inspect Chrome/Safari tab URLs (`meet.google.com/*`), and we log when Automation permission is missing so the UI can fall back to manual start.
- Manual overrides (Start/Pause/Stop) remain visible so users can recover from edge cases or support additional vendors (Teams, Webex, Slack huddles).

### 5.3 Audio Capture & Storage
- `ScreenCaptureKit` streams provide per-app audio taps without virtual drivers on macOS 12.3+, letting us isolate the Zoom/Meet window audio and encode 16 kHz mono WAVs tailored for MLX ASR.[^screencapture]
- Microphone capture uses `AVAudioEngine` taps so we can save dual mono channels (system, mic) into `recording.wav` while also writing `recording-mono.wav` for the transcription worker.[^avfoundation]
- For machines without Screen Recording permission or on older OS releases, a helper walks users through installing the open-source BlackHole driver, creating a Multi-Output/Aggregate device, and selecting it inside the app so recordings still include remote audio.[^blackhole]
- Keeping everything flat inside `YYYY-MM-DD_HHMM_<slug>/` folders keeps Finder navigation simple while still preserving the richer dual-channel source for future diarization.

### 5.4 Note Editor & UI Shell
- Menu bar extra hosts quick actions (Start/Pause, open Notes window, open Settings) and the status indicator (idle vs recording) so the app is usable even when all windows are closed.
- When a session begins, a floating SwiftUI window opens with timeline badges, note editor, and insert buttons (timestamp, bullet) and autosaves drafts every 2 s to `notes.tmp` before committing `notes.md` on stop.
- Plain-text Markdown storage keeps the “vibe coding” workflow transparent; no database migrations are required for MVP, but the file manager emits change events so future Spotlight/QuickLook plugins can index them.

### 5.5 Transcription Service
- MVP ships SwiftWhisper (Swift bindings around whisper.cpp) plus curated `ggml` weights (`tiny.en`, `base.en`, `small.en`). This keeps the app self-contained—no Python, Conda, or external scripts—while delivering proven on-device accuracy on Apple silicon.[^swiftwhisper]
- The transcription worker converts the recorded WAV to 16 kHz mono (if needed), streams frames into SwiftWhisper, and emits standardized `.json` + `.txt` outputs with segment-level timestamps. Progress is surfaced in the UI with cancel/retry semantics.
- Phase 3 in the delivery plan introduces an opt-in MLX Parakeet backend: we bundle `mlx-community/parakeet-tdt-0.6b-v3` weights plus `parakeet-mlx` binaries and gate them behind a “High Fidelity (Preview)” toggle. Both engines implement the same `TranscriptionProvider` protocol so switching simply swaps implementations.[^mlxparakeet]
- Future work can re-enable NeMo Python runners for users with remote NVIDIA GPUs, but the primary story remains fully local on Apple silicon.

### 5.6 Enhanced Summary Mechanism (Phase 2 ready)
- Define `SummaryProvider` protocol with implementations:
  - `DummySummaryProvider` (MVP) writes deterministic sample text.
  - `LMStudioProvider` hitting the OpenAI-compatible local endpoint `http://localhost:1234/v1/chat/completions` when LM Studio server is running.[^lmstudio]
  - Future `RemoteLLMProvider` for OpenAI/Claude.
- Store summary metadata (model, timestamp, prompt) alongside markdown content for auditing.

### 5.7 Security & Privacy
- Entitlement prompts describe data flows; no background network calls besides optional summary providers.
- Configurable retention policy (auto-delete after N days) stored in preferences.
- Provide single-click "Reveal in Finder" to reassure data locality.

---

## 6. Delivery Plan

**Implementation RFC:** [RFC-001: Alona MVP Full Implementation](./rfcs/RFC-001-alona-mvp-full-implementation.md)

| Phase | Scope | Key Deliverables |
| --- | --- | --- |
| **0 – Repo & Research (complete)** | Git init, README, PRD | This document. |
| **1 – Detection & Permissions** | Multi-signal detector + onboarding | RFC + service for Zoom/Meet detection, permission checklist UI, manual session start. |
| **2 – Audio Graph & Notes Shell** | Recording + file scaffold | ScreenCaptureKit + AVAudioEngine services, BlackHole fallback guide, menu bar + notes window, autosave + folder writer. |
| **3 – Transcription Loop** | SwiftWhisper MVP + MLX preview toggle | Bundled SwiftWhisper weights, background job queue, progress UI, schema-aligned transcript files, optional MLX Parakeet preview bundle. |
| **4 – UX Polish & Notifications** | Settings, alerts, Finder surfacing | Settings window, onboarding checklist, Finder reveal + notifications, keyboard shortcuts. |
| **5 – LLM Integrations (stretch)** | Real enhanced summaries | LM Studio + OpenAI clients, provider switching, telemetry. |

The single RFC covers all phases with a phased checklist. Each phase builds on the previous.

---

## 7. Risks & Mitigations
| Risk | Impact | Mitigation |
| --- | --- | --- |
| System audio capture blocked (no ScreenCaptureKit permissions) | Cannot record output audio | Fallback to BlackHole driver install guide + permission checker UI. |
| MLX Parakeet inference is resource-heavy | Lower-tier Macs may transcribe slowly | Surface hardware guidance, allow SwiftWhisper fallback, throttle concurrent jobs. |
| Meeting heuristics misfire (false positives) | Start recording at wrong time | Provide manual confirm toast + kill switch; log telemetry locally for tuning. |
| Storage bloat | Disk pressure | Show per-meeting sizes, allow auto-delete raw audio older than configurable threshold. |

---

## 8. Open Questions
1. Do we need video capture or screen snapshots for context? (requires Screen Recording entitlements + storage.)
2. When we enable the MLX Parakeet preview, should we bundle the safetensors inside the `.app` or download them on demand to keep the installer lean?
3. How to detect Google Meet reliably inside browsers without violating sandbox rules? Possibly use Chrome DevTools Protocol when user grants permission.
4. Should auto-summary run for very short (<2 min) sessions?

---

## 9. References
- Granola product positioning.[^granola]
- Apple AVFoundation audio APIs.[^avfoundation]
- `NSWorkspace` notifications for detecting running apps.[^nsworkspace]
- ScreenCaptureKit for app-level audio capture on macOS.[^screencapture]
- BlackHole virtual audio driver for legacy fallback.[^blackhole]
- NVIDIA NeMo Parakeet ASR usage examples.[^nemo]
- LM Studio OpenAI-compatible local API.[^lmstudio]
- SwiftUI docs for native macOS UI guidance.[^swiftui]

---

[^granola]: Granola AI – "The AI notepad for people in back-to-back meetings" https://www.granola.ai/
[^avfoundation]: Apple Developer Documentation – AVFoundation framework overview https://developer.apple.com/documentation/avfoundation
[^nsworkspace]: Apple Developer Documentation – `NSWorkspace` notifications https://developer.apple.com/documentation/appkit/nsworkspace
[^screencapture]: Apple Developer Documentation – ScreenCaptureKit https://developer.apple.com/documentation/screencapturekit
[^blackhole]: BlackHole virtual audio driver (macOS) https://github.com/ExistentialAudio/BlackHole
[^nemo]: NVIDIA NeMo Parakeet ASR usage (timestamps, pretrained load) https://github.com/NVIDIA/NeMo/blob/main/docs/source/asr/intro.rst
[^lmstudio]: LM Studio OpenAI-compatible API docs https://lmstudio.ai/docs/developer/openai-compat
[^swiftui]: Apple Developer Documentation – SwiftUI overview https://developer.apple.com/documentation/swiftui
[^mlxparakeet]: MLX community conversions of NVIDIA Parakeet TDT checkpoints for Apple silicon https://huggingface.co/mlx-community/parakeet-tdt-0.6b-v3
[^swiftwhisper]: SwiftWhisper (whisper.cpp bindings) for on-device transcription https://github.com/exPHAT/SwiftWhisper
