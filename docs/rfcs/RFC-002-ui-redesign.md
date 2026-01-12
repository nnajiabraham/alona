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
  - [x] Apply SF Mono for text editor (NSTextView already uses monospaced)
  - [x] Standardize spacing
  - Notes: Updated heading typography, standardized spacing. Tests pass, lint clean.

- [x] **TranscriptionProgressView** (Progress Component)
  - [x] Apply yellow-green (#C0CA33) for transcription
  - [x] Update corner radius to 10pt
  - Notes: Added status icon per state, yellow-green progress bar tint for transcription. Success/error states use proper semantic colors. Tests pass, lint clean.

- [x] **TranscriptionQueueView** (Queue View)
  - [x] Apply semantic colors per state mapping
  - [x] Update hero icon size (48pt for empty state)
  - Notes: 48pt hero waveform icon, status icons with semantic colors, yellow-green progress tint. Tests pass, lint clean.

### Phase 4: Validation
- [x] Final `make test` passes (113 tests)
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

---

## Final Summary

All UI views have been redesigned to match mockups in `docs/design_system/`:

| View | Layout Changes |
|------|----------------|
| `DesignSystem.swift` | Centralized tokens (colors, typography, spacing, icons, animations) |
| `StartupView` | **Complete redesign**: Hero status card with mic icon, 3 card navigation buttons, footer status bar |
| `MenuBarView` | **Complete redesign**: Prominent meeting detection card (orange/red), recent recordings list, cleaner footer |
| `SettingsView` | **Sidebar navigation** with tabbed content, cleaner model list with status/action columns |
| `MeetingDetectedPopup` | **Simplified layout**: Video icon + title, two buttons (Ignore/Record) |
| `RecordingsBrowserView` | SF Mono for transcripts, hero icon for empty state |
| `OnboardingView` | Permission badges with icons, semantic colors |
| `MeetingNotesView` | SF Pro Rounded heading, standardized spacing |
| `TranscriptionProgressView` | Yellow-green progress tint, status icons per state |
| `TranscriptionQueueView` | 48pt hero icon, semantic colors per job state |

---

## Follow-ups & Future Work

1. **Visual QA**: Manual visual review of all screens in running app recommended
2. **Dark Mode Testing**: Verify all semantic colors work well in both light and dark modes
3. **Accent Color**: Consider adding a custom Accent asset for the primary green (`#388E3C`) in Assets.xcassets
4. **Animation Refinement**: The recording pulse animation timing could be fine-tuned based on user feedback
5. **Accessibility**: Verify color contrast ratios meet WCAG guidelines for the new color palette
