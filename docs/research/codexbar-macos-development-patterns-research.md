# CodexBar macOS Development Patterns Research

**Research Date:** December 27, 2025  
**Source Repository:** https://github.com/steipete/CodexBar  
**Purpose:** Study and document macOS development patterns, agentic development practices, and standards from an experienced Swift/macOS developer (Peter Steinberger) who uses AI agents for development.

---

## Executive Summary

CodexBar is a macOS 15+ menu bar app built by Peter Steinberger using Swift 6.2 and SwiftPM. It demonstrates professional-grade macOS development patterns suitable as a baseline standard for the Alona project. Key takeaways include:

1. **Modern Swift 6 with strict concurrency** enabled via `.enableUpcomingFeature("StrictConcurrency")`
2. **SwiftPM-only builds** (no Xcode project files for the main build)
3. **Comprehensive agentic development guidelines** via `AGENTS.md`
4. **Extensive test coverage** with 50+ test files
5. **Automated build/test/run scripts** for developer and agent workflows
6. **Modern SwiftUI + Observation framework** (macros like `@Observable`, `@State`)
7. **Menu bar implementation using AppKit's NSStatusItem** (not SwiftUI MenuBarExtra)

---

## 1. Project Structure

### 1.1 Directory Layout

```
CodexBar/
├── AGENTS.md                    # Agentic development guidelines
├── CHANGELOG.md                 # Version history
├── Package.swift                # SwiftPM manifest (Swift 6.2)
├── .swiftformat                 # SwiftFormat configuration
├── .swiftlint.yml               # SwiftLint rules
├── Sources/
│   ├── CodexBar/                # Main macOS app (UI + Controllers)
│   │   ├── CodexbarApp.swift    # @main App entry point
│   │   ├── StatusItemController.swift  # NSStatusItem menu bar
│   │   ├── StatusItemController+Menu.swift
│   │   ├── StatusItemController+Animation.swift
│   │   ├── StatusItemController+Actions.swift
│   │   ├── Providers/           # Provider-specific code (siloed)
│   │   │   ├── Claude/
│   │   │   ├── Codex/
│   │   │   ├── Cursor/
│   │   │   ├── Gemini/
│   │   │   ├── Zai/
│   │   │   ├── Antigravity/
│   │   │   └── Shared/          # Shared provider infrastructure
│   │   ├── Preferences*.swift   # Settings panes
│   │   └── Menu*.swift          # Menu-related views
│   ├── CodexBarCore/            # Cross-platform core logic
│   │   ├── Host/                # Shared host APIs (Keychain, cookies, PTY)
│   │   ├── Providers/           # Provider probes/fetchers/parsers
│   │   ├── Logging/             # Logging infrastructure
│   │   └── *.swift              # Core models and utilities
│   ├── CodexBarCLI/             # CLI executable
│   ├── CodexBarWidget/          # macOS widget
│   └── CodexBarClaudeWatchdog/  # Auxiliary executable
├── Tests/
│   └── CodexBarTests/           # XCTest suite (50+ test files)
├── Scripts/
│   ├── compile_and_run.sh       # Dev loop: kill, build, test, package, relaunch
│   ├── package_app.sh           # Bundle .app
│   ├── sign-and-notarize.sh     # Code signing + notarization
│   ├── make_appcast.sh          # Sparkle appcast generation
│   └── release.sh               # Full release automation
├── docs/
│   ├── provider.md              # Provider authoring guide
│   ├── RELEASING.md             # Release checklist
│   └── cli.md                   # CLI documentation
└── .github/workflows/
    ├── ci.yml                   # CI: lint, build, test
    └── release-cli.yml          # CLI release workflow
```

### 1.2 Key Observations

| Aspect | CodexBar Pattern | Alona Current State |
|--------|-----------------|---------------------|
| Build System | SwiftPM only | Xcode project + workspace |
| Platform Target | macOS 15+ | macOS (version TBD) |
| Swift Version | 6.2 with StrictConcurrency | Likely older |
| UI Layer Split | CodexBar (UI) + CodexBarCore (logic) | Single Alona target |
| Test Organization | Feature-based test files | Minimal tests |

---

## 2. Package.swift Configuration

### 2.1 Dependencies

```swift
dependencies: [
    .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.8.1"),
    .package(url: "https://github.com/steipete/Commander", from: "0.2.0"),
    .package(url: "https://github.com/apple/swift-log", from: "1.8.0"),
]
```

### 2.2 Target Structure

```swift
.target(
    name: "CodexBarCore",
    dependencies: [
        .product(name: "Logging", package: "swift-log"),
    ],
    swiftSettings: [
        .enableUpcomingFeature("StrictConcurrency"),
    ])
```

**Key Pattern:** Core logic is separated into `CodexBarCore` (cross-platform) while UI lives in `CodexBar` (macOS only).

---

## 3. AGENTS.md - Agentic Development Guidelines

This is critical for understanding how to prompt AI agents effectively. Key sections:

### 3.1 Build, Test, Run Commands

```bash
# Dev loop (preferred for agents)
./Scripts/compile_and_run.sh   # Kill, build, test, package, relaunch, verify

# Quick commands
swift build                     # Debug build
swift build -c release          # Release build
swift test                      # Run full XCTest suite

# Package locally
./Scripts/package_app.sh        # Refresh CodexBar.app
```

### 3.2 Coding Style & Naming

> "Enforce SwiftFormat/SwiftLint: run `swiftformat Sources Tests` and `swiftlint --strict`. 4-space indent, 120-char lines, explicit `self` is intentional—do not remove."

### 3.3 Testing Guidelines

> "Add/extend XCTest cases under `Tests/CodexBarTests/*Tests.swift` (`FeatureNameTests` with `test_caseDescription` methods). Always run `swift test` before handoff."

### 3.4 Agent-Specific Notes

Key rules for AI agents:
- **Always rebuild and restart** using `./Scripts/compile_and_run.sh` after code changes
- **Prefer modern SwiftUI/Observation macros**: Use `@Observable` models with `@State` ownership and `@Bindable` in views
- **Avoid legacy patterns**: No `ObservableObject`, `@ObservedObject`, `@StateObject`
- **Favor modern macOS 15+ APIs** over deprecated counterparts

---

## 4. Menu Bar Implementation Comparison

### 4.1 CodexBar Approach (AppKit NSStatusItem)

**`Sources/CodexBar/StatusItemController.swift`:**

```swift
import AppKit
import Observation
import QuartzCore
import SwiftUI

// MARK: - Status item controller (AppKit-hosted icons, SwiftUI popovers)

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate, StatusItemControlling {
    let store: UsageStore
    let settings: SettingsStore
    var statusItem: NSStatusItem
    var statusItems: [UsageProvider: NSStatusItem] = [:]
    
    init(store: UsageStore, settings: SettingsStore, ...) {
        self.store = store
        self.settings = settings
        let bar = NSStatusBar.system
        let item = bar.statusItem(withLength: NSStatusItem.variableLength)
        // Ensure the icon is rendered at 1:1 without resampling
        item.button?.imageScaling = .scaleNone
        self.statusItem = item
        // ... per-provider status items
        super.init()
        self.wireBindings()
        self.updateIcons()
        self.updateVisibility()
    }
    
    private func wireBindings() {
        self.observeStoreChanges()
        self.observeSettingsChanges()
        self.observeUpdaterChanges()
    }
    
    private func observeStoreChanges() {
        withObservationTracking {
            _ = self.store.menuObservationToken
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observeStoreChanges()
                self?.invalidateMenus()
                self?.updateIcons()
            }
        }
    }
}
```

**Key Patterns:**
1. Uses `NSStatusBar.system.statusItem()` for the menu bar icon
2. Manages multiple `NSStatusItem` instances (one per provider)
3. Uses the modern **Observation framework** with `withObservationTracking`
4. Implements `NSMenuDelegate` for menu lifecycle
5. Custom icon rendering with `NSStatusItem.variableLength`
6. Separates concerns into extension files (`+Menu`, `+Animation`, `+Actions`)

### 4.2 Alona Current Approach (SwiftUI MenuBarExtra)

**`Alona/AlonaApp.swift`:**

```swift
@main
struct AlonaApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var permissionManager = PermissionManager()
    @StateObject private var meetingDetector: MeetingDetector
    @State private var showMenuBarExtra = true
    
    var body: some Scene {
        WindowGroup { ... }
        
        MenuBarExtra("Alona", systemImage: "note.text", isInserted: $showMenuBarExtra) {
            MenuBarView()
                .environmentObject(appState)
                .environmentObject(permissionManager)
                .environmentObject(meetingDetector)
        }
        .menuBarExtraStyle(.window)
        .defaultSize(width: 360, height: 320)
    }
}
```

### 4.3 Comparison Analysis

| Aspect | CodexBar (NSStatusItem) | Alona (MenuBarExtra) |
|--------|------------------------|---------------------|
| API | AppKit `NSStatusItem` | SwiftUI `MenuBarExtra` |
| Introduced | macOS 10.0+ | macOS 13+ |
| Icon Control | Full control via `NSImage` | System SF Symbols only |
| Menu Control | NSMenu with full customization | SwiftUI View or Menu |
| Animation | CADisplayLink for icon animations | Limited |
| Multiple Items | Easy (multiple NSStatusItem) | Not supported |
| Modern API | ❌ (but more powerful) | ✅ |

**Verdict:** 
- **Alona's SwiftUI `MenuBarExtra` approach is valid and more modern** for simple menu bar needs
- CodexBar uses `NSStatusItem` because it needs **multiple status items** (one per provider), **custom icon animations**, and **dynamic icon rendering** that SwiftUI can't provide
- For Alona's use case (single menu bar icon with a window popover), `MenuBarExtra` is appropriate

---

## 5. App Entry Point & Architecture

### 5.1 CodexBar Pattern

```swift
@main
struct CodexBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var settings: SettingsStore       // Modern @State
    @State private var store: UsageStore             // Modern @State
    
    init() {
        // Bootstrap logging
        CodexBarLog.bootstrapIfNeeded(...)
        
        let settings = SettingsStore()
        let fetcher = UsageFetcher()
        let account = fetcher.loadAccountInfo()
        let store = UsageStore(fetcher: fetcher, settings: settings)
        
        _settings = State(wrappedValue: settings)
        _store = State(wrappedValue: store)
        
        // Configure AppDelegate with dependencies
        self.appDelegate.configure(store: store, settings: settings, ...)
    }
    
    var body: some Scene {
        // Hidden window to keep SwiftUI lifecycle alive
        WindowGroup("CodexBarLifecycleKeepalive") {
            HiddenWindowView()
        }
        .windowStyle(.hiddenTitleBar)
        
        Settings {
            PreferencesView(settings: self.settings, store: self.store, ...)
        }
    }
}
```

**Key Differences from Alona:**
1. Uses `@State` instead of `@StateObject` (modern Observation pattern)
2. Dependency injection via init instead of default values
3. AppDelegate is configured explicitly with dependencies
4. Hidden window trick for lifecycle management (no `MenuBarExtra`)

### 5.2 Alona Pattern

```swift
@main
struct AlonaApp: App {
    @StateObject private var appState = AppState()       // Legacy pattern
    @StateObject private var permissionManager = PermissionManager()
    @StateObject private var meetingDetector: MeetingDetector
    
    var body: some Scene {
        WindowGroup { StartupView() }
        MenuBarExtra(...) { MenuBarView() }
        // ... more windows
    }
}
```

**Issues to Address:**
1. Uses `@StateObject` (legacy) instead of `@State` with `@Observable` models
2. Models should be `@Observable` class, not `ObservableObject`

---

## 6. Testing Patterns

### 6.1 Test File Organization

CodexBar has **50+ test files** organized by feature:

```
Tests/CodexBarTests/
├── ClaudeUsageTests.swift        # Provider-specific parsing
├── CursorStatusProbeTests.swift  # API response parsing
├── GeminiStatusProbeTests.swift  # Multiple test files per feature
├── StatusMenuTests.swift         # UI behavior tests
├── ProviderRegistryTests.swift   # Registry logic
├── SettingsStoreTests.swift      # Settings persistence
└── ...
```

### 6.2 Test Naming Convention

```swift
final class ClaudeUsageTests: XCTestCase {
    func test_parseUsageOutput_validPercentages() { ... }
    func test_parseUsageOutput_invalidFormat() { ... }
    func test_parseStatus_loggedIn() { ... }
}
```

Pattern: `test_<methodName>_<scenario>`

### 6.3 Test Categories

1. **Parsing tests** - Validate text/JSON parsing logic
2. **API response tests** - Mock responses and validate handling
3. **Settings tests** - UserDefaults persistence
4. **UI state tests** - Menu state, visibility logic
5. **Integration tests** - TTY/subprocess interaction

---

## 7. CI/CD Pipeline

### 7.1 GitHub Actions CI (`.github/workflows/ci.yml`)

```yaml
name: CI
on: [push, pull_request]

jobs:
  lint-build-test:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v6
      - name: Select Xcode 26.1.1
        run: sudo xcode-select -s /Applications/Xcode_26.1.1.app
      - name: Install Swift 6.2 toolchain
        run: |
          curl -L https://download.swift.org/swift-6.2-release/xcode/swift-6.2-RELEASE/swift-6.2-RELEASE-osx.pkg -o /tmp/swift.pkg
          sudo installer -pkg /tmp/swift.pkg -target /
      - name: Install lint tools
        run: brew install swiftlint swiftformat
      - name: SwiftFormat (lint)
        run: swiftformat Sources Tests --lint
      - name: SwiftLint
        run: swiftlint --strict
      - name: Swift Test
        run: swift test --parallel
```

### 7.2 Key CI Requirements

1. **SwiftFormat lint check** before tests
2. **SwiftLint strict mode** enforcement
3. **Parallel test execution** for speed
4. **Cross-platform** testing (macOS + Linux for CLI)

---

## 8. Code Style & Linting

### 8.1 SwiftFormat Configuration (`.swiftformat`)

```bash
--self insert              # Insert self for member references (Swift 6 required)
--indent 4                 # 4-space indent
--maxwidth 120             # 120-char line limit
--swiftversion 6.2         # Swift 6.2 syntax
--importgrouping testable-bottom
--wraparguments before-first
--organizetypes class,struct,enum,extension
--markextensions always
```

### 8.2 SwiftLint Configuration (`.swiftlint.yml`)

Key rules:
- **Analyzer rules enabled:** `unused_declaration`, `unused_import`
- **Opt-in rules:** `empty_string`, `first_where`, `fatal_error_message`
- **Disabled for Swift 6:** `explicit_self` (Swift 6 requires explicit self)
- **Line length:** 120 warning, 250 error
- **Function body length:** 150 warning, 300 error

---

## 9. Development Scripts

### 9.1 `Scripts/compile_and_run.sh`

This is the critical script for agentic development:

```bash
#!/usr/bin/env bash
# Reset CodexBar: kill running instances, build, package, relaunch, verify.

set -euo pipefail

# 1) Acquire lock (prevent parallel agent runs)
acquire_lock

# 2) Kill all running CodexBar instances
kill_all_codexbar
kill_claude_probes  # Clean up orphaned processes

# 3) Build and optionally test
run_step "swift build" swift build -q
if [[ "${RUN_TESTS}" == "1" ]]; then
  run_step "swift test" swift test -q
fi

# 4) Package the app
run_step "package app" "${ROOT_DIR}/scripts/package_app.sh"

# 5) Launch and verify it stays running
open "${APP_BUNDLE}"
for _ in {1..10}; do
  if pgrep -f "${APP_PROCESS_PATTERN}" >/dev/null 2>&1; then
    log "OK: CodexBar is running."
    exit 0
  fi
  sleep 0.4
done
fail "App exited immediately."
```

**Key Features:**
- **Lock mechanism** to prevent parallel agent compilation
- **Process cleanup** before rebuild
- **Build + test + package** in one step
- **Verification** that app stays running

---

## 10. Observation Framework Usage

### 10.1 Modern Pattern (CodexBar)

```swift
@Observable
final class UsageStore {
    var menuObservationToken: Int = 0  // Observation trigger
    
    func notifyChange() {
        self.menuObservationToken &+= 1
    }
}

// In view/controller:
withObservationTracking {
    _ = self.store.menuObservationToken
} onChange: { [weak self] in
    Task { @MainActor in
        self?.updateUI()
    }
}
```

### 10.2 Legacy Pattern (Alona - to be updated)

```swift
class AppState: ObservableObject {       // ❌ Legacy
    @Published var isRecording = false   // ❌ Legacy
}

@StateObject private var appState = AppState()  // ❌ Legacy
```

**Recommended Update:**

```swift
@Observable
final class AppState {                   // ✅ Modern
    var isRecording = false              // ✅ Modern (no @Published needed)
}

@State private var appState = AppState() // ✅ Modern
```

---

## 11. Release Process

### 11.1 Key Steps (from `docs/RELEASING.md`)

1. **Update versions** (Package.swift, Info.plist, CHANGELOG)
2. **Run linting:** `swiftformat`, `swiftlint --strict`
3. **Run tests:** `swift test`
4. **Build icon:** `./Scripts/build_icon.sh`
5. **Sign and notarize:** `./Scripts/sign-and-notarize.sh`
6. **Generate Sparkle appcast:** `./Scripts/make_appcast.sh`
7. **Upload to GitHub Releases**
8. **Verify** appcast URL and download links

### 11.2 Notarization Requirements

- Developer ID Application certificate
- App Store Connect API credentials
- Sparkle Ed25519 private key
- Deep + timestamp signing for all frameworks

---

## 12. Recommendations for Alona

Based on this research, here are specific recommendations:

### 12.1 Critical Updates

| Priority | Recommendation |
|----------|---------------|
| HIGH | Migrate to `@Observable` from `ObservableObject` |
| HIGH | Create `AGENTS.md` with development guidelines |
| HIGH | Add `compile_and_run.sh` script for dev workflow |
| MEDIUM | Add SwiftFormat/SwiftLint configuration |
| MEDIUM | Increase test coverage significantly |
| LOW | Consider SwiftPM-only build (optional) |

### 12.2 Menu Bar Implementation

**Current Alona approach is valid.** The `MenuBarExtra` with `.window` style is appropriate for a single-icon menu bar app with a popover window. No changes needed unless you require:
- Multiple menu bar icons
- Custom animated icons
- Dynamic icon rendering

### 12.3 Testing Strategy

Target coverage for:
1. **Audio recording** - Mock audio capture, verify state transitions
2. **Transcription** - Mock Whisper responses, verify parsing
3. **Meeting detection** - Mock AppleScript responses
4. **Permission manager** - Mock permission states
5. **File management** - Test file operations

### 12.4 AGENTS.md Template for Alona

```markdown
# Alona Repository Guidelines

## Build, Test, Run
- Dev loop: `./Scripts/compile_and_run.sh`
- Quick build: `swift build` or `xcodebuild`
- Tests: `swift test`

## Coding Style
- Use SwiftFormat: `swiftformat Sources Tests`
- Use SwiftLint: `swiftlint --strict`
- Modern Observation: `@Observable`, not `ObservableObject`

## Testing Guidelines
- Add tests under `AlonaTests/`
- Naming: `test_<method>_<scenario>`
- Always run tests before handoff

## Agent Notes
- Rebuild with compile_and_run.sh after changes
- Prefer modern macOS 15+ APIs
- Keep audio/transcription logic testable
```

---

## 13. Files to Reference

For implementation details, clone and examine these files:

1. **App Architecture:** `Sources/CodexBar/CodexbarApp.swift`
2. **Menu Bar:** `Sources/CodexBar/StatusItemController*.swift`
3. **Settings:** `Sources/CodexBar/SettingsStore.swift`
4. **Testing:** `Tests/CodexBarTests/StatusMenuTests.swift`
5. **Scripts:** `Scripts/compile_and_run.sh`
6. **Agent Guide:** `AGENTS.md`
7. **Linting:** `.swiftformat`, `.swiftlint.yml`

---

## 14. Summary

CodexBar demonstrates professional macOS development patterns that Alona should adopt:

1. ✅ **Modern Swift 6 with strict concurrency**
2. ✅ **Observation framework** (`@Observable` instead of `ObservableObject`)
3. ✅ **Comprehensive test coverage**
4. ✅ **Automated build/test scripts** for agent workflows
5. ✅ **SwiftFormat/SwiftLint** enforcement
6. ✅ **Clear agent guidelines** (`AGENTS.md`)
7. ✅ **Separation of concerns** (Core vs UI modules)

The Alona menu bar implementation using `MenuBarExtra` is valid and modern - no changes needed there. Focus should be on modernizing the state management and adding testing infrastructure.

