Here is the Alona MVP Design System and visual mockups for your core screens.

1. The Alona Design System
This system prioritizes readability for transcripts and clear status indication for recording states.

Color Palette
We will move away from raw system colors to a semantic palette that supports both Light and Dark modes.

Primary (Brand): Color("Accent") - A deep, electric Indigo.

Hex: #5856D6 (System Indigo is a good base, but slightly more saturated).

Surface (Backgrounds):

Color(nsColor: .windowBackgroundColor) (Standard window background).

Color(nsColor: .controlBackgroundColor) (Inputs/Lists).

Semantic Status:

Recording (Active): #FF3B30 (System Red) - Pulse animation.

Meeting Detected: #FF9500 (System Orange) - High visibility.

Success/Safe: #34C759 (System Green) - For "Model Ready" or "Grant Permission."

Transcription: #AF52DE (System Purple) - Indicates AI processing.

Typography
Headings: SF Pro Rounded (Adds a slightly friendlier, modern feel compared to standard SF Pro).

Body: SF Pro Text.

Transcription/Notes: SF Mono. This is crucial. It aligns with the "coding/technical" vibe of a local-first tool and makes editing transcripts easier.

Layout & Shape
Corner Radius: 10pt (Standard macOS small window) and 8pt for internal buttons.

Padding: Standardize to 16px for outer edges and 12px for internal card spacing.

2. UI Mockups & Screen Designs
A. Startup View (Dashboard)
This is the "Control Center." It needs to clearly show if the app is Idle, Recording, or Processing.

Design Change: Instead of a list of buttons, we use a "Status Hero" card at the top, with a grid of actions below.

B. Menu Bar Dropdown
This needs to be high-contrast and instantly readable.

Design Change: The "Meeting Detected" state should dominate the view when active. When idle, it should be compact.

C. Recordings Browser (Split View)
This is where the user spends the most time.

Design Change:

Left Sidebar: List of meetings with date badges.

Right Detail: A clean "Notion-style" editor. Title at the top, audio player pinned below title, and then the notes/transcript using SF Mono.

D. Settings (Model Management)
Managing local LLMs/Whisper models is technical.

Design Change: Use a "Table Row" style. Each model gets a row with a clear "Download" arrow or a "Checkmark" if ready.

E. Floating Popup
The "Meeting Detected" notification.

Design Change: A floating "pill" rather than a standard window. It should look like the macOS volume HUD or a Dynamic Island interaction.

---------------------------------------------------------------------------
## Example Mockscreen image files
### **A. Startup View (Dashboard)**

This is the main dashboard window in its idle state. The design is clean and minimalist, featuring a prominent status indicator and a grid of navigation buttons. See mock image at docs/design_system/images/startup_view_mock.png.

* **State:** Idle.
* **Key Elements:** "Ready to Record" hero card, Recordings, Settings, and Queue buttons.
* **Design:** Light mode, minimalist, native macOS feel.

### **B. Menu Bar Dropdown**

This is the menu bar dropdown in a dark mode "Meeting Detected" state. The interface is dominated by a high-visibility orange card, prompting the user to start recording. See mock image at docs/design_system/images/menu_bar_dropdown_mock.png.

* **State:** Meeting Detected (Zoom).
* **Key Elements:** Prominent "Zoom Meeting Detected" card with a "Start Recording" button.
* **Design:** Dark mode, high-contrast, compact layout.

### **C. Recordings Browser (Split View)**

This image shows the main content management screen. The split-view layout allows users to browse meetings on the left and review details, including the transcript and audio, on the right. See mock image at docs/design_system/images/recordings_browser_mock.png.

* **Layout:** macOS Split View.
* **Left Pane:** List of meeting recordings.
* **Right Pane:** Meeting details, audio player with waveform, and a timestamped transcript in a monospaced font.

### **D. Settings (Model Management)**

This image of the Settings window illustrates the user's experience of managing local transcription models. It shows a clean list of models with their current status (Ready, Downloading, Not Downloaded). See mock image at docs/design_system/images/settings_mock.png.

* **Key Elements:** "Transcription Models" section, model list with status indicators, download progress bar, and action buttons.
* **Design:** Tabular layout, clean and informative.

### **E. Floating Popup (Meeting Detected)**

This image visualizes the app's real-time notification system. It's a small, unobtrusive floating window that appears when a meeting is detected, offering quick actions to "Ignore" or "Record". See mock image at docs/design_system/images/floating_popup_mock.png.

* **Style:** Floating, translucent, pill-shaped popup.
* **Content:** "Meeting Detected" text, camera icon, "Ignore" and "Record" buttons.
* **Context:** Hovers over a blurred desktop background, indicating a non-intrusive alert.