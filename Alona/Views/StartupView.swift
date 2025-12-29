import SwiftUI

struct StartupView: View {
    @Environment(AppState.self) private var appState
    @Environment(PermissionManager.self) private var permissionManager
    @Environment(MeetingDetector.self) private var meetingDetector
    @Environment(\.openWindow) private var openWindow
    @StateObject private var modelManager = WhisperModelManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if shouldShowDetectionPrompt {
                detectionPrompt
            } else {
                detectionStatus
            }
            Divider()
            controls
            Spacer()
            footer
        }
        .padding(24)
        .frame(minWidth: 420, minHeight: 380)
        .background(StartupWindowIdentifierSetter())
        .task {
            modelManager.refreshStatus()
            permissionManager.refreshAllPermissions()
        }
        .onChange(of: appState.notesWindowRequestID) {
            WindowFocusController.focusOrOpen(windowID: "meeting-notes", openWindow: openWindow)
        }
        .onChange(of: activeDetectionIdentifier) { _, newValue in
            appState.resetDetectionDismissalIfNeeded(for: newValue)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Welcome to Alona")
                .font(.title2)
                .bold()
            if appState.isRecording {
                Text("Recording in progress")
                    .foregroundStyle(.red)
            } else if meetingDetector.isInMeeting {
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
                .fill(meetingDetector.isInMeeting ? Color.green : Color.gray)
                .frame(width: 10, height: 10)
            if meetingDetector.isInMeeting {
                Text(detectedMeetingDescription)
                    .font(.subheadline)
            } else if meetingDetector.automationPermissionDenied {
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
            Text(detectedMeetingDescription)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button("Start Recording") {
                    startDetectedMeeting()
                }
                .buttonStyle(.borderedProminent)
                Button("Dismiss") {
                    dismissDetectedMeeting()
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
        let identifier = activeDetectionIdentifier
        guard !identifier.isEmpty, meetingDetector.isInMeeting, !appState.isRecording else { return false }
        return appState.dismissedDetectionIdentifier != identifier
    }

    private var activeDetectionIdentifier: String {
        guard meetingDetector.isInMeeting else { return "" }
        return "\(meetingDetector.detectedApp?.rawValue ?? "unknown")|\(meetingDetector.meetingTitle)"
    }

    private var detectedMeetingDescription: String {
        let appName = meetingDetector.detectedApp?.displayName ?? "Meeting"
        return "\(appName) – \(meetingDetector.meetingTitle)"
    }

    private func startDetectedMeeting() {
        let identifier = activeDetectionIdentifier
        guard !identifier.isEmpty else { return }
        Task {
            await appState.startRecording(meetingTitleOverride: meetingDetector.meetingTitle)
            appState.dismissDetection(identifier: identifier)
        }
    }

    private func dismissDetectedMeeting() {
        let identifier = activeDetectionIdentifier
        guard !identifier.isEmpty else { return }
        appState.dismissDetection(identifier: identifier)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Button(appState.isRecording ? "Stop Recording" : "Start Recording") {
                    toggleRecording()
                }
                .buttonStyle(.borderedProminent)

                Button("Recordings") {
                    WindowFocusController.focusOrOpen(windowID: "recordings", openWindow: openWindow)
                }
                .buttonStyle(.bordered)

                if appState.currentMeetingDirectory != nil {
                    Button("Current Notes") {
                        WindowFocusController.focusOrOpen(windowID: "meeting-notes", openWindow: openWindow)
                    }
                    .buttonStyle(.bordered)
                }
            }

            HStack(spacing: 12) {
                Button("Open Settings") {
                    WindowFocusController.focusOrOpen(windowID: "settings-window", openWindow: openWindow)
                }
                Button("Review Permissions") {
                    WindowFocusController.focusOrOpen(windowID: "onboarding", openWindow: openWindow)
                }
                Button("Transcription Queue") {
                    WindowFocusController.focusOrOpen(windowID: "transcription-queue", openWindow: openWindow)
                }
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            modelStatusSection
            permissionSummary
        }
    }

    private var modelStatusSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Model status")
                .font(.footnote)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Text(modelStatusMessage)
                    .foregroundStyle(modelStatusColor)
                if showDownloadButton {
                    Button("Download Model") {
                        modelManager.downloadModel()
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
                    Text(permissionManager.statuses[type]?.displayName ?? "–")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var modelStatusMessage: String {
        switch modelManager.status {
        case .available:
            return "Model installed"
        case .downloading:
            return "Downloading..."
        case .missing:
            return "Model missing"
        case .failed:
            return "Download failed"
        }
    }

    private var modelStatusColor: Color {
        switch modelManager.status {
        case .available:
            return .green
        case .downloading:
            return .orange
        case .missing, .failed:
            return .red
        }
    }

    private var showDownloadButton: Bool {
        switch modelManager.status {
        case .available, .downloading:
            return false
        case .missing, .failed:
            return true
        }
    }

    private func toggleRecording() {
        Task {
            if appState.isRecording {
                await appState.stopRecording()
            } else {
                await appState.startRecording()
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
