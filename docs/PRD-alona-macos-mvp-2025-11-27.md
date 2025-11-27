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
2. Record system audio locally, transcribe it with an NVIDIA Parakeet ASR checkpoint, and bucket every artifact (audio, notes, transcript, enhanced summary) into a user-chosen directory tree.
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
   - Listen to `NSWorkspace.didLaunchApplicationNotification` / `didActivateApplicationNotification` to watch for `zoom.us`, Chrome tabs containing `meet.google.com`, Safari, Brave, Edge.[^nsworkspace]
   - Manual "New Session" button for unsupported providers.
3. **Recording Pipeline**:
   - Aggregate mic + system audio using `ScreenCaptureKit` or bundled BlackHole virtual device to tap speaker output.[^screencapture][^blackhole]
   - Provide visible state (Red dot, pause/resume, timer).
4. **Notes Surface**:
   - Rich-text-lite editor (Markdown subset) with autosave drafts to `notes.tmp` and final `notes.md` on stop.
5. **Transcription Job**:
   - After recording, execute NeMo Parakeet checkpoint (default `nvidia/parakeet-tdt-0.6b-v2`) via offline runner; produce `.json` (timestamps) and `.txt` file.[^nemo]
   - Configurable GPU/CPU fallback (warn if device lacks NVIDIA GPU; allow remote Linux box optional later).
6. **Enhanced Summary Stub**:
   - Call `generateEnhancedSummary(sessionId)` that currently writes deterministic dummy data (timestamp + placeholder).  
   - Provide "Regenerate" button; future integration can call LM Studio or remote OpenAI.
7. **Folder Layout**:
   ```
   <root>/2025/11/27/<meeting-slug>/
     raw/audio.wav
     raw/metadata.json
     notes/notes.md
     transcript/transcript.json
     transcript/transcript.txt
     summaries/summary-v1.md
   ```
8. **Settings & Permissions**: wizard to request Accessibility, Screen Recording, Microphone, plus toggles for auto-start, push notifications.
9. **Error Handling**: inline toasts for detection failures, permission issues, transcription crashes.

---

## 5. Technical Approach & Research
### 5.1 Platform Choice
- **Swift/SwiftUI** (primary): direct access to `NSWorkspace`, `ScreenCaptureKit`, and sandbox entitlements with minimal bridging overhead; aligns with System Settings UI patterns.[^swiftui]
- **React Native macOS** is possible but would require handwritten native modules for detection, audio graph management, and GPU-accelerated ASR, negating the speed advantage. Recommendation: native Swift for MVP; revisit RN shell only if future cross-platform goals emerge.

### 5.2 Meeting Detection Layer
- Use `NSWorkspace` notifications + `NSRunningApplication` metadata to detect Zoom process and frontmost bundle.[^nsworkspace]
- For Google Meet, subscribe to Accessibility events on Chromium browsers (AX notifications) and inspect window titles/URLs. Start with heuristics (window title contains "Meet"), then allow manual override.
- Provide fallback manual start for vendors like Teams/Webex.

### 5.3 Audio Capture & Storage
- `ScreenCaptureKit` streams provide per-app audio taps without virtual drivers on macOS 12.3+.[^screencapture]
- For older releases, ship an optional helper to install the open-source BlackHole virtual audio driver and configure a Multi-Output device so the app can capture system output + mic mix.[^blackhole]
- Use `AVAudioEngine` to route inputs, encode to 16-bit PCM WAV via `AVAudioFile` for compatibility with NeMo preprocessing.[^avfoundation]

### 5.4 Note Editor & UI Shell
- SwiftUI split view: session timeline on the left, editor + live waveform on the right.
- Markdown store backed by CoreData or plain files; prefer plain files for transparency.
- Autosave timer triggered by Combine publisher emitting on text changes.

### 5.5 Transcription Service
- Bundle lightweight Python runtime (e.g., Miniconda env) or require pre-installed conda; launch `python transcribe.py audio.wav --model=nvidia/parakeet-tdt-0.6b-v2`.
- Parakeet RNNT/CTC models expose timestamps by passing `timestamps=True` to NeMo ASRModel inference; we can leverage that for annotated transcripts.[^nemo]
- Provide queue + retry semantics; show progress in UI with log tail.

### 5.6 Enhanced Summary Mechanism (Phase 2 ready)
- Define `SummaryProvider` protocol with implementations:
  - `DummySummaryProvider` (MVP) writes deterministic sample text.
  - `LMStudioProvider` hitting the OpenAI-compatible local endpoint `http://localhost:1234/v1/chat/completions` when LM Studio server is running.[^lmstudio]
  - Future `RemoteLLMProvider` for OpenAI/Claude.
- Store summary metadata (model, timestamp, prompt) alongside markdown content for auditing.

### 5.7 File Organization & Metadata
- Central `manifest.json` per meeting containing:
  ```json
  {
    "id": "2025-11-27-1030-product-sync",
    "title": "Product Sync w/ Acme",
    "participants": ["Abraham", "Michaela"],
    "source": "Zoom",
    "recording": "raw/audio.wav",
    "transcript": "transcript/transcript.json",
    "summary": "summaries/summary-v1.md",
    "tags": ["sales", "acme"],
    "notebookVersion": 1
  }
  ```
- This enables future Spotlight/QuickLook integrations.

### 5.8 Security & Privacy
- Entitlement prompts describe data flows; no background network calls besides optional summary providers.
- Configurable retention policy (auto-delete after N days) stored in preferences.
- Provide single-click "Reveal in Finder" to reassure data locality.

---

## 6. Delivery Plan
| Phase | Scope | Key Deliverables |
| --- | --- | --- |
| **0 – Repo & Research (complete)** | Git init, README, PRD | This document. |
| **1 – Local Capture MVP** | Detection, recording, notes, folder scaffold | SwiftUI shell, detection service, audio graph, manual start, folder writer, tests. |
| **2 – Automation Loop** | Transcription + stub summary | Parakeet runner, job queue, UI statuses, dummy summary + regenerate, error handling. |
| **3 – UX polish & Settings** | Permissions onboarding, notifications, theme | Settings window, onboarding checklist, keyboard shortcuts. |
| **4 – LLM Integrations (stretch)** | Real enhanced summaries | LM Studio + OpenAI clients, provider switching, cost telemetry. |

Each phase should end with an RFC per major subsystem following the existing template.

---

## 7. Risks & Mitigations
| Risk | Impact | Mitigation |
| --- | --- | --- |
| System audio capture blocked (no ScreenCaptureKit permissions) | Cannot record output audio | Fallback to BlackHole driver install guide + permission checker UI. |
| Parakeet models require NVIDIA GPU | Users on Intel/Apple Silicon only | Offer remote GPU host option, consider Whisper for CPU fallback later. |
| Meeting heuristics misfire (false positives) | Start recording at wrong time | Provide manual confirm toast + kill switch; log telemetry locally for tuning. |
| Storage bloat | Disk pressure | Show per-meeting sizes, allow auto-delete raw audio older than configurable threshold. |

---

## 8. Open Questions
1. Do we need video capture or screen snapshots for context? (requires Screen Recording entitlements + storage.)
2. Should we bundle Python/NeMo or guide users through setup? (Impacts notarization size.)
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
