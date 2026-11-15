# RFC-002: UI Redesign to Design System Guidelines

## Summary

Systematically redesign all Alona UI screens/components to align with the design system defined in `docs/design_system/design_system_guidelines.md`. This RFC tracks progress and implementation notes for each screen/component.

## Design System Key Tokens

| Token | Value | Notes |
|-------|-------|-------|
| Primary (Brand) | `#388E3C` | Forest Green |
| Recording | `#FF3B30` | System Red + pulse animation |
| Meeting Detected | `#FF9500` | System Orange |
| Success/Ready | `#34C759` | System Green |
| Transcription | `#C0CA33` | Yellow-Green (processing) |
| Corner Radius (containers) | 10pt | Standard windows/cards |
| Corner Radius (buttons) | 8pt | Internal elements |
| Spacing | 4/8/12/16/24pt | 4pt grid system |
| Icons (inline) | 14pt | Buttons, labels |
| Icons (status) | 18pt | Status indicators |
| Icons (hero) | 48pt | Dashboard, empty states |
| Recording pulse | 1.0→0.6 opacity, 1.2s | easeInOut, forever |

## Progress Checklist

### Phase 0: Foundation
- [x] Create RFC tracker (this file)
- [x] Create `DesignSystem.swift` with centralized tokens
- [x] Verify baseline: `make test` + `make lint` pass

### Phase 1: Core Screens
- [x] **StartupView** (Dashboard)
  - [x] Apply semantic colors for states
  - [x] Update typography (headings)
  - [x] Standardize spacing to 4pt grid
  - [x] Add recording pulse animation
  - [x] Update corner radii
  - Notes: Added status icons with semantic colors, recording pulse on header, permission status badges with color coding. Tests pass, lint clean.

- [x] **MenuBarView** (Menu Bar Dropdown)
  - [x] Apply semantic colors
  - [x] Update typography
  - [x] Standardize spacing
  - [x] Add recording pulse animation
  - Notes: Added pulse on recording button and duration indicator, semantic colors for detection/permissions, updated spacing grid. Tests pass, lint clean.

- [x] **RecordingsBrowserView** (Split View)
  - [x] Apply SF Mono for transcript display
  - [x] Update colors and spacing
  - [x] Standardize corner radii
  - Notes: SF Mono for transcripts and notes, hero icon for empty state, semantic colors for transcription status. Tests pass, lint clean.

- [x] **SettingsView** (Model Management)
  - [x] Apply semantic colors for model status
  - [x] Update Download Log Console per spec
  - [x] Standardize spacing and typography
  - Notes: Download Log Console with SF Mono 11pt, proper color-coded log messages per design system. Model status badges use semantic colors. Primary (green) for selection. Tests pass, lint clean.

### Phase 2: Popups & Notifications
- [x] **MeetingDetectedPopup** (Floating Pill)
  - [x] Apply orange (#FF9500) for meeting detected
  - [x] Update button to primary green
  - [x] Standardize spacing (12pt container padding)
  - Notes: Added orange video icon indicator, primary green "Take Notes" button. Updated spacing grid and corner radii. Tests pass, lint clean.

- [x] **OnboardingView** (Permissions)
  - [x] Apply semantic colors for permission status
  - [x] Update typography and spacing
  - Notes: Added status icons with semantic colors, SF Pro Rounded heading. Updated permission badges with proper icon+label. Tests pass, lint clean.

### Phase 3: Supporting Views
- [x] **MeetingNotesView** (Notes Editor)
  - [x] Apply SF Mono for text editor
  - [x] Standardize spacing
  - [x] Add recording status bar with stop button
  - [x] Add word count and auto-save indicator
  - [x] Add action item toolbar button
  - Notes: Complete redesign with recording status bar, word count footer, action items. Tests pass, lint clean.

- [x] **TranscriptionProgressView** (Progress Component)
  - [x] Apply yellow-green (#C0CA33) for transcription
  - [x] Update corner radius to 10pt
  - Notes: Added status icon per state, yellow-green progress bar tint for transcription. Success/error states use proper semantic colors. Tests pass, lint clean.

- [x] **TranscriptionQueueView** (Queue View)
  - [x] Apply semantic colors per state mapping
  - [x] Update hero icon size (48pt for empty state)
  - Notes: 48pt hero waveform icon, status icons with semantic colors, yellow-green progress tint. Tests pass, lint clean.

### Phase 4: Validation
- [x] Final `make test` passes (115 tests)
- [x] Final `make lint` passes (0 files require formatting)
- [ ] Visual review of all screens

---

## Implementation Log

### 2026-01-11 - Session Start
- **Status**: RFC created, baseline tests/lint pass (113 tests, 0 lint errors)
- **Completed**: Created `DesignSystem.swift` foundation file with centralized tokens

### 2026-01-11 - Phase 1 Complete
- **Completed**: StartupView, MenuBarView, RecordingsBrowserView, SettingsView
- All views now use design system tokens for colors, spacing, typography, icons

### 2026-01-11 - Phase 2 Complete
- **Completed**: MeetingDetectedPopup, OnboardingView
- Popups use orange for meeting detection, primary green for CTA buttons

### 2026-01-11 - Phase 3 & 4 Complete
- **Completed**: MeetingNotesView, TranscriptionProgressView, TranscriptionQueueView
- Yellow-green (#C0CA33) now used for all transcription/processing states
- Final validation: 113 tests pass, 0 lint errors

### 2026-01-11 - Xcode Project Fix
- **Fixed**: Added `DesignSystem.swift` to Xcode project (was only in Package.swift for SPM tests)
- Build and run now work correctly via `make build` and `make run`

### 2026-01-11 - Full Layout Redesign (Phase 2)
- **Reviewed mockups** in `docs/design_system/` folder
- **StartupView**: Completely rewritten with hero status card + 3 navigation card buttons (matching mockup)
- **MenuBarView**: Redesigned with prominent meeting detection card + recent recordings list
- **SettingsView**: Added sidebar navigation + clean tabular model list
- **MeetingDetectedPopup**: Updated to match floating popup mockup (Ignore/Record buttons)
- Tests pass (113), lint clean

### 2026-01-11 - Restore Missing Features (Phase 3)
- **StartupView**: Restored permissions summary, model status section, detection prompt, secondary actions row
- **SettingsView**: Added General tab with Recording settings (system audio toggle) and Storage settings (save directory)
- **SettingsView**: Restored full model selection UI with download log, progress, show all/recommended toggle
- **RecordingsBrowserView**: Better organized detail view with clear sections (Header, Audio, Transcript, Notes)
- Tests pass (113), lint clean

### 2026-01-11 - Notes Editor Redesign & Bug Fixes (Phase 4)
- **MeetingNotesView**: Complete redesign with:
  - Recording status bar (shows recording indicator, duration, stop button when recording)
  - Better organized sections (header, toolbar, editor, footer)
  - Word count display in footer
  - Auto-save indicator
  - Action item button (☐) added to toolbar
  - Better styled text editor with border
- **RecordingsBrowserView**: Notes section now **editable** with TextEditor (auto-saves on change)
- **Bug Fix**: Notes window can now be reopened during active recording via `appState.requestNotesWindow()`
- **New Tests**: `testRequestNotesWindowGeneratesNewID`, `testRequestNotesWindowCanBeCalledMultipleTimes`
- Tests pass (115 total - 2 new), lint clean

---

## Final Summary

All UI views have been redesigned to match mockups in `docs/design_system/`:

| View | Layout Changes |
|------|----------------|
| `DesignSystem.swift` | Centralized tokens (colors, typography, spacing, icons, animations) |
| `StartupView` | **Complete redesign**: Hero status card with mic icon, 3 card navigation buttons, permissions summary |
| `MenuBarView` | **Complete redesign**: Prominent meeting detection card (orange/red), recent recordings list |
| `SettingsView` | **Sidebar navigation** with General + Transcription Models tabs, full model list with download log |
| `MeetingDetectedPopup` | **Simplified layout**: Video icon + title, two buttons (Ignore/Record) |
| `RecordingsBrowserView` | **Editable notes**, SF Mono for transcripts, organized sections (Header/Audio/Transcript/Notes) |
| `OnboardingView` | Permission badges with icons, semantic colors |
| `MeetingNotesView` | **Complete redesign**: Recording status bar, word count, action items, auto-save indicator |
| `TranscriptionProgressView` | Yellow-green progress tint, status icons per state |
| `TranscriptionQueueView` | 48pt hero icon, semantic colors per job state |

---

## Follow-ups & Future Work

1. **Visual QA**: Manual visual review of all screens in running app recommended
2. **Dark Mode Testing**: Verify all semantic colors work well in both light and dark modes
3. **Accent Color**: Consider adding a custom Accent asset for the primary green (`#388E3C`) in Assets.xcassets
4. **Animation Refinement**: The recording pulse animation timing could be fine-tuned based on user feedback
5. **Accessibility**: Verify color contrast ratios meet WCAG guidelines for the new color palette
