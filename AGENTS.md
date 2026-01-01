# AGENTS.md - Alona Development Guidelines

Guidelines for AI agents (Cursor, Copilot, Claude, etc.) and human contributors working on this macOS app.

---

## Project Overview

**Alona** is a macOS meeting assistant that detects active meetings (Zoom, Google Meet), captures audio, transcribes locally using Whisper, and generates summaries.

| Attribute | Value |
|-----------|-------|
| Build System | Xcode workspace (`Alona.xcworkspace`) + Makefile |
| Platform | macOS 14.6+ (arm64) |
| Swift Version | 6.0 |
| UI Framework | SwiftUI with `MenuBarExtra` |
| State Management | `@Observable` / `@State` / `@Environment` |

---

## Build, Test, Run Commands

**Always run these after making changes:**

```bash
# Full dev loop (preferred)
make test                    # Kill app, build, run tests

# Individual commands
make build                   # Build only
make run                     # Build and launch app
make lint                    # Check formatting (swiftformat --lint)
make format                  # Apply formatting fixes
make clean                   # Clean DerivedData
make setup                   # Regenerate buildServer.json
make download-model          # Fetch Whisper model if missing
```

### Verification Checklist

Before considering any task complete, verify:

1. ✅ `make test` — All tests pass
2. ✅ `make lint` — No formatting issues
3. ✅ No compiler warnings in the build output

---

## Project Structure

```
Alona/
├── AlonaApp.swift           # App entry, MenuBarExtra, WindowGroups
├── AppDelegate.swift        # NSApplicationDelegate
├── Models/
│   ├── AppState.swift       # @Observable main state container
│   └── TranscriptionResult.swift
├── Services/
│   ├── AudioRecorder.swift  # @Observable - CoreAudio process tap + mic capture
│   ├── MeetingDetector.swift # @Observable - detects Zoom/Meet
│   ├── PermissionManager.swift # @Observable - permission handling
│   ├── TranscriptionEngine.swift # @Observable - Whisper integration
│   └── ...
├── Views/
│   ├── MenuBarView.swift    # Main menu bar UI
│   ├── StartupView.swift    # Primary window
│   └── ...
└── Resources/
    └── Models/              # Whisper model files (ggml-base.en.bin)

AlonaTests/
├── TestHelpers.swift        # Shared mocks and harnesses
├── AppStateTests.swift      # AppState behavior tests
├── MeetingFileManagerTests.swift
├── MeetingDetectorTests.swift
├── AudioTests.swift         # Audio processing, CoreAudio
├── TranscriptionTests.swift
├── PermissionTests.swift
├── MicrophoneTrackerTests.swift
└── WindowControllerTests.swift
```

---

## Coding Style

### SwiftFormat

Run `make format` before committing. Key rules:
- 4-space indentation
- Explicit `self` where required for Swift concurrency
- Modern trailing closure syntax

### State Management (IMPORTANT)

**Use modern Observation framework:**

| ✅ Use | ❌ Avoid |
|--------|----------|
| `@Observable` | `ObservableObject` |
| `@State` | `@StateObject` |
| `@Environment(Type.self)` | `@EnvironmentObject` |
| `.environment(object)` | `.environmentObject(object)` |
| `@Bindable var x = x` | `$object.property` without Bindable |

**Exception:** Classes extending `NSObject` (e.g., `RecordingAudioPlayer` for `AVAudioPlayerDelegate`) must use `ObservableObject`.

### Bindings with @Observable

When a view needs to create a binding to an `@Observable` property:

```swift
struct SettingsView: View {
    @Environment(AppState.self) private var appState
    
    var body: some View {
        @Bindable var appState = appState  // Create bindable at start of body
        Toggle("Option", isOn: $appState.someProperty)
    }
}
```

### Concurrency

- Mark UI-related classes with `@MainActor`
- Use `Task.detached` for background work, with `guard let self else { return }` before `MainActor.run`
- Prefer `async/await` over Combine for new code
- Keep Combine for interop with legacy/NSObject classes that expose publishers

### SwiftUI onChange

Use modern `onChange` syntax (macOS 14+):

```swift
// ✅ Correct
.onChange(of: value) { }                      // Zero-param
.onChange(of: value) { oldValue, newValue in } // Two-param

// ❌ Deprecated
.onChange(of: value) { newValue in }          // One-param (deprecated)
```

---

## Testing Guidelines

### Running Tests

```bash
make test   # Runs all tests, kills any running Alona instance first
```

### Writing Tests

- Add tests to the appropriate `*Tests.swift` file by subsystem (see Project Structure)
- Use `@MainActor` for tests involving main-actor-isolated types
- Use test harnesses with cleanup (see `MeetingFileManagerTestHarness` in `TestHelpers.swift`)
- Mock external dependencies (see `MockAudioRecorder`, `MockTranscriptionEngine` in `TestHelpers.swift`)

### Test Naming

```swift
func testFeatureNameBehaviorDescription() { ... }
// Example: testNotesAutosaveAndFinalize()
```

---

## Common Tasks

### Adding a New View

1. Create `Views/NewView.swift`
2. Use `@Environment(AppState.self)` for state access
3. Add to appropriate `WindowGroup` in `AlonaApp.swift`
4. Add preview with `.environment(AppState())`

### Adding a New Service

1. Create `Services/NewService.swift`
2. Use `@Observable` macro (unless NSObject required)
3. Inject via `@Environment` or pass directly
4. Add tests for public API

### Modifying AppState

1. Add/modify properties in `Alona/Models/AppState.swift`
2. Properties are automatically observable (no `@Published` needed)
3. For debounced behavior, use Task-based debouncing in `didSet`
4. Run `make test` to verify no regressions

---

## What to Avoid

1. **Don't use `@StateObject` / `@ObservableObject` / `@EnvironmentObject`** for new code
2. **Don't use deprecated `onChange(of:perform:)`** — use zero or two-param version
3. **Don't block the main thread** — use `Task.detached` for slow operations
4. **Don't skip tests** — always run `make test` before considering work complete
5. **Don't create new files without tests** for non-trivial logic
6. **Don't use `print()` for debugging** — use `Logger` from OSLog

---

## Permissions Required

The app requires these macOS permissions:
- **Microphone** — Voice capture
- **System Audio Recording** — Meeting participant audio (CoreAudio Process Taps)
- **Accessibility** — Zoom UI state detection
- **Automation** — Google Meet tab detection via AppleScript

Permission handling is in `Services/PermissionManager.swift`.

---

## Whisper Model

The app uses `ggml-base.en.bin` for transcription:

```bash
make download-model   # Downloads to Alona/Resources/Models/
```

Or manually download from: https://huggingface.co/ggerganov/whisper.cpp

---

## Troubleshooting

### SourceKit/Autocomplete Not Working

```bash
make setup   # Regenerate buildServer.json
make build   # Force a clean build
```

### Tests Fail with Permission Errors

```bash
# Use a fresh DerivedData to reset TCC permissions
DERIVED_DATA_PATH=/tmp/alona-test-$$ make test
```

### App Not Launching

```bash
killall Alona 2>/dev/null  # Kill any stuck instances
make run
```

---

## Reference Documentation

- [RFC-001: Alona MVP Implementation](docs/rfcs/RFC-001-alona-mvp-full-implementation.md)
- [PRD: Alona macOS MVP](docs/PRD-alona-macos-mvp-2025-11-27.md)

