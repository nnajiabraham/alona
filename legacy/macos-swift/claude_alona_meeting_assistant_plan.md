# Alona: Local Meeting Assistant for macOS

> A local-first meeting recording, transcription, and notes app inspired by Granola.ai

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [Technology Stack Decision](#technology-stack-decision)
3. [Architecture Overview](#architecture-overview)
4. [Core Features & Implementation](#core-features--implementation)
5. [Technical Deep Dive](#technical-deep-dive)
6. [Project Structure](#project-structure)
7. [Development Phases](#development-phases)
8. [Security & Privacy](#security--privacy)
9. [Future Enhancements](#future-enhancements)
10. [References & Resources](#references--resources)

---

## Executive Summary

**Alona** is a privacy-focused macOS application that:

- 🎤 Detects and records Zoom/Google Meet meetings automatically
- 📝 Provides a distraction-free note-taking interface during meetings
- 🗣️ Transcribes recordings locally using AI (no cloud required)
- 📁 Organizes meeting artifacts in user-defined directory structures
- ✨ Generates enhanced summary notes (Phase 2: LLM integration)

### Key Design Principles

1. **Privacy First**: All processing happens locally on your Mac
2. **Simple & Focused**: Clean UI, minimal distractions
3. **Self-Contained**: Single app bundle, no external dependencies (Python, etc.)
4. **Organized**: Systematic file organization by meeting with timestamps
5. **Offline Capable**: Works without internet (except for optional cloud LLM features)

### Key Technical Decisions

| Aspect | Decision |
|--------|----------|
| **Transcription** | SwiftWhisper (MVP) → Parakeet MLX (future) |
| **Folder Format** | `YYYY-MM-DD_HHMM_Title/` for multiple daily meetings |
| **Structure** | Flat: `recording.m4a`, `notes.md`, `transcription.txt`, `summary.md` |

---

## Technology Stack Decision

### Recommendation: Native Swift/SwiftUI

After extensive research, **native Swift development** is strongly recommended over React Native or Tauri for this project. Here's why:

| Criteria | Swift/SwiftUI | React Native macOS | Tauri |
|----------|--------------|-------------------|-------|
| System Audio Capture | ✅ Native ScreenCaptureKit | ❌ Requires native bridge | ⚠️ Requires Rust+Swift bridge |
| Meeting Detection | ✅ NSWorkspace, Accessibility APIs | ⚠️ Requires native modules | ⚠️ Requires Rust+Swift bridge |
| ML Model Integration | ✅ CoreML, Metal acceleration | ❌ Complex bridging | ⚠️ Must call external process |
| Menu Bar App | ✅ Native MenuBarExtra | ⚠️ Limited support | ✅ Possible |
| Performance | ✅ Optimal | ❌ JS bridge overhead | ✅ Near-native |
| Development Speed | ⚠️ Learning curve | ✅ Familiar (if web dev) | ⚠️ Rust learning curve |
| App Size | ✅ Small (~10-50MB) | ❌ Large (~100MB+) | ✅ Small (~10-20MB) |

### Transcription Strategy: Self-Contained App

For a **fully self-contained native macOS app** (no Python dependencies), we use SwiftWhisper for MVP with a clear path to NVIDIA Parakeet in the future.

#### MVP: whisper.cpp with SwiftWhisper

```swift
// SwiftWhisper - Native Swift binding for whisper.cpp
import SwiftWhisper

let whisper = Whisper(fromFileURL: modelURL)
let segments = try await whisper.transcribe(audioFrames: pcmFrames)
```

**Why SwiftWhisper for MVP:**
- ✅ **Fully self-contained** - No Python runtime needed
- ✅ Optimized for Apple Silicon (CoreML + Metal acceleration)
- ✅ Native Swift bindings - bundles directly in app
- ✅ Multiple model sizes (tiny → large) for quality/speed tradeoff
- ✅ Runs completely offline
- ✅ ~3-10x realtime on M1/M2/M3 chips

**Model Performance on Apple Silicon (M1 Pro):**

| Model | Size | Speed | Quality |
|-------|------|-------|---------|
| tiny.en | 75MB | ~10x RT | Good for clear audio |
| base.en | 142MB | ~7x RT | Better accuracy ← **Recommended for MVP** |
| small.en | 466MB | ~4x RT | Good balance |
| medium.en | 1.5GB | ~2x RT | High accuracy |
| large-v3 | 2.9GB | ~1x RT | Best accuracy |

#### Future Enhancement: NVIDIA Parakeet via MLX-Swift

> **Note**: NVIDIA Parakeet models have been converted to Apple's MLX format and are available at [mlx-community/parakeet-tdt-0.6b-v3](https://huggingface.co/mlx-community/parakeet-tdt-0.6b-v3). The `parakeet-mlx` Python library offers excellent features including:
> - Word-level timestamps with confidence scores
> - Real-time streaming transcription
> - FastConformer architecture (more modern than Whisper)
> - 25 language support
>
> **Target model**: `mlx-community/parakeet-tdt-0.6b-v3`
>
> For a self-contained app, we would need to port `parakeet-mlx` to Swift via [MLX-Swift](https://github.com/ml-explore/mlx-swift). This is tracked as a future enhancement once MLX-Swift bindings mature.

The transcription service is designed with a `TranscriptionProvider` protocol to enable easy swapping between engines:

```swift
// Protocol for swappable transcription engines
protocol TranscriptionProvider {
    func transcribe(audioURL: URL) async throws -> TranscriptionResult
    var supportedFormats: [String] { get }
}

struct TranscriptionResult {
    let text: String
    let segments: [TranscriptionSegment]
}

struct TranscriptionSegment {
    let startTime: Double
    let endTime: Double
    let text: String
    let confidence: Double?  // Available with Parakeet
}

// MVP Implementation
class WhisperTranscriptionProvider: TranscriptionProvider { ... }

// Future Implementation  
class ParakeetTranscriptionProvider: TranscriptionProvider { ... }
```

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                        Alona App (SwiftUI)                          │
├─────────────────────────────────────────────────────────────────────┤
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐ │
│  │  Menu Bar   │  │   Meeting   │  │    Notes    │  │  Settings   │ │
│  │   Extra     │  │   Window    │  │   Editor    │  │   Window    │ │
│  └─────────────┘  └─────────────┘  └─────────────┘  └─────────────┘ │
├─────────────────────────────────────────────────────────────────────┤
│                         Core Services                                │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐ │
│  │  Meeting    │  │   Audio     │  │Transcription│  │   Summary   │ │
│  │  Detector   │  │  Recorder   │  │   Engine    │  │  Generator  │ │
│  └─────────────┘  └─────────────┘  └─────────────┘  └─────────────┘ │
├─────────────────────────────────────────────────────────────────────┤
│                         Data Layer                                   │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────────────┐  │
│  │   Meeting   │  │   File      │  │   User Preferences          │  │
│  │   Store     │  │   Manager   │  │   (UserDefaults)            │  │
│  └─────────────┘  └─────────────┘  └─────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────┐
│                    External Dependencies                             │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────────────┐  │
│  │ SwiftWhisper│  │ScreenCapture│  │   Optional: LLM APIs        │  │
│  │ (whisper.cpp)  │    Kit      │  │ (OpenAI/Claude/LMStudio)    │  │
│  └─────────────┘  └─────────────┘  └─────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Core Features & Implementation

### 1. Set Default Meeting Save Directory

**Implementation:**

```swift
// UserDefaults for persistent storage
@AppStorage("meetingSaveDirectory") var meetingSaveDirectory: String = ""

// Directory picker using NSOpenPanel
func selectSaveDirectory() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = true
    panel.prompt = "Select Meeting Folder"
    
    if panel.runModal() == .OK {
        meetingSaveDirectory = panel.url?.path ?? ""
    }
}
```

**Directory Structure:**

> **Note**: Folder names include timestamps (HHMM) to support multiple meetings per day without overwriting.

```
/User-Selected-Directory/
├── 2024-11-27_1030_Team-Standup/
│   ├── recording.m4a
│   ├── notes.md
│   ├── transcription.txt
│   └── summary.md
├── 2024-11-27_1400_Product-Review/
│   ├── recording.m4a
│   ├── notes.md
│   ├── transcription.txt
│   └── summary.md
├── 2024-11-28_0900_Client-Call/
│   └── ...
└── ...
```

### 2. Meeting Detection

**Approach: Multi-signal detection**

```swift
import AppKit
import Foundation

class MeetingDetector: ObservableObject {
    @Published var isInMeeting = false
    @Published var currentMeetingApp: MeetingApp?
    
    enum MeetingApp: String {
        case zoom = "zoom.us"
        case googleMeet = "Google Chrome"  // or other browsers
        case teams = "Microsoft Teams"
    }
    
    private var workspaceObserver: Any?
    
    func startMonitoring() {
        // Monitor running applications
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.checkForMeetingApps()
        }
        
        // Also monitor at intervals for meeting state changes
        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.checkMeetingStatus()
        }
    }
    
    private func checkForMeetingApps() {
        let runningApps = NSWorkspace.shared.runningApplications
        
        // Check for Zoom
        if runningApps.contains(where: { $0.bundleIdentifier == "us.zoom.xos" }) {
            checkZoomMeetingActive()
        }
        
        // Check for Google Meet in browsers
        checkBrowserForGoogleMeet()
    }
    
    private func checkZoomMeetingActive() {
        // Method 1: Check for Zoom meeting window
        // Method 2: Check network connections (Zoom uses UDP on specific ports)
        let task = Process()
        task.launchPath = "/usr/bin/lsof"
        task.arguments = ["-i", "4UDP"]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        task.launch()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        
        // If Zoom has active UDP connections, likely in a meeting
        if output.contains("zoom") && output.components(separatedBy: "\n").count > 2 {
            isInMeeting = true
            currentMeetingApp = .zoom
        }
    }
    
    private func checkBrowserForGoogleMeet() {
        // Use AppleScript to check browser tab titles
        let script = """
        tell application "System Events"
            if exists (process "Google Chrome") then
                tell application "Google Chrome"
                    set tabTitle to title of active tab of front window
                    if tabTitle contains "Meet" then
                        return true
                    end if
                end tell
            end if
        end tell
        return false
        """
        
        // Execute AppleScript and check result
        // ...
    }
}
```

### 3. Audio Recording

**Implementation using ScreenCaptureKit (macOS 12.3+):**

```swift
import ScreenCaptureKit
import AVFoundation

class AudioRecorder: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var recordingURL: URL?
    
    private var stream: SCStream?
    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    
    // For system audio capture
    func startRecordingSystemAudio(outputURL: URL) async throws {
        // Get available content to capture
        let availableContent = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        )
        
        // Configure to capture audio only
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = false
        config.sampleRate = 16000  // Required for whisper.cpp
        config.channelCount = 1    // Mono for transcription
        
        // Create filter for the meeting app (optional - capture all)
        let filter = SCContentFilter(
            desktopIndependentWindow: availableContent.windows.first!
        )
        
        // Create and start stream
        stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream?.addStreamOutput(self, type: .audio, sampleHandlerQueue: .main)
        try await stream?.startCapture()
        
        // Set up audio file for writing
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        audioFile = try AVAudioFile(forWriting: outputURL, settings: format.settings)
        
        isRecording = true
        recordingURL = outputURL
    }
    
    func stopRecording() async {
        try? await stream?.stopCapture()
        stream = nil
        audioFile = nil
        isRecording = false
    }
}

extension AudioRecorder: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        
        // Convert CMSampleBuffer to AVAudioPCMBuffer and write to file
        // ... conversion code
    }
}
```

**Alternative: Microphone + System Audio via Virtual Device**

For capturing both microphone and system audio, consider using:
- **BlackHole** (open-source virtual audio device)
- **Loopback** (commercial, easier setup)

```swift
// Capture from aggregate device (mic + system)
func startRecordingWithMicrophone(outputURL: URL) throws {
    audioEngine = AVAudioEngine()
    
    let inputNode = audioEngine!.inputNode
    let format = inputNode.outputFormat(forBus: 0)
    
    audioFile = try AVAudioFile(forWriting: outputURL, settings: format.settings)
    
    inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, time in
        try? self?.audioFile?.write(from: buffer)
    }
    
    try audioEngine?.start()
    isRecording = true
}
```

### 4. Notes Interface

**Implementation with SwiftUI:**

```swift
import SwiftUI

struct MeetingNotesView: View {
    @Binding var meeting: Meeting
    @State private var noteText: String = ""
    @FocusState private var isTextEditorFocused: Bool
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Meeting header
            HStack {
                Circle()
                    .fill(meeting.isRecording ? Color.red : Color.gray)
                    .frame(width: 12, height: 12)
                
                Text(meeting.title)
                    .font(.headline)
                
                Spacer()
                
                Text(meeting.formattedDuration)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Divider()
            
            // Notes editor
            TextEditor(text: $noteText)
                .font(.body)
                .focused($isTextEditorFocused)
                .frame(minHeight: 200)
                .onChange(of: noteText) { newValue in
                    // Auto-save notes
                    Task {
                        await meeting.saveNotes(noteText)
                    }
                }
            
            // Quick action buttons
            HStack {
                Button(action: { insertTimestamp() }) {
                    Label("Timestamp", systemImage: "clock")
                }
                .buttonStyle(.bordered)
                
                Button(action: { insertBullet() }) {
                    Label("Bullet", systemImage: "list.bullet")
                }
                .buttonStyle(.bordered)
                
                Spacer()
            }
        }
        .padding()
        .onAppear {
            noteText = meeting.notes
            isTextEditorFocused = true
        }
    }
    
    private func insertTimestamp() {
        let timestamp = meeting.currentTimestamp
        noteText += "\n[\(timestamp)] "
    }
    
    private func insertBullet() {
        noteText += "\n• "
    }
}
```

### 5. Transcription Engine

**Implementation with SwiftWhisper:**

```swift
import SwiftWhisper

class TranscriptionEngine: ObservableObject {
    @Published var isTranscribing = false
    @Published var progress: Double = 0
    @Published var transcriptionResult: String = ""
    
    private var whisper: Whisper?
    
    func loadModel() async throws {
        // Model should be bundled with app or downloaded on first launch
        guard let modelURL = Bundle.main.url(
            forResource: "ggml-base.en",
            withExtension: "bin"
        ) else {
            throw TranscriptionError.modelNotFound
        }
        
        whisper = Whisper(fromFileURL: modelURL)
        whisper?.delegate = self
    }
    
    func transcribe(audioURL: URL) async throws -> String {
        guard let whisper = whisper else {
            throw TranscriptionError.modelNotLoaded
        }
        
        isTranscribing = true
        defer { isTranscribing = false }
        
        // Convert audio to required format (16kHz, mono, Float32)
        let audioFrames = try await convertAudioToPCM(url: audioURL)
        
        // Perform transcription
        let segments = try await whisper.transcribe(audioFrames: audioFrames)
        
        // Format output with timestamps
        transcriptionResult = segments.map { segment in
            let startTime = formatTimestamp(segment.startTime)
            let endTime = formatTimestamp(segment.endTime)
            return "[\(startTime) - \(endTime)] \(segment.text)"
        }.joined(separator: "\n")
        
        return transcriptionResult
    }
    
    private func convertAudioToPCM(url: URL) async throws -> [Float] {
        // Use AVFoundation to read and convert audio
        let audioFile = try AVAudioFile(forReading: url)
        
        // Convert to required format
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!
        
        let converter = AVAudioConverter(from: audioFile.processingFormat, to: format)!
        
        let frameCount = AVAudioFrameCount(audioFile.length)
        let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        
        try converter.convert(to: pcmBuffer, from: audioFile)
        
        // Extract float array
        let floatArray = Array(UnsafeBufferPointer(
            start: pcmBuffer.floatChannelData?[0],
            count: Int(pcmBuffer.frameLength)
        ))
        
        return floatArray
    }
    
    private func formatTimestamp(_ seconds: Int) -> String {
        let minutes = seconds / 60
        let remainingSeconds = seconds % 60
        return String(format: "%02d:%02d", minutes, remainingSeconds)
    }
}

extension TranscriptionEngine: WhisperDelegate {
    func whisper(_ aWhisper: Whisper, didUpdateProgress progress: Double) {
        DispatchQueue.main.async {
            self.progress = progress
        }
    }
    
    func whisper(_ aWhisper: Whisper, didProcessNewSegments segments: [Segment], atIndex index: Int) {
        // Handle real-time segment updates if needed
    }
    
    func whisper(_ aWhisper: Whisper, didCompleteWithSegments segments: [Segment]) {
        // Transcription complete
    }
    
    func whisper(_ aWhisper: Whisper, didErrorWith error: Error) {
        print("Transcription error: \(error)")
    }
}
```

### 6. Enhanced Summary Notes (Phase 2 - Placeholder)

**Implementation with extensible provider pattern:**

```swift
import Foundation

// MARK: - Summary Provider Protocol
protocol SummaryProvider {
    func generateSummary(
        transcript: String,
        userNotes: String
    ) async throws -> String
}

// MARK: - Placeholder Provider (for MVP)
class PlaceholderSummaryProvider: SummaryProvider {
    func generateSummary(transcript: String, userNotes: String) async throws -> String {
        // Simulate processing delay
        try await Task.sleep(nanoseconds: 2_000_000_000)
        
        return """
        # Meeting Summary
        
        ## Key Points
        - [Placeholder] This is a dummy summary
        - The actual implementation will use LLM APIs
        - User notes and transcript will be analyzed
        
        ## Action Items
        - [ ] Implement OpenAI integration
        - [ ] Add Claude API support
        - [ ] Support local LLM via LMStudio
        
        ## Next Steps
        - Review transcript for accuracy
        - Add speaker detection in future version
        
        ---
        *Generated on \(Date().formatted())*
        """
    }
}

// MARK: - OpenAI Provider (Phase 2)
class OpenAISummaryProvider: SummaryProvider {
    private let apiKey: String
    
    init(apiKey: String) {
        self.apiKey = apiKey
    }
    
    func generateSummary(transcript: String, userNotes: String) async throws -> String {
        // TODO: Implement actual OpenAI API call
        throw SummaryError.notImplemented
    }
}

// MARK: - Claude Provider (Phase 2)
class ClaudeSummaryProvider: SummaryProvider {
    private let apiKey: String
    
    init(apiKey: String) {
        self.apiKey = apiKey
    }
    
    func generateSummary(transcript: String, userNotes: String) async throws -> String {
        // TODO: Implement actual Claude API call
        throw SummaryError.notImplemented
    }
}

// MARK: - LMStudio Provider (Phase 2)
class LMStudioSummaryProvider: SummaryProvider {
    private let endpoint: URL
    
    init(endpoint: URL = URL(string: "http://localhost:1234/v1")!) {
        self.endpoint = endpoint
    }
    
    func generateSummary(transcript: String, userNotes: String) async throws -> String {
        // TODO: Implement LMStudio local API call
        throw SummaryError.notImplemented
    }
}

// MARK: - Summary Manager
class SummaryManager: ObservableObject {
    @Published var isGenerating = false
    @Published var currentSummary: String?
    
    private var provider: SummaryProvider
    
    init(provider: SummaryProvider = PlaceholderSummaryProvider()) {
        self.provider = provider
    }
    
    func setProvider(_ provider: SummaryProvider) {
        self.provider = provider
    }
    
    func generateSummary(for meeting: Meeting) async throws {
        isGenerating = true
        defer { isGenerating = false }
        
        let summary = try await provider.generateSummary(
            transcript: meeting.transcription,
            userNotes: meeting.notes
        )
        
        currentSummary = summary
        
        // Save to file
        try await meeting.saveSummary(summary)
    }
    
    func regenerateSummary(for meeting: Meeting) async throws {
        // Overwrites existing summary
        try await generateSummary(for: meeting)
    }
}

enum SummaryError: Error {
    case notImplemented
    case apiError(String)
    case invalidResponse
}
```

---

## Technical Deep Dive

### Menu Bar App Architecture

```swift
import SwiftUI

@main
struct AlonaApp: App {
    @StateObject private var appState = AppState()
    
    var body: some Scene {
        // Menu bar extra - always visible
        MenuBarExtra {
            MenuBarView()
                .environmentObject(appState)
        } label: {
            Label("Alona", systemImage: appState.isRecording ? "record.circle.fill" : "record.circle")
        }
        .menuBarExtraStyle(.window)
        
        // Settings window
        Settings {
            SettingsView()
                .environmentObject(appState)
        }
        
        // Meeting notes window (opened when recording starts)
        WindowGroup(id: "meeting-notes") {
            MeetingNotesView(meeting: $appState.currentMeeting)
                .environmentObject(appState)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 400, height: 600)
    }
}

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openWindow) private var openWindow
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Status indicator
            HStack {
                Circle()
                    .fill(appState.isRecording ? Color.red : Color.gray)
                    .frame(width: 8, height: 8)
                Text(appState.isRecording ? "Recording..." : "Idle")
                    .font(.caption)
            }
            
            Divider()
            
            if appState.isRecording {
                Button("Open Notes") {
                    openWindow(id: "meeting-notes")
                }
                
                Button("Stop Recording") {
                    Task {
                        await appState.stopRecording()
                    }
                }
                .foregroundColor(.red)
            } else {
                Button("Start Recording") {
                    Task {
                        await appState.startRecording()
                        openWindow(id: "meeting-notes")
                    }
                }
            }
            
            Divider()
            
            Button("Recent Meetings") {
                // Show recent meetings list
            }
            
            SettingsLink {
                Text("Settings...")
            }
            
            Divider()
            
            Button("Quit Alona") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding()
        .frame(width: 200)
    }
}
```

### Permissions Required

The app needs several macOS permissions:

```xml
<!-- Info.plist -->
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>NSMicrophoneUsageDescription</key>
    <string>Alona needs microphone access to record meeting audio for transcription.</string>
    
    <key>NSAppleEventsUsageDescription</key>
    <string>Alona needs automation access to detect active meetings in browsers.</string>
    
    <key>NSScreenCaptureUsageDescription</key>
    <string>Alona needs screen recording permission to capture system audio from meetings.</string>
    
    <!-- For Accessibility API access -->
    <key>NSAccessibilityUsageDescription</key>
    <string>Alona needs accessibility access to detect when you're in a meeting.</string>
</dict>
</plist>
```

### File Management

```swift
import Foundation

class MeetingFileManager {
    private let fileManager = FileManager.default
    
    /// Creates a meeting directory with timestamp to support multiple meetings per day
    /// Format: YYYY-MM-DD_HHMM_Meeting-Title
    func createMeetingDirectory(
        baseDirectory: URL,
        meetingTitle: String,
        date: Date
    ) throws -> URL {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HHmm"
        
        let sanitizedTitle = meetingTitle
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: " ", with: "-")
        
        // Include time to avoid collisions for multiple meetings on same day
        let folderName = "\(dateFormatter.string(from: date))_\(timeFormatter.string(from: date))_\(sanitizedTitle)"
        let meetingDir = baseDirectory.appendingPathComponent(folderName)
        
        // Check if directory exists and append suffix if needed
        var finalDir = meetingDir
        var suffix = 1
        while fileManager.fileExists(atPath: finalDir.path) {
            finalDir = baseDirectory.appendingPathComponent("\(folderName)-\(suffix)")
            suffix += 1
        }
        
        try fileManager.createDirectory(
            at: finalDir,
            withIntermediateDirectories: true
        )
        
        return finalDir
    }
    
    func getRecordingURL(meetingDir: URL) -> URL {
        return meetingDir.appendingPathComponent("recording.m4a")
    }
    
    func getNotesURL(meetingDir: URL) -> URL {
        return meetingDir.appendingPathComponent("notes.md")
    }
    
    func getTranscriptionURL(meetingDir: URL) -> URL {
        return meetingDir.appendingPathComponent("transcription.txt")
    }
    
    func getSummaryURL(meetingDir: URL) -> URL {
        return meetingDir.appendingPathComponent("summary.md")
    }
}
```

---

## Project Structure

```
Alona/
├── Alona.xcodeproj
├── Alona/
│   ├── AlonaApp.swift                 # App entry point
│   ├── Info.plist                     # Permissions & config
│   │
│   ├── Models/
│   │   ├── Meeting.swift              # Meeting data model
│   │   ├── AppState.swift             # Global app state
│   │   └── UserSettings.swift         # User preferences
│   │
│   ├── Views/
│   │   ├── MenuBarView.swift          # Menu bar interface
│   │   ├── MeetingNotesView.swift     # Notes editor
│   │   ├── SettingsView.swift         # Settings window
│   │   ├── RecentMeetingsView.swift   # Meeting history
│   │   └── TranscriptionProgressView.swift
│   │
│   ├── Services/
│   │   ├── MeetingDetector.swift      # Zoom/Meet detection
│   │   ├── AudioRecorder.swift        # Audio capture
│   │   ├── TranscriptionEngine.swift  # whisper.cpp wrapper
│   │   ├── SummaryManager.swift       # LLM integration
│   │   └── MeetingFileManager.swift   # File organization
│   │
│   ├── Providers/
│   │   ├── SummaryProvider.swift      # Protocol
│   │   ├── PlaceholderProvider.swift  # Dummy implementation
│   │   ├── OpenAIProvider.swift       # (Phase 2)
│   │   ├── ClaudeProvider.swift       # (Phase 2)
│   │   └── LMStudioProvider.swift     # (Phase 2)
│   │
│   ├── Resources/
│   │   └── Models/
│   │       └── ggml-base.en.bin       # Whisper model
│   │
│   └── Utilities/
│       ├── AudioConverter.swift       # Audio format conversion
│       └── Extensions.swift           # Helper extensions
│
├── AlonaTests/
│   └── ...
│
└── README.md
```

---

## Development Phases

### Phase 1: MVP (2-3 weeks)

**Week 1: Foundation**
- [ ] Set up Xcode project with SwiftUI
- [ ] Implement basic menu bar app structure
- [ ] Create settings view with directory picker
- [ ] Implement file organization system

**Week 2: Core Recording**
- [ ] Implement meeting detection (Zoom focus first)
- [ ] Set up audio recording with ScreenCaptureKit
- [ ] Create notes interface with auto-save
- [ ] Implement recording start/stop workflow

**Week 3: Transcription & Polish**
- [ ] Integrate SwiftWhisper for transcription
- [ ] Implement post-recording transcription pipeline
- [ ] Add placeholder summary generation
- [ ] Basic error handling and edge cases

### Phase 2: Enhanced Features (2-3 weeks)

**Week 4-5: LLM Integration**
- [ ] Implement OpenAI API integration
- [ ] Add Claude API support
- [ ] Integrate LMStudio for local LLM
- [ ] Settings UI for provider selection

**Week 6: Polish & Extended Support**
- [ ] Google Meet detection improvement
- [ ] Microsoft Teams support
- [ ] Better meeting title detection
- [ ] Enhanced notes editor features

### Phase 3: Advanced Features (Future)

- [ ] Speaker diarization (who said what)
- [ ] Calendar integration for meeting context
- [ ] Real-time transcription preview
- [ ] Search across all meetings
- [ ] Export to various formats (PDF, DOCX)
- [ ] Sync with cloud storage (optional)

---

## Security & Privacy

### Data Handling

1. **All processing is local by default**
   - Audio recording stays on device
   - Transcription uses local whisper.cpp
   - No data sent to cloud without explicit user action

2. **LLM integration is opt-in**
   - Users must explicitly configure API keys
   - Clear warning when data is sent to cloud
   - Local LLM option (LMStudio) for privacy-conscious users

3. **Secure storage**
   - Use macOS Keychain for API keys
   - Files stored in user-selected location
   - No hidden caches or cloud sync

### Permission Handling

```swift
import AVFoundation
import ScreenCaptureKit

class PermissionManager {
    static func requestMicrophonePermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }
    
    static func requestScreenRecordingPermission() async -> Bool {
        // ScreenCaptureKit permissions are requested on first use
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )
            return true
        } catch {
            // User needs to grant permission in System Settings
            return false
        }
    }
    
    static func openSystemPreferences() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }
}
```

---

## Future Enhancements

### Parakeet TDT v3 Integration (Priority)

Migrate from SwiftWhisper to NVIDIA Parakeet via MLX-Swift for improved features:

```swift
// Future: Native Parakeet integration via MLX-Swift
// Target model: mlx-community/parakeet-tdt-0.6b-v3
class ParakeetTranscriptionProvider: TranscriptionProvider {
    func transcribe(audioURL: URL) async throws -> TranscriptionResult {
        // Word-level timestamps with confidence scores
        // Real-time streaming support
        // 25 language support
    }
}
```

**Benefits over Whisper:**
- Word-level timestamps with confidence scores (built-in)
- FastConformer architecture (more modern)
- Better accuracy on conversational speech
- Real-time streaming transcription

### Speaker Diarization

Use **pyannote-audio** or similar for speaker identification:

```swift
// Future: Speaker detection integration
struct TranscriptionSegment {
    let speaker: String?  // "Speaker 1", "Speaker 2", etc.
    let startTime: Double
    let endTime: Double
    let text: String
}
```

### Real-time Transcription

whisper.cpp supports streaming mode:

```swift
// Future: Real-time transcription
func startRealtimeTranscription() {
    // Use whisper.cpp streaming API
    // Display live captions during meeting
}
```

### Calendar Integration

```swift
import EventKit

// Future: Calendar integration
func getUpcomingMeetings() async throws -> [EKEvent] {
    let eventStore = EKEventStore()
    // Request calendar access and fetch events
}
```

---

## References & Resources

### Official Documentation

- [SwiftUI Documentation](https://developer.apple.com/documentation/swiftui)
- [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit)
- [AVFoundation](https://developer.apple.com/documentation/avfoundation)
- [MenuBarExtra](https://developer.apple.com/documentation/swiftui/menubarextra)

### Libraries

- [whisper.cpp](https://github.com/ggml-org/whisper.cpp) - C/C++ port of OpenAI's Whisper
- [SwiftWhisper](https://github.com/exPHAT/SwiftWhisper) - Swift bindings for whisper.cpp

### Model Downloads

Download whisper models from:
```bash
# For CoreML-optimized models
cd models
./download-ggml-model.sh base.en
./generate-coreml-model.sh base.en
```

### Tutorials & Guides

- [Building Menu Bar Apps with SwiftUI](https://developer.apple.com/documentation/swiftui/building-and-customizing-the-menu-bar-with-swiftui)
- [ScreenCaptureKit for Audio](https://developer.apple.com/videos/play/wwdc2022/10156/)

---

## Getting Started

### Prerequisites

- macOS 13.0+ (Ventura or later)
- Xcode 15+
- Apple Silicon recommended (M1/M2/M3) for best transcription performance

### Quick Start

```bash
# Clone the repository
git clone https://github.com/yourusername/alona.git
cd alona

# Open in Xcode
open Alona.xcodeproj

# Build and run
# Cmd + R
```

### Download Whisper Model

```bash
# Download base.en model (~142MB)
cd Alona/Resources/Models
curl -L -o ggml-base.en.bin https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin
```

---

## License

MIT License - See LICENSE file for details

---

*Document created: November 27, 2024*
*Last updated: November 27, 2024*

## Appendix: Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| **App Type** | Fully self-contained | No Python dependencies, single app bundle |
| **Transcription (MVP)** | SwiftWhisper (whisper.cpp) | Native Swift, bundles in app |
| **Transcription (Future)** | Parakeet TDT v3 via MLX-Swift | Better word timestamps, confidence scores |
| **Directory Format** | `YYYY-MM-DD_HHMM_Title/` | Supports multiple meetings per day |
| **File Structure** | Flat (4 files per meeting) | Simple, easy to navigate |
| **Framework** | Native Swift/SwiftUI | Best system integration for macOS |

