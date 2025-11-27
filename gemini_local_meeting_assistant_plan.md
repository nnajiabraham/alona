# Gemini Plan: Local Meeting Assistant (Native Swift + MLX Parakeet Hybrid)

## 1. Executive Summary

This document outlines the plan to build a local-first macOS application inspired by Granola. The app will automatically detect Zoom and Google Meet calls, record system audio and microphone locally, and transcribe the audio using **NVIDIA Parakeet models on MLX** (via a bundled Python runtime).

**Core MVP Features:**
*   **Automatic Detection:**
    *   **Zoom:** Robust detection via UDP port monitoring (`lsof`) + window title polling.
    *   **Google Meet:** Browser tab detection via AppleScript (Chrome/Safari).
*   **Local Recording:** Captures system audio (meeting output) and user microphone using `ScreenCaptureKit` and `AVFoundation`.
*   **Local Transcription (Hard Requirement):** Uses **NVIDIA Parakeet (TDT 0.6b)** running on Apple Silicon via **MLX**.
    *   *Architecture Decision:* Swift frontend bundles a lightweight Python environment (or manages a user-installed one) to run the MLX inference script as a subprocess.
*   **UI/UX:**
    *   **Menu Bar Extra:** Primary entry point.
    *   **Floating Overlay:** "Always-on" note-taking pane that appears during meetings.
*   **Artifact Management:** Structured storage with `manifest.json` metadata.

---

## 2. Technology Stack & Architecture

### 2.1 The "Swift + Python Sidecar" Architecture
To satisfy the **hard requirement for Parakeet** while maintaining a native macOS experience:

1.  **Frontend (Swift / SwiftUI):**
    *   Manages UI, Audio Recording (`ScreenCaptureKit`), Meeting Detection, and File I/O.
    *   Acts as the "Manager" process.
2.  **Backend (Python + MLX):**
    *   A standalone Python script (`transcribe_parakeet.py`).
    *   Uses `mlx-community/parakeet-tdt-0.6b-v3` (or similar) for inference.
    *   Swift app calls this script via `Process()` after the meeting ends, passing the WAV file path.
    *   *Why?* `mlx-swift` lacks high-level ASR pipelines for Parakeet TDT models. Python MLX is the stable path for this specific model.

### 2.2 Key Frameworks
*   **Swift:** AppKit, SwiftUI, ScreenCaptureKit, AVFoundation, AppleScriptObjC.
*   **Python:** `mlx`, `mlx-data`, `numpy`, `transformers` (if needed for tokenizers).

---

## 3. Core Services Implementation

### 3.1 `MeetingDetectorService` (Swift)
Combines multiple signals for reliability:
*   **Zoom Strategy:**
    1.  Monitor `NSWorkspace` for `us.zoom.xos`.
    2.  If running, check UDP ports: `lsof -i 4UDP -p {PID}`. Active flow = Meeting.
    3.  Backup: Check window title for "Zoom Meeting".
*   **Google Meet Strategy:**
    1.  Monitor browsers (Chrome, Safari, Arc).
    2.  Run AppleScript to query active tab URL for `meet.google.com`.

### 3.2 `AudioRecorderService` (Swift)
*   **System Audio:** `SCShareableContent` -> `SCStream` -> `SCStreamOutput`.
    *   *Critical:* Requires `Screen Recording` permission.
*   **Mic Audio:** `AVCaptureSession` or `AVAudioEngine`.
*   **Mixing:** Write to a multi-channel WAV (Ch 1: System, Ch 2: Mic) or mix down to mono for transcription.

### 3.3 `TranscriberService` (Swift -> Python)
*   **Step 1 (Swift):** Save `recording.wav` to meeting folder.
*   **Step 2 (Swift):** Locate bundled Python or user's venv.
*   **Step 3 (Shell):**
    ```bash
    /path/to/python transcribe.py --input "recording.wav" --model "parakeet-tdt-0.6b" --output "transcript.json"
    ```
*   **Step 4 (Python):**
    *   Load model via `mlx`.
    *   Transcribe audio.
    *   Dump JSON with timestamps.

### 3.4 `StorageManager` (Swift)
*   **Directory Structure:**
    ```
    ~/Documents/Meetings/
      └── 2025-11-27_10-30_Zoom-Meeting/
          ├── manifest.json       # Metadata (Title, Date, Duration)
          ├── audio.wav           # Raw Audio
          ├── notes.md            # User Notes
          └── transcript.json     # Parakeet Output
    ```

---

## 4. Implementation Phases

### Phase 1: Setup & Robust Detection (Day 1-2)
*   **Project Init:** Native macOS App.
*   **Permissions:** Microphone, Accessibility (for AppleScript/Window Titles), Screen Recording.
*   **Zoom Detection:** Implement `lsof` monitor.
*   **Meet Detection:** Implement `NSAppleScript` for Chrome/Safari.

### Phase 2: Audio Recording (Day 3)
*   **Service:** Build `AudioRecorder` using `ScreenCaptureKit`.
*   **Output:** Ensure reliable `.wav` file creation (16kHz, 16-bit PCM for MLX compatibility).

### Phase 3: Parakeet Integration (Day 4-5)
*   **Python Script:** Write `transcribe.py` using `mlx`.
*   **Bundling:** Decide on strategy (require user to `pip install mlx` vs bundle portable python).
    *   *MVP Decision:* Require user to have a working Python+MLX env path configured in Settings. Bundling is Phase 2 optimization.
*   **Bridge:** Swift `Process` runner to execute the script and parse the JSON output.

### Phase 4: UI & Polish (Day 6)
*   **Menu Bar:** Status icon.
*   **Floating Window:** Notes input, timer, "Stop" button.
*   **History View:** List past meetings from `~/Documents/Meetings`.

---

## 5. MVP "Vibe Code" Instructions

To execute this, prompt me with:

1.  "Create a `MeetingDetector` in Swift that uses `lsof` to detect Zoom UDP traffic and AppleScript for Google Meet tabs."
2.  "Implement `AudioRecorder` using `ScreenCaptureKit` to capture system audio to a WAV file."
3.  "Create a Python script `transcribe.py` that uses MLX to load Parakeet TDT and transcribe a WAV file."
4.  "Build a Swift `TranscriberService` that runs the Python script as a subprocess."
5.  "Build the Menu Bar UI with a floating notes window."
