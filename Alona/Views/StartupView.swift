import SwiftUI

struct StartupView: View {
    @Environment(AppState.self) private var appState
    @Environment(PermissionManager.self) private var permissionManager
    @Environment(MeetingDetector.self) private var meetingDetector
    @Environment(\.openWindow) private var openWindow
    @StateObject private var modelManager = WhisperModelManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            self.header
            if self.shouldShowDetectionPrompt {
                self.detectionPrompt
            } else {
                self.detectionStatus
            }
            Divider()
            self.controls
            Spacer()
            self.footer
        }
        .padding(24)
        .frame(minWidth: 420, minHeight: 380)
        .background(StartupWindowIdentifierSetter())
        .task {
            self.modelManager.refreshStatus()
            self.permissionManager.refreshAllPermissions()
        }
        .onChange(of: self.appState.notesWindowRequestID) {
            WindowFocusController.focusOrOpen(windowID: "meeting-notes", openWindow: self.openWindow)
        }
        .onChange(of: self.activeDetectionIdentifier) { _, newValue in
            self.appState.resetDetectionDismissalIfNeeded(for: newValue)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Welcome to Alona")
                .font(.title2)
                .bold()
            if self.appState.isRecording {
                Text("Recording in progress")
                    .foregroundStyle(.red)
            } else if self.meetingDetector.isInMeeting {
                Text("Meeting detected")
                    .foregroundStyle(.orange)
            } else {
                Text("Idle")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var detectionStatus: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(self.meetingDetector.isInMeeting ? Color.green : Color.gray)
                .frame(width: 10, height: 10)
            if self.meetingDetector.isInMeeting {
                Text(self.detectedMeetingDescription)
                    .font(.subheadline)
            } else if self.meetingDetector.automationPermissionDenied {
                Text("Automation permission needed for meeting detection")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
            } else {
                Text("Waiting for meeting...")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var detectionPrompt: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "video.fill")
                    .foregroundStyle(.orange)
                Text("Meeting Detected!")
                    .font(.headline)
            }
            Text(self.detectedMeetingDescription)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button("Start Recording") {
                    self.startDetectedMeeting()
                }
                .buttonStyle(.borderedProminent)
                Button("Dismiss") {
                    self.dismissDetectedMeeting()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

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

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Button(self.appState.isRecording ? "Stop Recording" : "Start Recording") {
                    self.toggleRecording()
                }
                .buttonStyle(.borderedProminent)

                Button("Recordings") {
                    WindowFocusController.focusOrOpen(windowID: "recordings", openWindow: self.openWindow)
                }
                .buttonStyle(.bordered)

                if self.appState.currentMeetingDirectory != nil {
                    Button("Current Notes") {
                        WindowFocusController.focusOrOpen(windowID: "meeting-notes", openWindow: self.openWindow)
                    }
                    .buttonStyle(.bordered)
                }
            }

            HStack(spacing: 12) {
                Button("Open Settings") {
                    WindowFocusController.focusOrOpen(windowID: "settings-window", openWindow: self.openWindow)
                }
                Button("Review Permissions") {
                    WindowFocusController.focusOrOpen(windowID: "onboarding", openWindow: self.openWindow)
                }
                Button("Transcription Queue") {
                    WindowFocusController.focusOrOpen(windowID: "transcription-queue", openWindow: self.openWindow)
                }
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            self.modelStatusSection
            self.permissionSummary
        }
    }

    private var modelStatusSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Model status")
                .font(.footnote)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Text(self.modelStatusMessage)
                    .foregroundStyle(self.modelStatusColor)
                if self.showDownloadButton {
                    Button("Download Model") {
                        self.modelManager.downloadModel()
                    }
                }
                if case let .failed(message) = modelManager.status {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private var permissionSummary: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Permissions summary")
                .font(.footnote)
                .foregroundStyle(.secondary)
            ForEach(Array(PermissionManager.PermissionType.allCases), id: \.self) { type in
                HStack {
                    Text(type.title)
                    Spacer()
                    Text(self.permissionManager.statuses[type]?.displayName ?? "–")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var modelStatusMessage: String {
        switch self.modelManager.status {
        case .available:
            "Model installed"
        case .downloading:
            "Downloading..."
        case .missing:
            "Model missing"
        case .failed:
            "Download failed"
        }
    }

    private var modelStatusColor: Color {
        switch self.modelManager.status {
        case .available:
            .green
        case .downloading:
            .orange
        case .missing, .failed:
            .red
        }
    }

    private var showDownloadButton: Bool {
        switch self.modelManager.status {
        case .available, .downloading:
            false
        case .missing, .failed:
            true
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

#Preview {
    StartupView()
        .environment(AppState())
        .environment(PermissionManager())
        .environment(MeetingDetector())
}
