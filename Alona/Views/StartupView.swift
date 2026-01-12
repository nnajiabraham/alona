import SwiftUI

struct StartupView: View {
    @Environment(AppState.self) private var appState
    @Environment(PermissionManager.self) private var permissionManager
    @Environment(MeetingDetector.self) private var meetingDetector
    @Environment(\.openWindow) private var openWindow
    @State private var modelManager = WhisperModelManager.shared

    var body: some View {
        VStack(spacing: 0) {
            // Main content area
            VStack(spacing: DesignSystem.Spacing.xl) {
                // Hero status card
                self.heroStatusCard

                // Navigation buttons row
                self.navigationButtonsRow
            }
            .padding(DesignSystem.Spacing.xl)

            Spacer()

            // Footer status bar
            self.footerStatusBar
        }
        .frame(minWidth: 400, minHeight: 320)
        .background(StartupWindowIdentifierSetter())
        .task {
            guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
            self.modelManager.refreshAllStatuses()
            self.permissionManager.refreshAllPermissions()
        }
        .onChange(of: self.appState.notesWindowRequestID) {
            WindowFocusController.focusOrOpen(windowID: "meeting-notes", openWindow: self.openWindow)
        }
        .onChange(of: self.activeDetectionIdentifier) { _, newValue in
            self.appState.resetDetectionDismissalIfNeeded(for: newValue)
        }
    }

    // MARK: - Hero Status Card

    private var heroStatusCard: some View {
        HStack(spacing: DesignSystem.Spacing.lg) {
            // Status indicator and text
            HStack(spacing: DesignSystem.Spacing.md) {
                Circle()
                    .fill(self.statusColor)
                    .frame(width: 14, height: 14)
                    .recordingPulse(isActive: self.appState.isRecording)

                Text(self.statusText)
                    .font(DesignSystem.Typography.heading(24))
                    .foregroundStyle(.primary)
            }

            Spacer()

            // Hero mic/record icon
            self.heroIcon
        }
        .padding(DesignSystem.Spacing.xl)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.container))
        .onTapGesture {
            self.toggleRecording()
        }
    }

    private var statusText: String {
        if self.appState.isRecording {
            "Recording..."
        } else if self.meetingDetector.isInMeeting {
            "Meeting Detected"
        } else {
            "Ready to Record"
        }
    }

    private var statusColor: Color {
        if self.appState.isRecording {
            DesignSystem.Colors.recording
        } else if self.meetingDetector.isInMeeting {
            DesignSystem.Colors.meetingDetected
        } else {
            DesignSystem.Colors.success
        }
    }

    @ViewBuilder
    private var heroIcon: some View {
        let iconName = self.appState.isRecording ? "stop.circle.fill" : "mic.fill"
        let iconColor: Color = self.appState.isRecording ? DesignSystem.Colors.recording : .secondary

        Image(systemName: iconName)
            .font(.system(size: DesignSystem.IconSize.hero))
            .foregroundStyle(iconColor)
            .recordingPulse(isActive: self.appState.isRecording)
    }

    // MARK: - Navigation Buttons Row

    private var navigationButtonsRow: some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            NavigationCardButton(
                title: "Recordings",
                icon: "list.bullet.rectangle.portrait") {
                    WindowFocusController.focusOrOpen(windowID: "recordings", openWindow: self.openWindow)
                }

            NavigationCardButton(
                title: "Settings",
                icon: "gearshape") {
                    WindowFocusController.focusOrOpen(windowID: "settings-window", openWindow: self.openWindow)
                }

            NavigationCardButton(
                title: "Queue",
                icon: "list.number") {
                    WindowFocusController.focusOrOpen(windowID: "transcription-queue", openWindow: self.openWindow)
                }
        }
    }

    // MARK: - Footer Status Bar

    private var footerStatusBar: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Image(systemName: self.modelStatusIcon)
                .font(.system(size: DesignSystem.IconSize.inline))
                .foregroundStyle(self.modelStatusColor)

            Text(self.modelStatusMessage)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Spacer()

            if self.showDownloadButton {
                Button("Download") {
                    self.modelManager.downloadModel(self.modelManager.selectedModel)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, DesignSystem.Spacing.lg)
        .padding(.vertical, DesignSystem.Spacing.md)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }

    // MARK: - Detection Prompt Overlay

    private var shouldShowDetectionPrompt: Bool {
        let identifier = self.activeDetectionIdentifier
        guard !identifier.isEmpty, self.meetingDetector.isInMeeting, !self.appState.isRecording else { return false }
        return self.appState.dismissedDetectionIdentifier != identifier
    }

    private var activeDetectionIdentifier: String {
        guard self.meetingDetector.isInMeeting else { return "" }
        return "\(self.meetingDetector.detectedApp?.rawValue ?? "unknown")|\(self.meetingDetector.meetingTitle)"
    }

    private func startDetectedMeeting() {
        let identifier = self.activeDetectionIdentifier
        guard !identifier.isEmpty else { return }
        Task {
            await self.appState.startRecording(meetingTitleOverride: self.meetingDetector.meetingTitle)
            self.appState.dismissDetection(identifier: identifier)
        }
    }

    private func dismissDetectedMeeting() {
        let identifier = self.activeDetectionIdentifier
        guard !identifier.isEmpty else { return }
        self.appState.dismissDetection(identifier: identifier)
    }

    // MARK: - Model Status

    private var modelStatusMessage: String {
        let status = self.modelManager.status(for: self.modelManager.selectedModel)
        switch status {
        case .available:
            return "Whisper Model: Ready"
        case .downloading:
            return "Downloading model..."
        case .notDownloaded:
            return "Model not downloaded"
        case .failed:
            return "Download failed"
        }
    }

    private var modelStatusIcon: String {
        let status = self.modelManager.status(for: self.modelManager.selectedModel)
        switch status {
        case .available:
            return DesignSystem.StateIcon.success
        case .downloading:
            return DesignSystem.StateIcon.downloading
        case .notDownloaded, .failed:
            return DesignSystem.StateIcon.error
        }
    }

    private var modelStatusColor: Color {
        let status = self.modelManager.status(for: self.modelManager.selectedModel)
        switch status {
        case .available:
            return DesignSystem.Colors.success
        case .downloading:
            return DesignSystem.Colors.transcription
        case .notDownloaded, .failed:
            return DesignSystem.Colors.error
        }
    }

    private var showDownloadButton: Bool {
        let status = self.modelManager.status(for: self.modelManager.selectedModel)
        switch status {
        case .available, .downloading:
            return false
        case .notDownloaded, .failed:
            return true
        }
    }

    private func toggleRecording() {
        Task {
            if self.appState.isRecording {
                await self.appState.stopRecording()
            } else {
                await self.appState.startRecording()
            }
        }
    }
}

// MARK: - Navigation Card Button Component

struct NavigationCardButton: View {
    let title: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: self.action) {
            VStack(spacing: DesignSystem.Spacing.sm) {
                Image(systemName: self.icon)
                    .font(.system(size: 24))
                    .foregroundStyle(.secondary)

                Text(self.title)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, DesignSystem.Spacing.lg)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.container))
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    StartupView()
        .environment(AppState())
        .environment(PermissionManager())
        .environment(MeetingDetector())
}
