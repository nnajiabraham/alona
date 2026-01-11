# Alona

[![CI](https://github.com/YOUR_USERNAME/alona/actions/workflows/ci.yml/badge.svg)](https://github.com/YOUR_USERNAME/alona/actions/workflows/ci.yml)

**Alona** is a macOS-native meeting assistant that captures, transcribes, and summarizes your meetings — entirely on-device.

## Features

- **🎯 Meeting Detection** — Automatically detects active Zoom and Google Meet sessions
- **🎙️ Audio Capture** — Records system audio (meeting participants) and microphone (your voice) using macOS CoreAudio Process Taps
- **🗣️ Local Transcription** — Transcribes audio locally using Whisper (ggml-base.en) — no cloud uploads
- **📝 Notes & Summaries** — Take notes during meetings and generate AI-powered summaries
- **📁 Organized Storage** — All meeting artifacts (audio, notes, transcripts, summaries) saved to a user-chosen directory

## Requirements

- macOS 14.6+ (Sonoma)
- Apple Silicon (arm64)

## Installation

1. Clone the repository
2. Download the Whisper model:
   ```bash
   make download-model
   ```
3. Open `Alona.xcworkspace` in Xcode and build, or:
   ```bash
   make build
   make run
   ```

## Development

```bash
# Build and run tests
make test

# Format code
make format

# Check formatting without changes
make lint

# Clean build artifacts
make clean
```

See [AGENTS.md](AGENTS.md) for detailed development guidelines.

## Permissions Required

Alona requires the following macOS permissions:

| Permission | Purpose |
|------------|---------|
| **Microphone** | Capture your voice |
| **System Audio Recording** | Capture meeting participant audio via CoreAudio Process Taps |
| **Accessibility** | Detect Zoom meeting state |
| **Automation** | Detect Google Meet tab titles via AppleScript |

## Architecture

```
Alona/
├── AlonaApp.swift           # App entry point, MenuBarExtra
├── Models/
│   ├── AppState.swift       # @Observable main state container
│   └── TranscriptionResult.swift
├── Services/
│   ├── AudioRecorder.swift  # CoreAudio process tap + mic capture
│   ├── MeetingDetector.swift
│   ├── TranscriptionEngine.swift
│   └── ...
├── Views/
│   ├── MenuBarView.swift    # Menu bar UI
│   ├── MeetingNotesView.swift
│   └── ...
└── Resources/
    └── Models/              # Whisper model files
```

## Tech Stack

- **SwiftUI** with `MenuBarExtra` for menu bar integration
- **@Observable** (Swift Observation framework) for state management
- **CoreAudio** Process Taps for non-interfering system audio capture
- **SwiftWhisper** for local transcription
- **Swift 6.0** with strict concurrency

## Contributing

This repo is currently private and under active development. Please coordinate before opening pull requests.

## License

Private — All rights reserved.
