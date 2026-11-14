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
            VStack(spacing: DesignSystem.Spacing.lg) {
                // Hero status card (clickable to record)
                self.heroStatusCard

                // Detection prompt (when meeting detected)
                if self.shouldShowDetectionPrompt {
                    self.detectionPrompt
                }

                // Navigation buttons row
                self.navigationButtonsRow

                // Secondary actions row
                self.secondaryActionsRow
            }
            .padding(DesignSystem.Spacing.xl)

            Spacer()

            // Footer with model status and permissions
            self.footerSection
        }
        .frame(minWidth: 440, minHeight: 420)
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

                VStack(alignment: .leading, spacing: 2) {
                    Text(self.statusText)
                        .font(DesignSystem.Typography.heading(20))
                        .foregroundStyle(.primary)

                    if self.appState.isRecording {
                        Text(self.recordingDurationText)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    } else if self.meetingDetector.isInMeeting {
                        Text(self.detectedMeetingDescription)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
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

    private var recordingDurationText: String {
        let totalSeconds = Int(self.appState.recordingDuration)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    // MARK: - Detection Prompt

    private var detectionPrompt: some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            Image(systemName: "video.fill")
                .font(.system(size: 24))
                .foregroundStyle(DesignSystem.Colors.meetingDetected)

            VStack(alignment: .leading, spacing: 2) {
                Text("Meeting Detected!")
                    .font(DesignSystem.Typography.heading(14))
                Text(self.detectedMeetingDescription)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: DesignSystem.Spacing.sm) {
                Button("Record") {
                    self.startDetectedMeeting()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button("Dismiss") {
                    self.dismissDetectedMeeting()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(DesignSystem.Spacing.md)
        .background(DesignSystem.Colors.meetingDetected.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.button))
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

    // MARK: - Secondary Actions Row

    private var secondaryActionsRow: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Button {
                WindowFocusController.focusOrOpen(windowID: "onboarding", openWindow: self.openWindow)
            } label: {
                Label("Permissions", systemImage: "lock.shield")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            if self.appState.currentMeetingDirectory != nil {
                Button {
                    self.appState.requestNotesWindow()
                } label: {
                    Label("Current Notes", systemImage: "note.text")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Spacer()
        }
    }

    // MARK: - Footer Section

    private var footerSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            Divider()

            // Model status
            self.modelStatusRow

            // Permissions summary
            self.permissionsSummary
        }
        .padding(.horizontal, DesignSystem.Spacing.xl)
        .padding(.bottom, DesignSystem.Spacing.lg)
    }

    private var modelStatusRow: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            Text("Model status")
                .font(.footnote)
                .foregroundStyle(.secondary)

            HStack(spacing: DesignSystem.Spacing.sm) {
                Image(systemName: self.modelStatusIcon)
                    .font(.system(size: DesignSystem.IconSize.inline))
                    .foregroundStyle(self.modelStatusColor)

                Text(self.modelStatusMessage)
                    .foregroundStyle(self.modelStatusColor)

                Spacer()

                if self.showDownloadButton {
                    Button("Download") {
                        self.modelManager.downloadModel(self.modelManager.selectedModel)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }

    private var permissionsSummary: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            Text("Permissions summary")
                .font(.footnote)
                .foregroundStyle(.secondary)

            ForEach(Array(PermissionManager.PermissionType.allCases), id: \.self) { type in
                HStack {
                    Text(type.title)
                        .font(.subheadline)
                    Spacer()
                    Text(self.permissionManager.statuses[type]?.displayName ?? "–")
                        .font(.caption)
                        .foregroundStyle(self.permissionStatusColor(for: type))
                }
            }
        }
    }

    private func permissionStatusColor(for type: PermissionManager.PermissionType) -> Color {
        guard let status = self.permissionManager.statuses[type] else { return .secondary }
        switch status {
        case .granted:
            return DesignSystem.Colors.success
        case .denied:
            return DesignSystem.Colors.error
        case .notDetermined:
            return .secondary
        }
    }

    // MARK: - Detection Helpers

    private var shouldShowDetectionPrompt: Bool {
        let identifier = self.activeDetectionIdentifier
        guard !identifier.isEmpty, self.meetingDetector.isInMeeting, !self.appState.isRecording else { return false }
        return self.appState.dismissedDetectionIdentifier != identifier
    }

    private var activeDetectionIdentifier: String {
        guard self.meetingDetector.isInMeeting else { return "" }
        return "\(self.meetingDetector.detectedApp?.rawValue ?? "unknown")|\(self.meetingDetector.meetingTitle)"
    }

    private var detectedMeetingDescription: String {
        let appName = self.meetingDetector.detectedApp?.displayName ?? "Meeting"
        return "\(appName) – \(self.meetingDetector.meetingTitle)"
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
            return "\(self.modelManager.selectedModel.displayName) ready"
        case .downloading:
            return "Downloading..."
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
