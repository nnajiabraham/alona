# Gemini Plan: Local-First Meeting Assistant (Granola Alternative)

## 1. Executive Summary

This document outlines the plan to build a local-first macOS application inspired by Granola. The app will automatically detect Zoom and Google Meet calls, record system audio and microphone locally, transcribe the audio using a high-performance local model, and allow the user to take notes. All data will be stored locally in a structured format.

**Core MVP Features:**
*   **Automatic Detection:** Detects active Zoom or Google Meet calls (via Accessibility API/Window detection).
*   **Local Recording:** Captures system audio (the meeting) and user microphone without third-party audio drivers (using `ScreenCaptureKit`).
*   **Local Transcription:** Uses `whisper.cpp` (via `SwiftWhisper`) for high-performance, offline transcription on Apple Silicon. *Note: Replaces NVIDIA Parakeet which requires CUDA/NVIDIA GPUs.*
*   **Notes Interface:** Simple UI for user notes during calls.
*   **Artifact Management:** Saves audio, notes, and transcripts to a user-defined directory.
*   **Enhanced Summary:** Placeholder mechanism for LLM-based summarization (local or remote).

---

## 2. Technology Stack & Trade-offs

### 2.1 Selected Stack: Native Swift + SwiftUI
*   **Language:** Swift 5+
*   **UI Framework:** SwiftUI
*   **Audio Capture:** `ScreenCaptureKit` (MacOS 12.3+) for system audio; `AVFoundation` for microphone.
*   **Transcription:** `SwiftWhisper` (binding for `whisper.cpp`) - Optimized for Apple Silicon (CoreML/Metal).
*   **State Management:** `Observation` framework or `Combine`.

### 2.2 Why not React Native?
While React Native was requested as a preference, it is **not recommended** for this specific MVP for the following reasons:
1.  **System Audio Capture:** Capturing system audio on macOS natively requires `ScreenCaptureKit`. There are no mature React Native bridges for this specific, complex API. You would have to write the native Swift module anyway.
2.  **Background Processes:** Reliable meeting detection (monitoring window titles/processes) is a system-level background task best handled natively.
3.  **Performance:** Real-time audio buffer handling and passing to a local C++ inference engine (`whisper.cpp`) introduces significant bridge overhead in RN. Native Swift provides direct memory access.

**Conclusion:** "Vibe coding" (rapid iteration) will actually be *faster* in Swift because you have direct access to the required APIs (SCK, Accessibility) without fighting the bridge.

---

## 3. Architecture

The app will follow a modular Service-Manager architecture.

### 3.1 Core Services
1.  **`MeetingDetectorService`**:
    *   Monitors `NSWorkspace` for active applications (Zoom, Chrome).
    *   Uses Accessibility API (`AXUIElement`) to read window titles (e.g., "Zoom Meeting").
    *   Publishes `MeetingStatus` (Active/Inactive).
2.  **`AudioRecorderService`**:
    *   Manages `SCStream` (ScreenCaptureKit) to capture system audio.
    *   Manages `AVCaptureSession` or `AVAudioEngine` for Microphone.
    *   Mixes channels (optional) or saves as multi-channel WAV.
3.  **`TranscriberService`**:
    *   Wraps `SwiftWhisper`.
    *   Queues audio chunks or processes the final WAV file post-meeting.
4.  **`StorageManager`**:
    *   Manages directory creation: `~/Documents/Meetings/{YYYY-MM-DD_HH-mm}_{MeetingTitle}/`.
    *   Saves `audio.wav`, `notes.txt`, `transcript.txt`, `summary.md`.

---

## 4. Implementation Plan

### Phase 1: Setup & Detection (Day 1)
*   **Project Init:** Create macOS App (AppKit/SwiftUI).
*   **Permissions:** Add `Privacy - Microphone Usage`, `Privacy - Accessibility Usage` (for window titles), and `Screen Recording` entitlements.
*   **Detection Logic:**
    *   Poll running apps or subscribe to `NSWorkspace.didLaunchApplicationNotification`.
    *   If Zoom is open, poll active window titles. If title contains "Meeting", trigger "Active".

### Phase 2: Audio Recording (Day 2)
*   **System Audio:** Use `ScreenCaptureKit`.
    *   Create `SCContentFilter` for the specific app (Zoom) or all system audio.
    *   Create `SCStream` with `.audio` enabled.
*   **Mic Audio:** Use `AVAudioEngine` input node.
*   **File Writing:** Write buffers to `ExtAudioFile` or `AVAudioFile` in the specific meeting folder.

### Phase 3: Transcription (Day 3)
*   **Integration:** Add `SwiftWhisper` via SPM (`https://github.com/exPHAT/SwiftWhisper`).
*   **Model:** Download `ggml-base.en.bin` (or small/medium) to `Application Support`.
*   **Logic:** On meeting end, pass the saved WAV file to `whisper.transcribe(fileURL: ...)`.

### Phase 4: UI & Glue (Day 4)
*   **Main Window:**
    *   Sidebar: List of past meetings (read from folders).
    *   Detail View: Notes editor, Playback, Transcript view.
*   **Menubar / Overlay:**
    *   Small floating window or Menu Bar icon showing "Recording" state + Quick Note input.

### Phase 5: Enhanced Summary (Day 5)
*   **Dummy Implementation:**
    *   Create `SummaryService`.
    *   `func generateSummary(transcript: String) -> String`
    *   MVP: Returns hardcoded "Summary: [TODO: Connect LLM]\n - Point 1\n - Point 2".
    *   Saves to `summary.md`.

---

## 5. Dependencies & Tools

| Feature | Tool/Library | Context7 ID | Notes |
| :--- | :--- | :--- | :--- |
| **Transcription** | **SwiftWhisper** | `/exphat/swiftwhisper` | Wrapper for `whisper.cpp`. High performance on Apple Silicon. |
| **System Audio** | **ScreenCaptureKit** | Native Framework | Requires macOS 12.3+. High efficiency, no drivers needed. |
| **Detection** | **Accessibility API** | Native Framework | Requires "Accessibility" permission in System Settings. |

## 6. MVP "Vibe Code" Step-by-Step Instructions

To start building this, you can prompt me (your AI Pair Programmer) with these steps:

1.  "Initialize a new macOS SwiftUI app. Add the required Info.plist permissions for Microphone and Apple Events."
2.  "Create a `MeetingDetector` class that prints to console when Zoom is focused."
3.  "Implement `AudioRecorder` using ScreenCaptureKit to capture audio from all running apps."
4.  "Add `SwiftWhisper` and create a test button to transcribe a dummy file."
5.  "Connect them: When Zoom is detected, start recording. When closed, stop and transcribe."

