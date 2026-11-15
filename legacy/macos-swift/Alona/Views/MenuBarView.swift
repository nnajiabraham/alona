import SwiftUI

struct MenuBarView: View {
    @Environment(AppState.self) private var appState
    @Environment(PermissionManager.self) private var permissionManager
    @Environment(MeetingDetector.self) private var meetingDetector
    @Environment(\.openWindow) private var openWindow
    @State private var recordingActionInFlight = false
    @State private var recentRecordings: [MeetingEntry] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            self.header
                .padding(.horizontal, DesignSystem.Spacing.lg)
                .padding(.top, DesignSystem.Spacing.lg)
                .padding(.bottom, DesignSystem.Spacing.md)

            // Meeting Detection Card (prominent when detected)
            if self.meetingDetector.isInMeeting || self.appState.isRecording {
                self.meetingDetectionCard
                    .padding(.horizontal, DesignSystem.Spacing.lg)
                    .padding(.bottom, DesignSystem.Spacing.md)
            }

            // Recent Recordings Section
            self.recentRecordingsSection
                .padding(.horizontal, DesignSystem.Spacing.lg)
                .padding(.bottom, DesignSystem.Spacing.md)

            Spacer(minLength: DesignSystem.Spacing.sm)

            // Footer Actions
            self.footerActions
                .padding(.horizontal, DesignSystem.Spacing.lg)
                .padding(.bottom, DesignSystem.Spacing.lg)
        }
        .frame(width: 300)
        .task {
            guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
            self.permissionManager.refreshAllPermissions()
            self.syncMeetingTitleFromDetector()
            self.loadRecentRecordings()
        }
        .onChange(of: self.meetingDetector.meetingTitle) {
            self.syncMeetingTitleFromDetector()
        }
        .onChange(of: self.meetingDetector.isInMeeting) {
            self.syncMeetingTitleFromDetector()
        }
        .onChange(of: self.appState.notesWindowRequestID) {
            self.openNotesWindow()
        }
        .onChange(of: self.activeDetectionIdentifier) { _, newValue in
            self.appState.resetDetectionDismissalIfNeeded(for: newValue)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Alona")
                .font(DesignSystem.Typography.heading(18))
            Text(self.statusText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var statusText: String {
        if self.appState.isRecording {
            "Recording • \(self.recordingDurationText)"
        } else if self.meetingDetector.isInMeeting {
            "Meeting detected"
        } else {
            "Idle"
        }
    }

    // MARK: - Meeting Detection Card

    private var meetingDetectionCard: some View {
        VStack(spacing: DesignSystem.Spacing.md) {
            // Icon
            Image(systemName: self.appState.isRecording ? DesignSystem.StateIcon.recording : "video.fill")
                .font(.system(size: 32))
                .foregroundStyle(self.appState.isRecording ? DesignSystem.Colors.recording : .primary)
                .recordingPulse(isActive: self.appState.isRecording)

            // Title
            Text(self.cardTitle)
                .font(DesignSystem.Typography.heading(16))
                .multilineTextAlignment(.center)

            // Action Button
            Button(action: self.toggleRecording) {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    Image(systemName: self.appState.isRecording ? "stop.circle" : "record.circle")
                        .font(.system(size: DesignSystem.IconSize.inline))
                    Text(self.appState.isRecording ? "Stop Recording" : "Start Recording")
                        .fontWeight(.medium)
                }
                .padding(.horizontal, DesignSystem.Spacing.lg)
                .padding(.vertical, DesignSystem.Spacing.sm)
                .background(self.appState.isRecording ? Color.white.opacity(0.9) : Color.white.opacity(0.9))
                .foregroundStyle(self.appState.isRecording ? DesignSystem.Colors.recording : .primary)
                .clipShape(RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.button))
            }
            .buttonStyle(.plain)
            .disabled(self.recordingActionInFlight)
        }
        .frame(maxWidth: .infinity)
        .padding(DesignSystem.Spacing.lg)
        .background(self.cardBackgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.container))
    }

    private var cardTitle: String {
        if self.appState.isRecording {
            "Recording in Progress"
        } else if let app = self.meetingDetector.detectedApp {
            "\(app.displayName) Meeting Detected"
        } else {
            "Meeting Detected"
        }
    }

    private var cardBackgroundColor: Color {
        if self.appState.isRecording {
            DesignSystem.Colors.recording
        } else {
            DesignSystem.Colors.meetingDetected
        }
    }

    // MARK: - Recent Recordings Section

    private var recentRecordingsSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Text("Recent Recordings")
                .font(.headline)
                .foregroundStyle(.primary)

            if self.recentRecordings.isEmpty {
                Text("No recordings yet")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, DesignSystem.Spacing.sm)
            } else {
                VStack(spacing: 0) {
                    ForEach(self.recentRecordings.prefix(3)) { entry in
                        Button {
                            WindowFocusController.focusOrOpen(windowID: "recordings", openWindow: self.openWindow)
                        } label: {
                            HStack {
                                Text(entry.title)
                                    .font(.subheadline)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Text("– \(self.formatDate(entry.createdAt))")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                            .padding(.vertical, DesignSystem.Spacing.sm)
                            .padding(.horizontal, DesignSystem.Spacing.md)
                            .background(Color(nsColor: .controlBackgroundColor))
                        }
                        .buttonStyle(.plain)

                        if entry.id != self.recentRecordings.prefix(3).last?.id {
                            Divider()
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.button))
            }
        }
    }

    private func formatDate(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        } else if calendar.isDateInYesterday(date) {
            return "Yesterday"
        } else {
            let days = calendar.dateComponents([.day], from: date, to: Date()).day ?? 0
            return "\(days) days ago"
        }
    }

    private func loadRecentRecordings() {
        self.recentRecordings = self.appState.meetingFileManager.meetingEntries()
    }

    // MARK: - Footer Actions

    private var footerActions: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Button("Recordings") {
                WindowFocusController.focusOrOpen(windowID: "recordings", openWindow: self.openWindow)
            }
            .buttonStyle(.bordered)

            Spacer()

            Button("Startup") {
                StartupWindowController.focusOrOpen(openWindow: self.openWindow)
            }
            .buttonStyle(.bordered)

            Button("Quit") {
                NSApp.terminate(nil)
            }
            .buttonStyle(.bordered)
            .keyboardShortcut("q")
        }
    }

    // MARK: - Helper Methods

    private func openNotesWindow() {
        WindowFocusController.focusOrOpen(windowID: "meeting-notes", openWindow: self.openWindow)
    }

    private var activeDetectionIdentifier: String {
        guard self.meetingDetector.isInMeeting else { return "" }
        return "\(self.meetingDetector.detectedApp?.rawValue ?? "unknown")|\(self.meetingDetector.meetingTitle)"
    }

    private func syncMeetingTitleFromDetector() {
        if self.meetingDetector.isInMeeting {
            self.appState.meetingTitle = self.meetingDetector.meetingTitle
        } else if !self.appState.isRecording {
            self.appState.meetingTitle = "No meeting detected"
        }
    }

    private func toggleRecording() {
        guard !self.recordingActionInFlight else { return }
        self.recordingActionInFlight = true
        Task {
            if self.appState.isRecording {
                await self.appState.stopRecording()
            } else {
                await self.appState.startRecording()
            }
            self.recordingActionInFlight = false
        }
    }

    private var recordingDurationText: String {
        let totalSeconds = Int(appState.recordingDuration)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

#Preview {
    MenuBarView()
        .environment(AppState())
        .environment(PermissionManager())
        .environment(MeetingDetector())
}
