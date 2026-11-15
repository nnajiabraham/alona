# Alona Design System Research

**Document Purpose:** This document captures all UI components, screens, features, user flows, and states in the Alona macOS app. It is intended for a design engineer to create a cohesive design system with typography, color palettes, spacing, and component specifications.

**Date:** January 2026  
**App Version:** MVP (Post-implementation)  
**Platform:** macOS 14.6+ (Apple Silicon)

---

## Table of Contents

1. [App Overview](#app-overview)
2. [Application Architecture](#application-architecture)
3. [Screens & Windows](#screens--windows)
4. [Components Library](#components-library)
5. [User Flows](#user-flows)
6. [States & Conditions](#states--conditions)
7. [Current Styling Audit](#current-styling-audit)
8. [Design System Recommendations](#design-system-recommendations)

---

## App Overview

**Alona** is a macOS meeting assistant that:
- Detects active meetings (Zoom, Google Meet)
- Captures audio (microphone + system audio)
- Transcribes locally using Whisper AI models
- Allows users to take timestamped notes during meetings
- Generates meeting summaries

### App Entry Points

| Entry Point | Type | Description |
|-------------|------|-------------|
| Menu Bar | `MenuBarExtra` | Always-visible icon with dropdown panel |
| Startup Window | `WindowGroup` | Main dashboard window |
| Floating Popup | `NSWindow` | Meeting detection notification |

---

## Application Architecture

### Window Types

```
┌─────────────────────────────────────────────────────────────────┐
│                        WINDOW HIERARCHY                         │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌─────────────┐   Primary Windows (Always Available)          │
│  │ Menu Bar    │ ─────────────────────────────────────         │
│  │ Extra       │   • MenuBarView (360×320 dropdown)            │
│  └─────────────┘   • StartupView (420×380 main window)         │
│                                                                 │
│  ┌─────────────┐   Secondary Windows (On Demand)               │
│  │ Window      │ ─────────────────────────────────────         │
│  │ Groups      │   • SettingsView (500×560)                    │
│  └─────────────┘   • OnboardingView (420×420)                  │
│                    • RecordingsBrowserView (split view)         │
│                    • MeetingNotesView (420×360)                 │
│                    • TranscriptionQueueView (460×420)           │
│                                                                 │
│  ┌─────────────┐   Floating Windows                            │
│  │ NSWindow    │ ─────────────────────────────────────         │
│  │ (Custom)    │   • MeetingDetectedPopup (340×80)             │
│  └─────────────┘                                               │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## Screens & Windows

### 1. Menu Bar View

**File:** `MenuBarView.swift`  
**Size:** 360×320 (dropdown panel)  
**Type:** `MenuBarExtra` with `.window` style

#### Sections

| Section | Components | Purpose |
|---------|------------|---------|
| Header | Title + Subtitle | App name + current meeting title |
| Detection Status | Status indicator + Label | Shows meeting detection state |
| Detection Prompt | Card with buttons | Appears when meeting detected |
| Recording Controls | Primary button + Duration | Start/stop recording |
| Transcription Progress | Progress bar + Status | Shows during post-processing |
| Permissions Summary | List of permission rows | Quick permission status |
| Footer Actions | Button group | Recordings, Startup, Quit |

#### User Stories

- **US-MB-1:** As a user, I want to see at a glance if a meeting is detected
- **US-MB-2:** As a user, I want to start/stop recording with one click
- **US-MB-3:** As a user, I want to quickly access recordings
- **US-MB-4:** As a user, I want to see transcription progress

---

### 2. Startup View (Main Dashboard)

**File:** `StartupView.swift`  
**Size:** 420×380 minimum  
**Type:** Primary `WindowGroup`

#### Sections

| Section | Components | Purpose |
|---------|------------|---------|
| Header | Title + Status badge | Welcome message + current state |
| Detection Status/Prompt | Conditional content | Shows idle or meeting prompt |
| Controls | Button groups (2 rows) | Primary actions and navigation |
| Model Status | Label + Download button | Whisper model availability |
| Permission Summary | Permission list | All permission statuses |

#### Layout Hierarchy

```
VStack(alignment: .leading, spacing: 16)
├── header (VStack)
│   ├── "Welcome to Alona" (title2, bold)
│   └── Status text (colored based on state)
├── detectionStatus OR detectionPrompt (conditional)
├── Divider
├── controls (VStack)
│   ├── HStack: [Start Recording, Recordings, Current Notes?]
│   └── HStack: [Settings, Permissions, Queue]
├── Spacer
└── footer (VStack)
    ├── modelStatusSection
    └── permissionSummary
```

#### States

| State | Visual Indicator | Actions Available |
|-------|------------------|-------------------|
| Idle | "Idle" (secondary text), gray dot | Start Recording |
| Meeting Detected | Orange card, green dot | Start Recording, Dismiss |
| Recording | "Recording in progress" (red) | Stop Recording, Current Notes |
| Transcribing | Progress indicator | View Queue |

---

### 3. Settings View

**File:** `SettingsView.swift`  
**Size:** 500×560  
**Type:** Secondary `WindowGroup`

#### Sections

| Section | Components | Purpose |
|---------|------------|---------|
| Recording | Toggle + Help text | System audio capture setting |
| Transcription Model | Model selector + Download UI | Whisper model management |
| Storage | Path display + Folder picker | Recording save location |

#### Model Selection Subcomponents

```
ModelSelectionView
├── Active Model Status Card
│   ├── "Active Model" label
│   ├── Model name (medium weight)
│   └── Status badge (Ready/Download Required)
├── Model List (ScrollView, max 5 visible)
│   └── ModelRowView (foreach)
│       ├── Selection radio (circle/checkmark)
│       ├── Model info (name, badges, specs)
│       └── Status/Action (download/progress/menu)
├── Show All Models toggle
└── Download Log (conditional)
    └── DownloadLogView
        ├── Header with Clear button
        └── Log entries (ScrollView)
```

#### Model Row States

| State | Visual | Actions |
|-------|--------|---------|
| Not Downloaded | "Download" button | Click to download |
| Downloading | Progress bar + Speed + ETA + Cancel | Cancel download |
| Available | Green checkmark + Ellipsis menu | Delete model |
| Failed | Red warning + "Retry" button | Retry download |

---

### 4. Onboarding/Permissions View

**File:** `OnboardingView.swift`  
**Size:** 420×420 minimum  
**Type:** Secondary `WindowGroup`

#### Sections

| Section | Components | Purpose |
|---------|------------|---------|
| Header | Title + Description | Welcome and explanation |
| Permissions List | PermissionRow cards | Each permission type |
| Footer | Refresh + Close buttons | Actions |

#### Permission Row Component

```
PermissionRow
├── Header row
│   ├── Permission title (headline)
│   └── Status badge (colored background)
└── Action row
    ├── "Request Access" button
    └── "Open Settings" button
```

#### Permission Types

| Permission | macOS Setting | Purpose |
|------------|---------------|---------|
| Microphone | Privacy > Microphone | Voice capture |
| System Audio | Screen Recording | Meeting participant audio |
| Accessibility | Accessibility | Zoom UI state detection |
| Automation | Automation | Google Meet tab detection |

#### Permission States

| State | Badge Color | Badge Text |
|-------|-------------|------------|
| Granted | Green (0.2 opacity) | "Granted" |
| Denied | Orange (0.2 opacity) | "Denied" |
| Not Determined | Gray (0.2 opacity) | "Not Determined" |

---

### 5. Recordings Browser View

**File:** `RecordingsBrowserView.swift`  
**Size:** Flexible (split view)  
**Type:** `NavigationSplitView`

#### Layout

```
NavigationSplitView
├── Sidebar (List)
│   └── Recording entries
│       ├── Editable title (TextField)
│       └── Date (caption, secondary)
└── Detail (ScrollView)
    ├── Title (editable, title2)
    ├── Date (secondary)
    ├── Notes section
    │   ├── "Notes" heading OR "No notes found"
    │   └── Notes text (selectable)
    ├── Audio section
    │   ├── "Audio" heading
    │   ├── Play/Stop button
    │   └── Filename
    └── Transcript section
        ├── Header with Regenerate button
        ├── Status (if queued)
        └── Transcript text OR "No transcript"
```

#### States

| State | Sidebar | Detail |
|-------|---------|--------|
| Empty | Empty list | "Select a recording" |
| Has Recordings | List of entries | Selected entry details |
| Transcribing | Normal | "Transcription queued..." |

---

### 6. Meeting Notes View

**File:** `MeetingNotesView.swift`  
**Size:** 420×360 minimum  
**Type:** Secondary `WindowGroup`

#### Layout

```
VStack(alignment: .leading, spacing: 16)
├── header (TextField for meeting title)
├── toolbar
│   ├── Timestamp button
│   ├── Bullet button
│   └── Spacer
└── NotesTextView (NSTextView wrapped)
```

#### Features

- **Monospaced font** for notes
- **Timestamp insertion**: `[MM:SS] ` format
- **Bullet insertion**: `• ` prefix
- **Real-time autosave** (debounced)

---

### 7. Transcription Queue View

**File:** `TranscriptionQueueView.swift`  
**Size:** 460×420 minimum  
**Type:** Secondary `WindowGroup`

#### Layout

```
VStack
├── Header
│   ├── "Transcription Queue" title
│   └── Active job indicator
└── List
    ├── Empty state (icon + text) OR
    └── Job rows
        ├── Title + Date
        ├── Status badge (colored)
        ├── Progress bar (if processing)
        ├── Error message (if failed)
        └── Cancel button (if busy)
```

#### Job States

| State | Color | Display |
|-------|-------|---------|
| Pending | Accent | "Pending" |
| Preparing | Accent | "Preparing" |
| Processing | Accent | "Processing X%" |
| Summarizing | Accent | "Summarizing" |
| Completed | Green | "Completed HH:MM" |
| Failed | Red | "Failed" + error |
| Cancelled | Secondary | "Cancelled" |

---

### 8. Meeting Detected Popup

**File:** `MeetingDetectedPopup.swift`  
**Size:** 340×80 (floating)  
**Type:** Custom `NSWindow` (borderless, floating)

#### Layout

```
HStack(spacing: 12)
├── Close button (xmark)
├── Meeting info (VStack)
│   ├── "Meeting detected" (subheadline, medium)
│   └── App name (caption, secondary)
├── Spacer
└── "Take Notes" button (accent, pill shape)
```

#### Behavior

- **Position:** Top-right corner of screen
- **Auto-dismiss:** 7 seconds
- **Animation:** Fade in/out (0.2s)
- **Level:** Floating (above all windows)

---

## Components Library

### 1. Status Indicators

#### Status Dot

```swift
Circle()
    .fill(isActive ? Color.green : Color.gray)
    .frame(width: 10, height: 10)
```

**Usage:** Meeting detection status, recording status

#### Status Badge (Capsule)

```swift
Label(text, systemImage: icon)
    .foregroundStyle(color)
    .font(.caption)
    .padding(.horizontal, 10)
    .padding(.vertical, 4)
    .background(color.opacity(0.1))
    .clipShape(Capsule())
```

**Variants:**
- Ready (green)
- Download Required (orange)
- Recommended (blue)
- Quantized (purple)

---

### 2. Buttons

#### Primary Action Button

```swift
Button("Action") { }
    .buttonStyle(.borderedProminent)
```

**Usage:** Start Recording, Take Notes, Download

#### Secondary Action Button

```swift
Button("Action") { }
    .buttonStyle(.bordered)
```

**Usage:** Stop, Recordings, Settings, Dismiss

#### Plain Text Button

```swift
Button("Action") { }
    .buttonStyle(.plain)
    .foregroundStyle(.blue)
```

**Usage:** Show All Models, Clear logs

#### Small Control Button

```swift
Button("Action") { }
    .buttonStyle(.bordered)
    .controlSize(.small)
```

**Usage:** Download, Retry, Request Access

---

### 3. Cards & Containers

#### Alert/Prompt Card

```swift
VStack { ... }
    .padding(12)
    .background(Color.orange.opacity(0.15))
    .clipShape(RoundedRectangle(cornerRadius: 12))
```

**Usage:** Meeting detected prompt, Detection prompt

#### Section Container (Settings)

```swift
VStack(alignment: .leading, spacing: 12) {
    Text(title).font(.headline)
    content
}
```

**Usage:** Settings sections

#### List Item Container

```swift
VStack { ... }
    .padding(12)
    .background(Color.gray.opacity(0.08))
    .clipShape(RoundedRectangle(cornerRadius: 12))
```

**Usage:** Permission rows

#### Bordered Container

```swift
VStack { ... }
    .background(Color.primary.opacity(0.02))
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .overlay(
        RoundedRectangle(cornerRadius: 8)
            .stroke(Color.primary.opacity(0.1), lineWidth: 1)
    )
```

**Usage:** Model list container

---

### 4. Progress Indicators

#### Linear Progress Bar

```swift
ProgressView(value: progress)
    .progressViewStyle(.linear)
```

**Usage:** Transcription progress, Download progress

#### Progress Card

```swift
VStack(alignment: .leading, spacing: 8) {
    Text(title).font(.footnote).foregroundStyle(.secondary)
    ProgressView(value: progress)
    Text(message).font(.caption).foregroundStyle(color)
}
.padding(12)
.background(Color.gray.opacity(0.08))
.clipShape(RoundedRectangle(cornerRadius: 10))
```

**Usage:** TranscriptionProgressView

---

### 5. Form Elements

#### Selection Radio

```swift
Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
    .font(.system(size: 18))
    .foregroundStyle(isSelected ? .blue : .secondary.opacity(0.5))
```

**Usage:** Model selection

#### Toggle

```swift
Toggle("Label", isOn: $binding)
```

**Usage:** System audio capture setting

#### Editable Text Field

```swift
TextField("Placeholder", text: $binding)
    .textFieldStyle(.plain)
    .font(.headline)
```

**Usage:** Recording titles, Meeting title

---

### 6. Lists

#### Selectable List

```swift
List(selection: $selection) {
    ForEach(items) { item in
        // Row content
    }
}
```

**Usage:** Recordings browser sidebar

#### Lazy Scrolling List

```swift
ScrollView {
    LazyVStack(spacing: 0) {
        ForEach(items) { item in
            // Row content
            if item != items.last {
                Divider().padding(.leading, 36)
            }
        }
    }
}
.frame(height: calculatedHeight)
```

**Usage:** Model list

---

### 7. Log/Console View

#### Download Log Entry

```swift
HStack(alignment: .top, spacing: 8) {
    Text(timestamp)
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .monospacedDigit()
        .frame(width: 55, alignment: .leading)
    
    logIcon
        .font(.caption2)
        .frame(width: 12)
    
    Text(message)
        .font(.caption)
        .foregroundStyle(logColor)
}
```

**Log Types:**
- Info (blue info.circle)
- Progress (cyan arrow.down.circle)
- Warning (orange exclamationmark.triangle)
- Error (red xmark.circle)
- Success (green checkmark.circle)

---

## User Flows

### Flow 1: First Launch

```
┌─────────────────┐
│  App Launches   │
└────────┬────────┘
         │
         ▼
┌─────────────────┐     ┌─────────────────┐
│  StartupView    │────▶│  OnboardingView │
│  (permissions   │     │  (grant perms)  │
│   not granted)  │     └────────┬────────┘
└─────────────────┘              │
                                 ▼
                    ┌─────────────────────┐
                    │  Download Model     │
                    │  (Settings or       │
                    │   StartupView)      │
                    └────────┬────────────┘
                             │
                             ▼
                    ┌─────────────────┐
                    │  Ready to Use   │
                    └─────────────────┘
```

### Flow 2: Auto Meeting Detection

```
┌─────────────────┐
│  User joins     │
│  Zoom/Meet call │
└────────┬────────┘
         │
         ▼
┌─────────────────┐     ┌─────────────────┐
│  MeetingDetector│────▶│ MeetingDetected │
│  detects app    │     │ Popup (7s)      │
└─────────────────┘     └────────┬────────┘
                                 │
              ┌──────────────────┼──────────────────┐
              │                  │                  │
              ▼                  ▼                  ▼
    ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐
    │  Click "Take    │  │  Auto-dismiss   │  │  Click X        │
    │  Notes"         │  │  (timeout)      │  │  (dismiss)      │
    └────────┬────────┘  └─────────────────┘  └─────────────────┘
             │
             ▼
    ┌─────────────────┐
    │  Recording      │
    │  Starts         │
    └────────┬────────┘
             │
             ▼
    ┌─────────────────┐
    │  MeetingNotes   │
    │  View Opens     │
    └─────────────────┘
```

### Flow 3: Recording Session

```
┌─────────────────┐
│  Start Recording│
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│  Recording      │◀──── User takes notes in MeetingNotesView
│  In Progress    │      Notes auto-save every 500ms
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│  Stop Recording │
└────────┬────────┘
         │
         ▼
┌─────────────────────────────────────┐
│  Post-Processing Pipeline           │
├─────────────────────────────────────┤
│  1. Preparing (loading model)       │
│  2. Processing (transcribing) 0-90% │
│  3. Summarizing                     │
│  4. Completed (saved)               │
└────────┬────────────────────────────┘
         │
         ▼
┌─────────────────┐
│  View in        │
│  Recordings     │
└─────────────────┘
```

### Flow 4: Model Download

```
┌─────────────────┐
│  Open Settings  │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│  Transcription  │
│  Model Section  │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│  Select Model   │
│  (not downloaded)│
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│  Click Download │
└────────┬────────┘
         │
         ▼
┌─────────────────────────────────────┐
│  Download Progress                  │
├─────────────────────────────────────┤
│  • Log: Connecting...               │
│  • Log: Connected (HTTP 200)        │
│  • Progress: 10% - 160MB @ 50MB/s   │
│  • Progress: 20% - 320MB @ 52MB/s   │
│  • ...                              │
│  • Log: Complete in 32s (avg 50MB/s)│
└────────┬────────────────────────────┘
         │
         ▼
┌─────────────────┐
│  Model Ready    │
│  (green check)  │
└─────────────────┘
```

---

## States & Conditions

### Global App States

| State | Description | UI Indicators |
|-------|-------------|---------------|
| Idle | No meeting, not recording | Gray dot, "Idle" text |
| Meeting Detected | Zoom/Meet active, not recording | Green dot, orange prompt card |
| Recording | Actively capturing audio | Red status text, timer shown |
| Transcribing | Post-recording processing | Progress bar, state labels |
| Model Missing | No Whisper model available | Red text, Download button |

### Permission States

| State | Color | Action |
|-------|-------|--------|
| Granted | Green | None needed |
| Denied | Orange | Open System Settings |
| Not Determined | Gray | Request Access |

### Model States

| State | Badge | Action |
|-------|-------|--------|
| Available | Green checkmark | Delete (via menu) |
| Downloading | Progress bar | Cancel |
| Not Downloaded | None | Download |
| Failed | Red warning | Retry |

### Transcription Job States

| State | Color | Progress |
|-------|-------|----------|
| Pending | Accent | None |
| Preparing | Accent | None |
| Processing | Accent | 0-100% |
| Summarizing | Accent | None |
| Completed | Green | None |
| Failed | Red | None |
| Cancelled | Gray | None |

---

## Current Styling Audit

### Typography (Current)

| Element | Font | Weight | Size |
|---------|------|--------|------|
| Window Title | .title / .title2 | Bold | System |
| Section Header | .headline | Regular | System |
| Subsection | .subheadline | Medium | System |
| Body Text | .body | Regular | System |
| Caption/Helper | .caption | Regular | System |
| Timestamps | .caption2 | Regular | Monospaced |
| Notes Editor | System Monospaced | Regular | System |

### Colors (Current - System Colors)

| Usage | Color | Notes |
|-------|-------|-------|
| Primary Actions | .accentColor (blue) | Button backgrounds |
| Success | .green | Granted, Available, Complete |
| Warning | .orange | Denied, Meeting detected, Downloading |
| Error | .red | Failed, Recording indicator |
| Neutral | .gray / .secondary | Idle, disabled, helper text |
| Quantized Badge | .purple | Model type indicator |
| Progress | .cyan | Download progress icon |

### Spacing (Current)

| Context | Value |
|---------|-------|
| Window Padding | 16-24pt |
| Section Spacing | 16pt |
| Item Spacing | 8-12pt |
| Card Padding | 12pt |
| Button Spacing | 12pt |

### Corner Radii (Current)

| Component | Radius |
|-----------|--------|
| Cards | 12pt |
| Buttons (pill) | 8pt |
| Containers | 8pt |
| Badges (capsule) | Full (Capsule) |
| Status badges | 6pt |

### Shadows (Current)

| Component | Shadow |
|-----------|--------|
| Popup Window | 0.15 opacity, 10pt blur, y: 4pt |
| Other Windows | None (system default) |

---

## Design System Recommendations

### Areas Needing Attention

1. **Inconsistent Card Styles**
   - Settings uses subtle borders
   - Onboarding uses solid gray backgrounds
   - Prompts use colored backgrounds
   - **Recommendation:** Define 2-3 card variants

2. **Button Hierarchy**
   - Currently using system styles throughout
   - **Recommendation:** Define primary, secondary, tertiary, destructive variants

3. **Color Palette**
   - Using system colors without custom palette
   - **Recommendation:** Define brand colors with semantic mappings

4. **Typography Scale**
   - Using system dynamic type
   - **Recommendation:** Define explicit type scale with line heights

5. **Icon Usage**
   - All SF Symbols, no custom icons
   - **Recommendation:** Document icon sizes per context

6. **Dark Mode**
   - Currently relies on system automatic
   - **Recommendation:** Verify all custom colors work in both modes

### Component Audit Checklist

| Component | Needs Design | Priority |
|-----------|--------------|----------|
| Status Badges | Unify styles | High |
| Cards/Containers | Define variants | High |
| Progress Indicators | Consistent styling | Medium |
| Buttons | Define hierarchy | Medium |
| Form Inputs | Consistent styling | Medium |
| Lists/Tables | Define patterns | Low |
| Empty States | Improve illustrations | Low |

### Suggested Design Tokens

```
// Colors
--color-primary: #007AFF (or custom)
--color-success: #34C759
--color-warning: #FF9500
--color-error: #FF3B30
--color-info: #5AC8FA

// Backgrounds
--bg-primary: system
--bg-secondary: primary @ 0.05
--bg-card: primary @ 0.02-0.08
--bg-alert: semantic color @ 0.1-0.15

// Typography
--font-title: .title2, bold
--font-heading: .headline, regular
--font-body: .body, regular
--font-caption: .caption, regular
--font-mono: .monospacedSystemFont

// Spacing
--space-xs: 4pt
--space-sm: 8pt
--space-md: 12pt
--space-lg: 16pt
--space-xl: 24pt

// Radii
--radius-sm: 6pt
--radius-md: 8pt
--radius-lg: 12pt
--radius-full: Capsule
```

---

## Appendix: File Reference

| Screen | File | Lines |
|--------|------|-------|
| Menu Bar | `Views/MenuBarView.swift` | ~244 |
| Startup | `Views/StartupView.swift` | ~272 |
| Settings | `Views/SettingsView.swift` | ~495 |
| Onboarding | `Views/OnboardingView.swift` | ~98 |
| Recordings | `Views/RecordingsBrowserView.swift` | ~198 |
| Notes | `Views/MeetingNotesView.swift` | ~153 |
| Queue | `Views/TranscriptionQueueView.swift` | ~139 |
| Popup | `Views/MeetingDetectedPopup.swift` | ~103 |
| Popup Window | `Views/MeetingPopupWindow.swift` | ~79 |
| Progress | `Views/TranscriptionProgressView.swift` | ~89 |

---

*End of Design System Research Document*
