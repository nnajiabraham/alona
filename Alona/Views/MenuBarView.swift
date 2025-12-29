import SwiftUI

struct MenuBarView: View {
    @Environment(AppState.self) private var appState
    @Environment(PermissionManager.self) private var permissionManager
    @Environment(MeetingDetector.self) private var meetingDetector
    @Environment(\.openWindow) private var openWindow
    @State private var recordingActionInFlight = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            self.header
            self.detectionStatus
            if self.shouldShowDetectionPrompt {
                self.detectionPrompt
            }
            self.recordingControls
            if let error = appState.recordingError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Divider()
            self.permissionSummary
            Divider()
            self.footerActions
        }
        .padding(16)
        .frame(minWidth: 300)
        .task {
            self.permissionManager.refreshAllPermissions()
            self.syncMeetingTitleFromDetector()
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

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Alona")
                .font(.headline)
            Text(self.appState.meetingTitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var detectionStatus: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Detection")
                .font(.footnote)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Circle()
                    .fill(self.meetingDetector.isInMeeting ? Color.green : Color.gray)
                    .frame(width: 10, height: 10)
                if self.meetingDetector.isInMeeting {
                    Text(self.detectedMeetingDescription)
                } else if self.meetingDetector.automationPermissionDenied {
                    Text("Automation permission needed for meeting detection")
                } else {
                    Text("Idle – waiting for meeting")
                }
            }
            .font(.caption)
        }
    }

    private var recordingControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recording")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button(action: self.toggleRecording) {
                Label(
                    self.appState.isRecording ? "Stop Recording" : "Start Recording",
                    systemImage: self.appState.isRecording ? "stop.circle.fill" : "record.circle")
                    .foregroundColor(self.appState.isRecording ? .red : .primary)
            }
            .buttonStyle(.borderedProminent)
            .disabled(self.recordingActionInFlight)

            if self.appState.isRecording {
                Text("Duration: \(self.recordingDurationText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if self.appState.transcriptionState != .idle {
                TranscriptionProgressView(state: self.appState.transcriptionState)
            }
        }
    }

    private var detectionPrompt: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Meeting detected")
                .font(.headline)
            Text(self.detectedMeetingDescription)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack {
                Button("Start Recording Now") {
                    self.startDetectedMeeting()
                }
                .buttonStyle(.borderedProminent)
                Button("Dismiss") {
                    self.dismissDetectedMeeting()
                }
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var permissionSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Permissions")
                .font(.footnote)
                .foregroundStyle(.secondary)
            ForEach(Array(PermissionManager.PermissionType.allCases), id: \.self) { type in
                HStack {
                    Text(type.title)
                    Spacer()
                    Text(self.permissionManager.statuses[type]?.displayName ?? "–")
                        .foregroundStyle(self.statusColor(for: type))
                        .font(.caption)
                }
            }
        }
    }

    private var footerActions: some View {
        HStack(spacing: 12) {
            Button("Recordings") {
                WindowFocusController.focusOrOpen(windowID: "recordings", openWindow: self.openWindow)
            }
            Button("Open Startup") {
                StartupWindowController.focusOrOpen(openWindow: self.openWindow)
            }
            Spacer()
            Button("Quit") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }

    private func openNotesWindow() {
        WindowFocusController.focusOrOpen(windowID: "meeting-notes", openWindow: self.openWindow)
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
        self.recordingActionInFlight = true
        Task {
            await self.appState.startRecording(meetingTitleOverride: self.meetingDetector.meetingTitle)
            self.appState.dismissDetection(identifier: identifier)
            self.recordingActionInFlight = false
        }
    }

    private func dismissDetectedMeeting() {
        let identifier = self.activeDetectionIdentifier
        guard !identifier.isEmpty else { return }
        self.appState.dismissDetection(identifier: identifier)
    }

    private func syncMeetingTitleFromDetector() {
        if self.meetingDetector.isInMeeting {
            self.appState.meetingTitle = self.meetingDetector.meetingTitle
        } else if !self.appState.isRecording {
            self.appState.meetingTitle = "No meeting detected"
        }
    }

    private func statusColor(for type: PermissionManager.PermissionType) -> Color {
        switch self.permissionManager.statuses[type] {
        case .granted:
            .green
        case .denied:
            .orange
        default:
            .secondary
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
