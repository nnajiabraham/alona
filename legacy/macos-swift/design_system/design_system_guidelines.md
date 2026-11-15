# Alona MVP Design System Update

This document outlines the updated design system for the Alona MVP, incorporating user feedback to refine the color palette and add detailed implementation specifications. The core philosophy remains **"Native Enhanced"**—feeling like a built-in macOS utility but with optimized readability for data-heavy tasks.

---

### 1. The Alona Design System

This system prioritizes readability for transcripts, clear status indication, and a professional, native-feeling aesthetic without using purple hues.

#### **Color Palette**
We have shifted away from purple to a palette anchored in greens, yellows, and a clean monochromatic base, supporting both Light and Dark modes.

* **Primary (Brand):** `Color("Accent")` - A sophisticated, deep Forest Green. It feels professional, trustworthy, and native.
    * *Hex:* `#388E3C`
* **Surface (Backgrounds):**
    * `Color(nsColor: .windowBackgroundColor)` (Standard window background).
    * `Color(nsColor: .controlBackgroundColor)` (Inputs/Lists/Secondary backgrounds).
* **Semantic Status Colors:**
    * **Recording (Active):** `#FF3B30` (System Red) - Used with a pulse animation.
    * **Meeting Detected (Warning/Alert):** `#FF9500` (System Orange) - High visibility for alerts.
    * **Success/Safe:** `#34C759` (System Green) - For "Model Ready," "Granted," or completed tasks.
    * **Transcription (Processing):** `#C0CA33` (Vibrant Yellow-Green) - Indicates active AI processing or a "working" state, distinct from success or warning.

#### **Typography**
* **Headings:** `SF Pro Rounded` (Adds a slightly friendlier, modern feel).
* **Body:** `SF Pro Text` (Standard for readability).
* **Transcription/Notes:** `SF Mono`. This is crucial for the "technical/local-first" vibe and makes editing transcripts with timestamps easier.

#### **Layout, Shape & Spacing**
* **Corner Radius:** `10pt` for standard macOS small windows and containers; `8pt` for internal buttons and smaller elements.
* **Spacing Scale:** We use a 4pt grid system to ensure consistent padding and margins.
    * `4pt`: Minimal spacing, tight grouping.
    * `8pt`: Standard internal spacing within components.
    * `12pt`: Standard padding for cards and containers.
    * `16pt`: Standard outer edge padding for windows and major sections.
    * `24pt`: Section separation or large whitespace.

#### **Iconography**
Icons should be from SF Symbols, sized according to their context to maintain hierarchy.
* **Inline/Controls:** `14pt` (e.g., buttons, small labels).
* **Status/Navigation:** `18pt` (e.g., sidebar icons, status indicators).
* **Hero/Prominent:** `48pt` (e.g., main dashboard status icon, empty state illustrations).

#### **Animations**
Animations should be subtle and purposeful, enhancing status visibility without being distracting.
* **Recording Pulse:** The red recording indicator (e.g., in the menu bar or dashboard) should have a subtle, repeating opacity pulse animation.
    * *Spec:* Opacity transitions between `1.0` and `0.6` over a `1.2s` duration with an `easeInEaseOut` curve, repeating forever while active.

---

### 2. State Mapping Table

This table defines how the app's state translates to visual elements across any screen.

| App State | Semantic Color | Icon (SF Symbol) | Visual Style / Component |
| :--- | :--- | :--- | :--- |
| **Idle** | Monochromatic (Gray) | `mic` or `mic.slash` | Standard text, no prominent colored elements. |
| **Meeting Detected** | Orange (`#FF9500`) | `video.fill` or `phone.fill` | Prominent orange alert card or banner. |
| **Recording** | Red (`#FF3B30`) | `record.circle.fill` | pulsing red indicator, red status text. |
| **Transcribing** | Yellow-Green (`#C0CA33`) | `waveform.circle.fill` or `sparkles` | Progress bar, "Processing" badge. |
| **Success / Ready**| Green (`#34C759`) | `checkmark.circle.fill` | Green checkmark badge, success message. |
| **Error / Failed** | Red (`#FF3B30`) | `exclamationmark.triangle.fill`| Red error text, retry button. |
| **Downloading** | Monochromatic (Blue/Gray)| `arrow.down.circle.fill` | Progress bar, cancel button. |

---

### 3. Component Specifications

#### **Download Log Console**
This component (used in Settings) displays a stream of technical messages during model downloads.
* **Container:** A scrollable text area with a slightly darker background (`Color(nsColor: .controlBackgroundColor)` or slightly darker in light mode) and a monospaced font.
* **Font:** `SF Mono`, size `11pt` or `12pt`.
* **Each Line:**
    * **Timestamp:** `[HH:MM:SS]` in gray secondary color.
    * **Message:** The log text.
    * **Color Coding:**
        * Standard info: Primary text color.
        * Errors: Red (`#FF3B30`).
        * Success/Done: Green (`#34C759`).
        * Progress updates: Monochromatic or subtle blue.

---

### 4. UI Mockups & Screen Designs (Reference)

These mocks illustrate the design system applied to core screens.

#### **A. Startup View (Dashboard)**
The "Control Center" showing app status.
* *Mockup:* `docs/design_system/images/startup_view_mock.png`

#### **B. Menu Bar Dropdown**
High-contrast, instantly readable view for quick actions.
* *Mockup:* `docs/design_system/images/menu_bar_dropdown_mock.png`

#### **C. Recordings Browser (Split View)**
The main content management screen with a list and detail editor.
* *Mockup:* `docs/design_system/images/recordings_browser_mock.png`

#### **D. Settings (Model Management)**
A tabular view for managing technical resources like Whisper models.
* *Mockup:* `docs/design_system/images/settings_mock.png`

#### **E. Floating Popup**
A non-intrusive "pill" notification for detected meetings.
* *Mockup:* `docs/design_system/images/floating_popup_mock.png`

---
*Note: The visual mockups linked above were created with the previous color palette. Implementers should apply the **new Green/Yellow-Green color palette** and the **detailed specs (spacing, icons, etc.)** defined in this document when building the actual application components.*