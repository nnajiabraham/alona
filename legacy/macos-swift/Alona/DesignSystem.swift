import SwiftUI

// MARK: - Design System

/// Centralized design tokens based on docs/design_system/design_system_guidelines.md
/// Philosophy: "Native Enhanced" - feels like a built-in macOS utility with optimized readability
enum DesignSystem {
    // MARK: - Semantic Colors

    enum Colors {
        /// Primary brand color - Forest Green (#388E3C)
        static let primary = Color(red: 0.22, green: 0.556, blue: 0.235)

        /// Recording state - System Red (#FF3B30)
        static let recording = Color(red: 1.0, green: 0.231, blue: 0.188)

        /// Meeting detected / Warning - System Orange (#FF9500)
        static let meetingDetected = Color(red: 1.0, green: 0.584, blue: 0.0)

        /// Success / Ready / Granted - System Green (#34C759)
        static let success = Color(red: 0.204, green: 0.78, blue: 0.349)

        /// Transcription / Processing - Vibrant Yellow-Green (#C0CA33)
        static let transcription = Color(red: 0.753, green: 0.792, blue: 0.2)

        /// Error / Failed - System Red (same as recording)
        static let error = Color(red: 1.0, green: 0.231, blue: 0.188)

        // MARK: - Backgrounds

        /// Standard window background
        static let windowBackground = Color(nsColor: .windowBackgroundColor)

        /// Inputs, lists, secondary backgrounds
        static let controlBackground = Color(nsColor: .controlBackgroundColor)
    }

    // MARK: - Typography

    enum Typography {
        /// Headings - SF Pro Rounded for friendlier, modern feel
        static func heading(_ size: CGFloat) -> Font {
            .system(size: size, weight: .semibold, design: .rounded)
        }

        /// Body text - SF Pro Text (standard)
        static func body(_ size: CGFloat = 13) -> Font {
            .system(size: size, weight: .regular, design: .default)
        }

        /// Transcription/Notes text - SF Mono for technical/local-first vibe
        static func mono(_ size: CGFloat = 13) -> Font {
            .system(size: size, weight: .regular, design: .monospaced)
        }

        /// Download log console font
        static let logConsole: Font = .system(size: 11, weight: .regular, design: .monospaced)
    }

    // MARK: - Spacing (4pt Grid)

    enum Spacing {
        /// 4pt - Minimal spacing, tight grouping
        static let xs: CGFloat = 4

        /// 8pt - Standard internal spacing within components
        static let sm: CGFloat = 8

        /// 12pt - Standard padding for cards and containers
        static let md: CGFloat = 12

        /// 16pt - Standard outer edge padding for windows and major sections
        static let lg: CGFloat = 16

        /// 24pt - Section separation or large whitespace
        static let xl: CGFloat = 24
    }

    // MARK: - Corner Radius

    enum CornerRadius {
        /// 10pt - Standard for macOS small windows and containers
        static let container: CGFloat = 10

        /// 8pt - Internal buttons and smaller elements
        static let button: CGFloat = 8
    }

    // MARK: - Icons (SF Symbols)

    enum IconSize {
        /// 14pt - Inline/Controls (buttons, small labels)
        static let inline: CGFloat = 14

        /// 18pt - Status/Navigation (sidebar icons, status indicators)
        static let status: CGFloat = 18

        /// 48pt - Hero/Prominent (main dashboard status, empty state illustrations)
        static let hero: CGFloat = 48
    }

    // MARK: - Animations

    enum Animation {
        /// Recording pulse animation spec
        /// Opacity: 1.0 → 0.6, Duration: 1.2s, easeInOut, repeating forever
        static let recordingPulse = SwiftUI.Animation
            .easeInOut(duration: 1.2)
            .repeatForever(autoreverses: true)
    }
}

// MARK: - Recording Pulse View Modifier

struct RecordingPulseModifier: ViewModifier {
    @State private var isPulsing = false
    let isActive: Bool

    func body(content: Content) -> some View {
        content
            .opacity(self.isActive && self.isPulsing ? 0.6 : 1.0)
            .animation(self.isActive ? DesignSystem.Animation.recordingPulse : .default, value: self.isPulsing)
            .onAppear {
                if self.isActive {
                    self.isPulsing = true
                }
            }
            .onChange(of: self.isActive) { _, newValue in
                self.isPulsing = newValue
            }
    }
}

extension View {
    /// Apply recording pulse animation when active
    func recordingPulse(isActive: Bool) -> some View {
        modifier(RecordingPulseModifier(isActive: isActive))
    }
}

// MARK: - State Mapping Helpers

extension DesignSystem {
    /// Maps app state to semantic color per design system state mapping table
    enum StateColor {
        static func forIdle() -> Color { .gray }
        static func forMeetingDetected() -> Color { Colors.meetingDetected }
        static func forRecording() -> Color { Colors.recording }
        static func forTranscribing() -> Color { Colors.transcription }
        static func forSuccess() -> Color { Colors.success }
        static func forError() -> Color { Colors.error }
        static func forDownloading() -> Color { .gray }
    }

    /// Maps app state to SF Symbol per design system state mapping table
    enum StateIcon {
        static let idle = "mic"
        static let idleDisabled = "mic.slash"
        static let meetingDetected = "video.fill"
        static let meetingDetectedPhone = "phone.fill"
        static let recording = "record.circle.fill"
        static let transcribing = "waveform.circle.fill"
        static let transcribingAlt = "sparkles"
        static let success = "checkmark.circle.fill"
        static let error = "exclamationmark.triangle.fill"
        static let downloading = "arrow.down.circle.fill"
    }
}
