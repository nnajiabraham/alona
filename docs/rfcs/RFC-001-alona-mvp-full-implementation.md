# RFC-001: Alona MVP Full Implementation

**Status:** Draft  
**Branch:** `rfc/001-alona-mvp`  
**Related PRD:** [PRD-alona-macos-mvp-2025-11-27.md](../PRD-alona-macos-mvp-2025-11-27.md)

---

## 1. Goal

Build a fully self-contained native macOS application that:
- Detects Zoom/Google Meet meetings and automatically starts recording
- Captures system audio via ScreenCaptureKit + microphone via AVAudioEngine
- Provides a floating notes window with autosave during meetings
- Transcribes recordings locally using SwiftWhisper (whisper.cpp)
- Organizes all meeting artifacts in user-defined directories
- Generates placeholder enhanced summaries (real LLM integration in future)

---

## 2. Background & Context

Knowledge workers need a privacy-focused, offline-capable meeting assistant that doesn't require cloud services or meeting bots. Existing solutions like Granola require cloud processing, creating privacy and compliance concerns.

**Key Constraints:**
- **Self-contained**: No Python runtime, no external dependencies at runtime
- **Local-first**: All processing on-device, no network calls except opt-in LLM
- **Simple file structure**: Flat folders with `YYYY-MM-DD_HHMM_<slug>/` naming

**Technology Stack (from PRD):**
- Swift 5+ / SwiftUI
- ScreenCaptureKit (macOS 12.3+) for system audio
- AVAudioEngine for microphone capture
- SwiftWhisper for transcription (whisper.cpp Swift bindings)
- macOS 13+ (Ventura) for MenuBarExtra API

---

## 3. Technical Design

### 3.1 Project Structure

```
Alona/
├── Alona.xcodeproj
├── Alona/
│   ├── AlonaApp.swift                    # App entry point with MenuBarExtra
│   ├── Info.plist                        # Permissions
│   │
│   ├── Models/
│   │   ├── Meeting.swift                 # Meeting data model
│   │   ├── AppState.swift                # Global observable state
│   │   └── TranscriptionResult.swift     # Transcription output model
│   │
│   ├── Views/
│   │   ├── MenuBarView.swift             # Menu bar dropdown
│   │   ├── MeetingNotesView.swift        # Floating notes window
│   │   ├── SettingsView.swift            # Settings/preferences
│   │   ├── OnboardingView.swift          # Permission request wizard
│   │   └── TranscriptionProgressView.swift
│   │
│   ├── Services/
│   │   ├── MeetingDetector.swift         # Zoom/Meet detection
│   │   ├── AudioRecorder.swift           # ScreenCaptureKit + AVAudioEngine
│   │   ├── TranscriptionEngine.swift     # SwiftWhisper wrapper
│   │   ├── SummaryManager.swift          # Summary generation
│   │   ├── MeetingFileManager.swift      # File organization
│   │   └── PermissionManager.swift       # Permission handling
│   │
│   ├── Protocols/
│   │   ├── TranscriptionProvider.swift   # Transcription engine protocol
│   │   └── SummaryProvider.swift         # Summary generation protocol
│   │
│   └── Resources/
│       └── Models/
│           └── ggml-base.en.bin          # Whisper model (~142MB)
│
└── AlonaTests/
```

### 3.2 App Entry Point (AlonaApp.swift)

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
        
        // Meeting notes window
        WindowGroup(id: "meeting-notes") {
            MeetingNotesView()
                .environmentObject(appState)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 400, height: 500)
    }
}
```

### 3.3 Meeting Detection (MeetingDetector.swift)

**Multi-signal detection pipeline:**

1. **NSWorkspace notifications** - Monitor app launches/activations
2. **Process polling (2s interval)** - Check for Zoom/Meet processes
3. **UDP flow verification** - `lsof -i 4UDP -p <pid>` confirms active RTP streams
4. **Browser tab inspection** - AppleScript queries for `meet.google.com` URLs

```swift
import AppKit
import Foundation

class MeetingDetector: ObservableObject {
    @Published var isInMeeting = false
    @Published var detectedApp: MeetingApp?
    @Published var meetingTitle: String = "Untitled Meeting"
    
    enum MeetingApp: String, CaseIterable {
        case zoom = "us.zoom.xos"
        case googleMeet = "com.google.Chrome"  // or Safari
        case teams = "com.microsoft.teams"
    }
    
    private var pollTimer: Timer?
    private var workspaceObserver: Any?
    
    func startMonitoring() {
        // 1. NSWorkspace notification observer
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.checkMeetingStatus()
        }
        
        // 2. Polling timer every 2 seconds
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.checkMeetingStatus()
        }
        
        checkMeetingStatus()
    }
    
    func stopMonitoring() {
        pollTimer?.invalidate()
        if let observer = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }
    
    private func checkMeetingStatus() {
        // Check Zoom first
        if checkZoomMeeting() {
            detectedApp = .zoom
            isInMeeting = true
            return
        }
        
        // Check Google Meet in browsers
        if checkGoogleMeet() {
            detectedApp = .googleMeet
            isInMeeting = true
            return
        }
        
        isInMeeting = false
        detectedApp = nil
    }
    
    private func checkZoomMeeting() -> Bool {
        let runningApps = NSWorkspace.shared.runningApplications
        guard let zoomApp = runningApps.first(where: { $0.bundleIdentifier == "us.zoom.xos" }) else {
            return false
        }
        
        // Verify active UDP connections (RTP flows)
        return verifyUDPConnections(for: zoomApp.processIdentifier)
    }
    
    private func verifyUDPConnections(for pid: pid_t) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/lsof")
        task.arguments = ["-i", "4UDP", "-p", "\(pid)"]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        
        do {
            try task.run()
            task.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            
            // More than header line = active connections
            return output.components(separatedBy: "\n").count > 2
        } catch {
            return false
        }
    }
    
    private func checkGoogleMeet() -> Bool {
        // Use AppleScript to check Chrome/Safari tabs
        let script = """
        tell application "System Events"
            if exists (process "Google Chrome") then
                tell application "Google Chrome"
                    repeat with w in windows
                        repeat with t in tabs of w
                            if URL of t contains "meet.google.com" then
                                return title of t
                            end if
                        end repeat
                    end repeat
                end tell
            end if
        end tell
        return ""
        """
        
        var error: NSDictionary?
        if let scriptObject = NSAppleScript(source: script) {
            let result = scriptObject.executeAndReturnError(&error)
            
            // Handle Automation permission denial gracefully
            if let error = error {
                let errorCode = error[NSAppleScript.errorNumber] as? Int ?? 0
                // -1743 = "Not authorized to send Apple events"
                if errorCode == -1743 {
                    automationPermissionDenied = true
                    // Don't crash - surface manual start in UI
                    return false
                }
            }
            
            if let title = result.stringValue, !title.isEmpty {
                meetingTitle = title.replacingOccurrences(of: " - Google Meet", with: "")
                automationPermissionDenied = false
                return true
            }
        }
        return false
    }
    
    /// Published property to signal UI to show manual start when automation fails
    @Published var automationPermissionDenied = false
}
```

### 3.4 Audio Recording (AudioRecorder.swift)

**Dual-channel capture strategy (PRD-aligned):**
- System audio via ScreenCaptureKit (channel 0)
- Microphone via AVAudioEngine (channel 1)
- **Output files (flat folder layout per PRD):**
  - `recording.wav` – dual-channel (stereo) PCM WAV with system audio on Ch0 and mic on Ch1
  - `recording-mono.wav` – 16kHz mono mix for transcription (downmixed from recording.wav)
- No separate `recording-mic.wav` file – mic audio is embedded in the dual-channel file

```swift
import AVFoundation
import ScreenCaptureKit

class AudioRecorder: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var recordingDuration: TimeInterval = 0
    
    private var scStream: SCStream?
    private var audioEngine: AVAudioEngine?
    private var dualChannelFile: AVAudioFile?
    private var durationTimer: Timer?
    
    // Buffers for interleaving
    private var systemAudioBuffer: [Float] = []
    private var micAudioBuffer: [Float] = []
    private let bufferQueue = DispatchQueue(label: "com.alona.audiobuffer")
    
    var outputDirectory: URL?
    
    // MARK: - Recording Control
    
    func startRecording(to directory: URL) async throws {
        outputDirectory = directory
        
        // Create dual-channel output file (16kHz stereo)
        let dualChannelURL = directory.appendingPathComponent("recording.wav")
        let dualChannelFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 2,
            interleaved: false
        )!
        dualChannelFile = try AVAudioFile(forWriting: dualChannelURL, settings: dualChannelFormat.settings)
        
        // Start system audio capture (ScreenCaptureKit)
        try await startSystemAudioCapture()
        
        // Start microphone capture (AVAudioEngine)
        try startMicrophoneCapture()
        
        // Start duration timer
        durationTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.recordingDuration += 1
        }
        
        isRecording = true
    }
    
    private func startSystemAudioCapture() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        )
        
        // Configure for audio-only capture at 16kHz mono
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 16000
        config.channelCount = 1
        
        guard let display = content.displays.first else {
            throw RecordingError.noDisplayFound
        }
        
        let filter = SCContentFilter(display: display, excludingWindows: [])
        scStream = SCStream(filter: filter, configuration: config, delegate: nil)
        
        try scStream?.addStreamOutput(self, type: .audio, sampleHandlerQueue: .global(qos: .userInitiated))
        try await scStream?.startCapture()
    }
    
    private func startMicrophoneCapture() throws {
        audioEngine = AVAudioEngine()
        
        let inputNode = audioEngine!.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        
        // Target format: 16kHz mono
        let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!
        
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self = self,
                  let converter = AVAudioConverter(from: inputFormat, to: outputFormat),
                  let convertedBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(buffer.frameLength)) else { return }
            
            var error: NSError?
            converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }
            
            if let channelData = convertedBuffer.floatChannelData?[0] {
                let samples = Array(UnsafeBufferPointer(start: channelData, count: Int(convertedBuffer.frameLength)))
                self.bufferQueue.async {
                    self.micAudioBuffer.append(contentsOf: samples)
                    self.flushBuffersIfNeeded()
                }
            }
        }
        
        try audioEngine?.start()
    }
    
    /// Writes interleaved dual-channel audio when both buffers have data
    private func flushBuffersIfNeeded() {
        // Write when we have at least 1 second of data from both channels
        let minSamples = 16000
        guard systemAudioBuffer.count >= minSamples && micAudioBuffer.count >= minSamples else { return }
        
        let samplesToWrite = min(systemAudioBuffer.count, micAudioBuffer.count)
        
        guard let format = dualChannelFile?.processingFormat,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samplesToWrite)) else { return }
        
        buffer.frameLength = AVAudioFrameCount(samplesToWrite)
        
        // Channel 0: system audio, Channel 1: mic audio
        if let ch0 = buffer.floatChannelData?[0], let ch1 = buffer.floatChannelData?[1] {
            for i in 0..<samplesToWrite {
                ch0[i] = systemAudioBuffer[i]
                ch1[i] = micAudioBuffer[i]
            }
        }
        
        try? dualChannelFile?.write(from: buffer)
        
        // Remove written samples
        systemAudioBuffer.removeFirst(samplesToWrite)
        micAudioBuffer.removeFirst(samplesToWrite)
    }
    
    func stopRecording() async {
        // Stop system audio
        try? await scStream?.stopCapture()
        scStream = nil
        
        // Stop microphone
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        
        // Flush remaining buffers
        bufferQueue.sync {
            flushRemainingBuffers()
        }
        
        dualChannelFile = nil
        
        // Stop timer
        durationTimer?.invalidate()
        durationTimer = nil
        
        isRecording = false
        
        // Create mono mix for transcription
        if let dir = outputDirectory {
            try? await createMonoMix(in: dir)
        }
    }
    
    private func flushRemainingBuffers() {
        let samplesToWrite = min(systemAudioBuffer.count, micAudioBuffer.count)
        guard samplesToWrite > 0,
              let format = dualChannelFile?.processingFormat,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samplesToWrite)) else { return }
        
        buffer.frameLength = AVAudioFrameCount(samplesToWrite)
        
        if let ch0 = buffer.floatChannelData?[0], let ch1 = buffer.floatChannelData?[1] {
            for i in 0..<samplesToWrite {
                ch0[i] = systemAudioBuffer[i]
                ch1[i] = micAudioBuffer[i]
            }
        }
        
        try? dualChannelFile?.write(from: buffer)
        systemAudioBuffer.removeAll()
        micAudioBuffer.removeAll()
    }
    
    /// Creates recording-mono.wav by downmixing dual-channel to mono for transcription
    private func createMonoMix(in directory: URL) async throws {
        let dualURL = directory.appendingPathComponent("recording.wav")
        let monoURL = directory.appendingPathComponent("recording-mono.wav")
        
        let sourceFile = try AVAudioFile(forReading: dualURL)
        
        let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!
        
        let monoFile = try AVAudioFile(forWriting: monoURL, settings: monoFormat.settings)
        
        let frameCount = AVAudioFrameCount(sourceFile.length)
        guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFile.processingFormat, frameCapacity: frameCount),
              let monoBuffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: frameCount) else { return }
        
        try sourceFile.read(into: sourceBuffer)
        monoBuffer.frameLength = sourceBuffer.frameLength
        
        // Downmix: average of both channels (system + mic)
        if let ch0 = sourceBuffer.floatChannelData?[0],
           let ch1 = sourceBuffer.floatChannelData?[1],
           let monoData = monoBuffer.floatChannelData?[0] {
            for i in 0..<Int(sourceBuffer.frameLength) {
                monoData[i] = (ch0[i] + ch1[i]) / 2.0
            }
        }
        
        try monoFile.write(from: monoBuffer)
    }
}

extension AudioRecorder: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio,
              let floatSamples = sampleBuffer.asFloatArray() else { return }
        
        bufferQueue.async { [weak self] in
            self?.systemAudioBuffer.append(contentsOf: floatSamples)
            self?.flushBuffersIfNeeded()
        }
    }
}

// Helper extension to extract float samples from CMSampleBuffer
extension CMSampleBuffer {
    func asFloatArray() -> [Float]? {
        guard let formatDescription = formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription),
              let dataBuffer = CMSampleBufferGetDataBuffer(self) else {
            return nil
        }
        
        let frameCount = CMSampleBufferGetNumSamples(self)
        var dataPointer: UnsafeMutablePointer<Int8>?
        var length = 0
        
        let status = CMBlockBufferGetDataPointer(
            dataBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &length,
            dataPointerOut: &dataPointer
        )
        
        guard status == noErr, let dataPointer = dataPointer else { return nil }
        
        // Handle Float32 format (common from ScreenCaptureKit)
        if asbd.pointee.mBitsPerChannel == 32 {
            let floatPointer = UnsafeRawPointer(dataPointer).bindMemory(to: Float.self, capacity: frameCount)
            return Array(UnsafeBufferPointer(start: floatPointer, count: frameCount))
        }
        
        // Handle Int16 format (fallback)
        if asbd.pointee.mBitsPerChannel == 16 {
            let int16Pointer = UnsafeRawPointer(dataPointer).bindMemory(to: Int16.self, capacity: frameCount)
            return (0..<frameCount).map { i in
                max(-1.0, min(Float(int16Pointer[i]) / 32767.0, 1.0))
            }
        }
        
        return nil
    }
}

enum RecordingError: Error {
    case noDisplayFound
    case permissionDenied
    case audioEngineFailure
}
```

### 3.5 Transcription Engine (TranscriptionEngine.swift)

```swift
import SwiftWhisper
import AVFoundation

protocol TranscriptionProvider {
    func transcribe(audioURL: URL) async throws -> TranscriptionResult
}

struct TranscriptionResult {
    let text: String
    let segments: [TranscriptionSegment]
}

struct TranscriptionSegment {
    let startTime: TimeInterval
    let endTime: TimeInterval
    let text: String
}

class TranscriptionEngine: ObservableObject, TranscriptionProvider {
    @Published var isTranscribing = false
    @Published var progress: Double = 0
    
    private var whisper: Whisper?
    
    func loadModel() throws {
        guard let modelURL = Bundle.main.url(forResource: "ggml-base.en", withExtension: "bin") else {
            throw TranscriptionError.modelNotFound
        }
        
        whisper = Whisper(fromFileURL: modelURL)
        whisper?.delegate = self
    }
    
    func transcribe(audioURL: URL) async throws -> TranscriptionResult {
        guard let whisper = whisper else {
            throw TranscriptionError.modelNotLoaded
        }
        
        await MainActor.run { isTranscribing = true }
        defer { Task { @MainActor in isTranscribing = false } }
        
        // Convert audio to required format
        let audioFrames = try await convertAudioToPCM(url: audioURL)
        
        // Transcribe
        let segments = try await whisper.transcribe(audioFrames: audioFrames)
        
        let resultSegments = segments.map { segment in
            TranscriptionSegment(
                startTime: TimeInterval(segment.startTime) / 1000.0,
                endTime: TimeInterval(segment.endTime) / 1000.0,
                text: segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        
        let fullText = resultSegments.map(\.text).joined(separator: " ")
        
        return TranscriptionResult(text: fullText, segments: resultSegments)
    }
    
    private func convertAudioToPCM(url: URL) async throws -> [Float] {
        let audioFile = try AVAudioFile(forReading: url)
        
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!
        
        guard let converter = AVAudioConverter(from: audioFile.processingFormat, to: targetFormat) else {
            throw TranscriptionError.conversionFailed
        }
        
        let frameCount = AVAudioFrameCount(audioFile.length)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCount) else {
            throw TranscriptionError.bufferAllocationFailed
        }
        
        var error: NSError?
        converter.convert(to: outputBuffer, error: &error) { inNumPackets, outStatus in
            outStatus.pointee = .haveData
            
            guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: inNumPackets) else {
                outStatus.pointee = .noDataNow
                return nil
            }
            
            do {
                try audioFile.read(into: inputBuffer, frameCount: inNumPackets)
                return inputBuffer
            } catch {
                outStatus.pointee = .endOfStream
                return nil
            }
        }
        
        if let error = error {
            throw error
        }
        
        guard let channelData = outputBuffer.floatChannelData?[0] else {
            throw TranscriptionError.noChannelData
        }
        
        return Array(UnsafeBufferPointer(start: channelData, count: Int(outputBuffer.frameLength)))
    }
}

extension TranscriptionEngine: WhisperDelegate {
    func whisper(_ aWhisper: Whisper, didUpdateProgress progress: Double) {
        Task { @MainActor in
            self.progress = progress
        }
    }
    
    func whisper(_ aWhisper: Whisper, didProcessNewSegments segments: [Segment], atIndex index: Int) {}
    func whisper(_ aWhisper: Whisper, didCompleteWithSegments segments: [Segment]) {}
    func whisper(_ aWhisper: Whisper, didErrorWith error: Error) {}
}

enum TranscriptionError: Error {
    case modelNotFound
    case modelNotLoaded
    case conversionFailed
    case bufferAllocationFailed
    case noChannelData
}
```

### 3.6 File Management (MeetingFileManager.swift)

```swift
import Foundation

/// Codable struct for transcript JSON serialization (fixes [String: Any] encoding issue)
struct TranscriptSegmentRecord: Codable {
    let start: Double
    let end: Double
    let text: String
}

class MeetingFileManager {
    private let fileManager = FileManager.default
    
    var baseDirectory: URL {
        get {
            if let path = UserDefaults.standard.string(forKey: "meetingSaveDirectory"),
               !path.isEmpty {
                return URL(fileURLWithPath: path)
            }
            return fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Alona")
        }
        set {
            UserDefaults.standard.set(newValue.path, forKey: "meetingSaveDirectory")
        }
    }
    
    /// Creates meeting directory: YYYY-MM-DD_HHMM_<slug>/
    func createMeetingDirectory(title: String, date: Date = Date()) throws -> URL {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HHmm"
        
        let slug = title
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .prefix(50)
        
        let folderName = "\(dateFormatter.string(from: date))_\(timeFormatter.string(from: date))_\(slug)"
        var meetingDir = baseDirectory.appendingPathComponent(String(folderName))
        
        // Handle collisions for multiple meetings per day
        var suffix = 1
        while fileManager.fileExists(atPath: meetingDir.path) {
            meetingDir = baseDirectory.appendingPathComponent("\(folderName)-\(suffix)")
            suffix += 1
        }
        
        try fileManager.createDirectory(at: meetingDir, withIntermediateDirectories: true)
        
        return meetingDir
    }
    
    func saveNotes(_ notes: String, to directory: URL) throws {
        let notesURL = directory.appendingPathComponent("notes.md")
        try notes.write(to: notesURL, atomically: true, encoding: .utf8)
        
        // Clean up temp file if exists
        let tempURL = directory.appendingPathComponent("notes.tmp")
        try? fileManager.removeItem(at: tempURL)
    }
    
    func saveTranscript(_ result: TranscriptionResult, to directory: URL) throws {
        // Save plain text
        let textURL = directory.appendingPathComponent("transcript.txt")
        try result.text.write(to: textURL, atomically: true, encoding: .utf8)
        
        // Save JSON with timestamps using Codable struct (NOT [String: Any])
        let jsonURL = directory.appendingPathComponent("transcript.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        
        let records = result.segments.map { segment in
            TranscriptSegmentRecord(
                start: segment.startTime,
                end: segment.endTime,
                text: segment.text
            )
        }
        
        let jsonData = try encoder.encode(records)
        try jsonData.write(to: jsonURL)
    }
    
    func saveSummary(_ summary: String, to directory: URL) throws {
        let summaryURL = directory.appendingPathComponent("summary.md")
        try summary.write(to: summaryURL, atomically: true, encoding: .utf8)
    }
    
    /// Saves autosave draft to notes.tmp
    func saveNotesDraft(_ notes: String, to directory: URL) throws {
        let tempURL = directory.appendingPathComponent("notes.tmp")
        try notes.write(to: tempURL, atomically: true, encoding: .utf8)
    }
    
    /// Recovers notes from temp file if it exists (for crash recovery)
    func recoverNotesFromTemp(in directory: URL) -> String? {
        let tempURL = directory.appendingPathComponent("notes.tmp")
        return try? String(contentsOf: tempURL, encoding: .utf8)
    }
}
```

### 3.7 Summary Manager (Placeholder)

```swift
import Foundation

protocol SummaryProvider {
    func generateSummary(transcript: String, notes: String) async throws -> String
}

class PlaceholderSummaryProvider: SummaryProvider {
    func generateSummary(transcript: String, notes: String) async throws -> String {
        // Simulate processing
        try await Task.sleep(nanoseconds: 1_000_000_000)
        
        let date = Date().formatted(date: .long, time: .shortened)
        
        return """
        # Meeting Summary
        
        *Generated: \(date)*
        
        ## Overview
        [Placeholder] This summary was automatically generated.
        
        ## Key Points
        - [Placeholder] Point 1 from the discussion
        - [Placeholder] Point 2 from the discussion
        - [Placeholder] Point 3 from the discussion
        
        ## Action Items
        - [ ] [Placeholder] Action item 1
        - [ ] [Placeholder] Action item 2
        
        ## Notes Highlights
        \(notes.isEmpty ? "*No notes provided*" : notes.prefix(200))...
        
        ---
        *Enhanced summaries require LLM integration (Phase 5)*
        """
    }
}

class SummaryManager: ObservableObject {
    @Published var isGenerating = false
    
    private var provider: SummaryProvider = PlaceholderSummaryProvider()
    
    func setProvider(_ provider: SummaryProvider) {
        self.provider = provider
    }
    
    func generateSummary(transcript: String, notes: String) async throws -> String {
        await MainActor.run { isGenerating = true }
        defer { Task { @MainActor in isGenerating = false } }
        
        return try await provider.generateSummary(transcript: transcript, notes: notes)
    }
}
```

### 3.8 Info.plist Permissions

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>NSMicrophoneUsageDescription</key>
    <string>Alona needs microphone access to record your voice during meetings for transcription.</string>
    
    <key>NSScreenCaptureUsageDescription</key>
    <string>Alona needs screen recording permission to capture meeting audio from Zoom, Google Meet, and other apps.</string>
    
    <key>NSAppleEventsUsageDescription</key>
    <string>Alona needs automation permission to detect Google Meet tabs in your browser.</string>
    
    <key>NSAccessibilityUsageDescription</key>
    <string>Alona uses accessibility features to detect when you're in a meeting.</string>
    
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
```

---

## 4. Dependencies

| Dependency | Version | Purpose |
|------------|---------|---------|
| [SwiftWhisper](https://github.com/exPHAT/SwiftWhisper) | `master` branch | whisper.cpp Swift bindings for transcription |
| ggml-base.en.bin | ~142MB | Whisper model weights (bundled) |
| ScreenCaptureKit | macOS 12.3+ | System audio capture |
| AVFoundation | Built-in | Microphone capture, audio processing |

**Package.swift / Xcode SPM:**
```swift
dependencies: [
    .package(url: "https://github.com/exPHAT/SwiftWhisper.git", branch: "master")
]
```

---

## 5. Checklist

### Phase 1: Project Foundation & Permissions

- [X] **Task 1.1: Create Xcode project with SwiftUI lifecycle**
    - **Test Cases:**
        - [X] Project builds without errors on macOS 13+
        - [X] App launches and shows in menu bar and Dock

- [X] **Task 1.2: Configure Info.plist with all required permissions**
    - **Test Cases:**
        - [X] Microphone permission prompt appears on first mic access
        - [X] Screen Recording permission prompt/guidance appears
        - [X] Automation permission prompt appears when checking browser tabs

- [X] **Task 1.3: Implement PermissionManager service**
    - **Test Cases:**
        - [X] Can check microphone permission status
        - [X] Can request microphone permission
        - [X] Can check Screen Recording permission status
        - [X] Can open System Settings to relevant privacy pane

- [X] **Task 1.4: Create OnboardingView for permission wizard**
    - **Test Cases:**
        - [X] Shows checklist of required permissions
        - [X] Updates checkmarks as permissions are granted
        - [X] Provides buttons to open System Settings for each permission
        - [X] Can be dismissed when all permissions granted

- [X] **Task 1.5: Implement basic MenuBarExtra with status indicator**
    - **Test Cases:**
        - [X] Menu bar icon visible when app launches
        - [X] Icon changes when recording (record.circle vs record.circle.fill)
        - [X] Dropdown menu appears on click
        - [X] "Quit" menu item terminates the app

### Phase 2: Meeting Detection & File Management

- [X] **Task 2.1: Implement MeetingDetector service**
    - **Test Cases:**
        - [X] Detects when Zoom app launches
        - [X] Detects active Zoom meeting via UDP check
        - [X] Returns false when Zoom is open but not in meeting
        - [X] Detects Google Meet tab in Chrome via AppleScript
        - [X] Polling continues every 2 seconds
        - [X] When Automation permission is denied, MeetingDetector surfaces manual-start UI and no AppleScript crash occurs

- [X] **Task 2.2: Implement MeetingFileManager service**
    - **Test Cases:**
        - [X] Creates directory with format `YYYY-MM-DD_HHMM_<slug>/`
        - [X] Handles title sanitization (removes `/`, `:`, spaces)
        - [X] Appends suffix for collision avoidance (`-1`, `-2`)
        - [X] Can save notes.md file
        - [X] Can save transcript.txt and transcript.json files
        - [X] Can save summary.md file

- [X] **Task 2.3: Create SettingsView with directory picker**
    - **Test Cases:**
        - [X] Shows current save directory path
        - [X] "Choose Folder" button opens NSOpenPanel
        - [X] Selected directory is persisted in UserDefaults
        - [X] Default falls back to ~/Documents/Alona

- [X] **Task 2.4: Wire detection to UI with auto-start prompt**
    - **Test Cases:**
        - [X] When meeting detected, shows notification/prompt
        - [X] User can confirm to start recording
        - [X] User can dismiss to skip recording
        - [X] Manual "Start Recording" works without detection

### Phase 3: Audio Recording Pipeline

- [ ] **Task 3.1: Implement system audio capture via ScreenCaptureKit**
    - **Test Cases:**
        - [ ] SCStream starts successfully with audio configuration (16kHz mono)
        - [ ] Audio samples are received in stream output delegate
        - [ ] Audio samples buffered at 16kHz mono (later interleaved into dual-channel recording.wav)
        - [ ] Handles permission denial gracefully

- [ ] **Task 3.2: Implement microphone capture via AVAudioEngine**
    - **Test Cases:**
        - [ ] AVAudioEngine starts without errors
        - [ ] Audio tap receives microphone input at native sample rate
        - [ ] Audio resampled to 16kHz mono and buffered (later interleaved into dual-channel recording.wav)
        - [ ] Engine stops cleanly on stopRecording()

- [ ] **Task 3.3: Implement AudioRecorder service combining both sources**
    - **Test Cases:**
        - [ ] startRecording() creates meeting directory
        - [ ] Both system and mic recordings start
        - [ ] Duration timer updates every second
        - [ ] stopRecording() stops both captures
        - [ ] recording.wav contains two channels (system + mic)
        - [ ] recording-mono.wav is a 16kHz mono downmix for transcription
        - [ ] No separate recording-mic.wav file exists (PRD compliance)

- [ ] **Task 3.4: Add recording state to MenuBarView**
    - **Test Cases:**
        - [ ] "Start Recording" button visible when idle
        - [ ] "Stop Recording" button visible when recording
        - [ ] Recording duration displayed during recording
        - [ ] Menu bar icon reflects recording state

### Phase 4: Notes Interface & Autosave

- [ ] **Task 4.1: Create MeetingNotesView floating window**
    - **Test Cases:**
        - [ ] Window opens with notes TextEditor
        - [ ] Shows meeting title and duration
        - [ ] Shows recording indicator (red dot)
        - [ ] Window can be resized and repositioned

- [ ] **Task 4.2: Implement autosave (every 2 seconds)**
    - **Test Cases:**
        - [ ] notes.tmp created in meeting directory
        - [ ] Changes saved automatically after 2s debounce
        - [ ] Final notes.md saved on recording stop
        - [ ] notes.tmp is deleted after notes.md is finalized
        - [ ] After force-quitting during a meeting, reopening the app resumes notes from notes.tmp
        - [ ] Recovered notes are deleted once notes.md is finalized

- [ ] **Task 4.3: Add timestamp and bullet insert buttons**
    - **Test Cases:**
        - [ ] "Timestamp" button inserts `[MM:SS]` at cursor
        - [ ] "Bullet" button inserts `• ` at cursor
        - [ ] Buttons are accessible during recording

- [ ] **Task 4.4: Wire window opening to recording start**
    - **Test Cases:**
        - [ ] Notes window opens automatically when recording starts
        - [ ] Window can be opened manually from menu bar
        - [ ] Window content persists if closed and reopened

### Phase 5: Transcription & Summary

- [ ] **Task 5.1: Add SwiftWhisper dependency and bundle model**
    - **Test Cases:**
        - [ ] SwiftWhisper package resolves in Xcode via SPM (url: `https://github.com/exPHAT/SwiftWhisper.git`, branch: `master`)
        - [ ] ggml-base.en.bin (~142MB) added to Xcode project and included in "Copy Bundle Resources" build phase
        - [ ] Model file accessible via `Bundle.main.url(forResource: "ggml-base.en", withExtension: "bin")`
        - [ ] Model loads without errors at app launch using `Whisper(fromFileURL:)`
        - [ ] Build succeeds and .app bundle contains the model file in Resources/

- [ ] **Task 5.2: Implement TranscriptionEngine service**
    - **Test Cases:**
        - [ ] Converts audio to 16kHz mono PCM floats
        - [ ] Whisper transcription completes without errors
        - [ ] Progress updates received via delegate
        - [ ] Returns text and timestamped segments

- [ ] **Task 5.3: Implement automatic transcription after recording**
    - **Test Cases:**
        - [ ] Transcription starts automatically after stopRecording()
        - [ ] Progress shown in UI (or notification)
        - [ ] transcript.txt saved with plain text as valid UTF-8
        - [ ] transcript.json is valid UTF-8 JSON encoded from TranscriptSegmentRecord Codable struct
        - [ ] transcript.json encode/decode round-trip succeeds (can be decoded back)

- [ ] **Task 5.4: Implement PlaceholderSummaryProvider**
    - **Test Cases:**
        - [ ] Returns formatted markdown summary
        - [ ] Includes timestamp of generation
        - [ ] summary.md saved in meeting directory

- [ ] **Task 5.5: Add TranscriptionProgressView**
    - **Test Cases:**
        - [ ] Shows progress bar during transcription
        - [ ] Displays "Transcribing..." status
        - [ ] Shows "Complete" when done
        - [ ] Error state displayed if transcription fails

### Phase 6: Polish & Error Handling

- [ ] **Task 6.1: Add Finder reveal and notifications**
    - **Test Cases:**
        - [ ] "Reveal in Finder" opens meeting folder
        - [ ] Notification sent when transcription completes
        - [ ] Notification click opens meeting folder

- [ ] **Task 6.2: Implement error toasts/alerts**
    - **Test Cases:**
        - [ ] Permission denied shows helpful message
        - [ ] Recording failure shows error alert
        - [ ] Transcription failure shows retry option

- [ ] **Task 6.3: Add keyboard shortcuts**
    - **Test Cases:**
        - [ ] Cmd+Shift+R toggles recording
        - [ ] Cmd+, opens Settings
        - [ ] Cmd+Q quits app

- [ ] **Task 6.4: Final integration testing**
    - **Test Cases:**
        - [ ] Full flow: detect meeting → record → notes → stop → transcribe → summary
        - [ ] All files created in correct directory structure
        - [ ] App handles multiple meetings per day correctly
        - [ ] App recovers gracefully from unexpected quit

---

## 6. Definition of Done

- [ ] All Phase 1-6 checklist items completed
- [ ] App builds and runs on macOS 13+ (Ventura)
- [ ] App detects Zoom meetings and Google Meet tabs
- [ ] App records system audio and microphone
- [ ] App transcribes recordings with SwiftWhisper
- [ ] App generates placeholder summaries
- [ ] All files saved in flat `YYYY-MM-DD_HHMM_<slug>/` directories
- [ ] No Python or external runtime dependencies
- [ ] Manual testing confirms full user flow works

---

## Implementation Notes / Summary

### 2025-11-27 – Phase 1 bootstrap
- Added initial macOS SwiftUI MenuBarExtra app scaffold (`Alona/AlonaApp.swift`, `Alona/Views/*`, `Alona/Models/AppState.swift`) plus test target (`AlonaTests/AlonaTests.swift`).
- Implemented permission surfaces: `PermissionManager`, onboarding wizard, settings panel, and recording toggle per RFC Task 1.1–1.5 along with Info.plist entitlements.
- Introduced Xcode workspace/project (`Alona.xcworkspace`, `Alona.xcodeproj`), asset catalog, and developer tooling (`Makefile`, `buildServer.json`) to align with the CLI workflow.
- Commands executed: `xcode-build-server config -workspace Alona.xcworkspace -scheme Alona`, `make test`, `make lint`.

### 2025-11-27 – Phase 2 meeting detection
- Added `MeetingDetector` service that polls NSWorkspace activity, verifies Zoom RTP traffic via `lsof`, and queries Chrome tabs with AppleScript to identify Google Meet sessions, surfacing automation-permission failures gracefully.
- Extended unit tests (`AlonaTests/AlonaTests.swift`) with normalization coverage to guarantee meeting titles are sanitized before hitting UI.
- Updated the Xcode project (`Alona.xcodeproj/project.pbxproj`) so the new service participates in builds, and ran `make lint` plus `make test` to validate the additions.
- Expanded `MeetingFileManager` into a full-featured coordinator (directory creation, slug collisions, notes/transcripts/summaries, autosave recovery) with new transcription models, plus comprehensive unit tests that exercise slug formatting, collision handling, and file persistence; verified via `make lint` and `make test`.
- Wired the Settings workflow to `MeetingFileManager` by injecting it through `AppState`, ensuring the UI reflects persisted directories, and covered the flow with an `AppState` persistence test; validated with `make lint` and `make test`.
- Surfaced meeting detection signals inside `MenuBarView` (status banner + confirmation prompt) with new dismissal state in `AppState` and dependency-injected `MeetingDetector`, and added regression tests for the dismissal logic; verified with repeated `make lint` / `make test`.

### 2025-11-27 – Dev experience upgrades
- Added a `make run` target that reuses the `xcodebuild` pipeline and automatically launches the built `Alona.app`, answering the “can we run it locally?” workflow question.
- Integrated the [Inject](https://github.com/krzysztofzablocki/Inject) SPM package (`Alona.xcodeproj`, `Alona.xcworkspace/xcshareddata/swiftpm/Package.resolved`) and instrumented SwiftUI views (`MenuBarView`, `SettingsView`, `OnboardingView`) with `@ObserveInjection`/`.enableInjection()` under `#if DEBUG` so hot reloading works as recommended in the workspace rules.
- Commands executed: `xcodebuild -resolvePackageDependencies -workspace Alona.xcworkspace -scheme Alona`, `make test`, `make format`, `make lint`.

### 2025-11-27 – Dock-visible shell
- Updated `Alona/Info.plist` to set `LSUIElement` to `false`, keeping the menu-bar control but also showing the app in the Dock / Cmd-Tab to support the upcoming notes window workflow.
- Refreshed RFC Task 1.1 test cases to expect the icon in both the menu bar and Dock.
- Commands executed: `make test`.

### References

- [SwiftWhisper GitHub](https://github.com/exPHAT/SwiftWhisper) - Swift bindings for whisper.cpp
- [Apple ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit) - System audio capture
- [Apple AVFoundation](https://developer.apple.com/documentation/avfoundation) - Microphone and audio processing
- [Apple MenuBarExtra](https://developer.apple.com/documentation/swiftui/menubarextra) - Menu bar apps in SwiftUI
- [NSWorkspace Notifications](https://developer.apple.com/documentation/appkit/nsworkspace) - App detection

### Model Download & Bundling

```bash
# Download Whisper base.en model (~142MB)
curl -L -o ggml-base.en.bin https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin
```

**Xcode Bundling Steps (Critical for Phase 5.1):**

1. Place `ggml-base.en.bin` in `Alona/Resources/Models/` directory
2. In Xcode, drag the file into the project navigator under `Alona/Resources/`
3. Ensure "Copy items if needed" is checked
4. Verify the file appears in **Build Phases → Copy Bundle Resources**
5. If missing, manually add it to Copy Bundle Resources
6. Verify at runtime:
   ```swift
   guard let modelURL = Bundle.main.url(forResource: "ggml-base.en", withExtension: "bin") else {
       fatalError("Model not found in bundle - check Copy Bundle Resources")
   }
   ```

**SwiftWhisper API Usage (Context7 validated):**

```swift
// Initialize with bundled model
let whisper = Whisper(fromFileURL: modelURL)

// Transcribe requires 16kHz PCM float array
let segments = try await whisper.transcribe(audioFrames: pcmFloatArray)

// Access results
let text = segments.map(\.text).joined()
```

### File Layout (PRD-Aligned)

Each meeting creates a flat folder:
```
2025-11-27_1030_Product-Sync/
├── recording.wav        # Dual-channel: Ch0=system, Ch1=mic
├── recording-mono.wav   # 16kHz mono downmix for transcription
├── notes.md             # Final user notes
├── transcript.txt       # Plain text transcript
├── transcript.json      # Timestamped segments (Codable)
└── summary.md           # Enhanced summary (placeholder)
```

**No extra files:** `notes.tmp` is deleted after `notes.md` is saved; no separate `recording-mic.wav`.

### Known Limitations (MVP)

1. **Google Meet detection** requires Automation permission and only works with Chrome (Safari support is similar but separate AppleScript). Falls back to manual start if permission denied.
2. **BlackHole fallback** for older macOS not implemented in MVP - requires separate user setup
3. **Speaker diarization** not included - dual-channel preserved for future work
4. **Real LLM summaries** use placeholder - Phase 5 stretch goal

---

*This section will be updated during implementation with file paths, commands executed, and any deviations from the plan.*

