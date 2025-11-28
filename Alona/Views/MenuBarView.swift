import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var permissionManager: PermissionManager
    @EnvironmentObject private var meetingDetector: MeetingDetector
    @Environment(\.openWindow) private var openWindow
    @State private var recordingActionInFlight = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            detectionStatus
            if shouldShowDetectionPrompt {
                detectionPrompt
            }
            recordingControls
            if let error = appState.recordingError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Divider()
            permissionSummary
            Divider()
            footerActions
        }
        .padding(16)
        .frame(minWidth: 300)
        .task {
            permissionManager.refreshAllPermissions()
            syncMeetingTitleFromDetector()
        }
        .onChange(of: meetingDetector.meetingTitle) { _ in
            syncMeetingTitleFromDetector()
        }
        .onChange(of: meetingDetector.isInMeeting) { _ in
            syncMeetingTitleFromDetector()
        }
        .onChange(of: appState.notesWindowRequestID) { _ in
            openNotesWindow()
        }
        .onChange(of: activeDetectionIdentifier) { newValue in
            appState.resetDetectionDismissalIfNeeded(for: newValue)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Alona")
                .font(.headline)
            Text(appState.meetingTitle)
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
                    .fill(meetingDetector.isInMeeting ? Color.green : Color.gray)
                    .frame(width: 10, height: 10)
                if meetingDetector.isInMeeting {
                    Text(detectedMeetingDescription)
                } else if meetingDetector.automationPermissionDenied {
                    Text("Automation permission needed for Google Meet tabs")
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
            Button(action: toggleRecording) {
                Label(appState.isRecording ? "Stop Recording" : "Start Recording",
                      systemImage: appState.isRecording ? "stop.circle.fill" : "record.circle")
                    .foregroundColor(appState.isRecording ? .red : .primary)
            }
            .buttonStyle(.borderedProminent)
            .disabled(recordingActionInFlight)

            if appState.isRecording {
                Text("Duration: \(recordingDurationText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var detectionPrompt: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Meeting detected")
                .font(.headline)
            Text(detectedMeetingDescription)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack {
                Button("Start Recording Now") {
                    startDetectedMeeting()
                }
                .buttonStyle(.borderedProminent)
                Button("Dismiss") {
                    dismissDetectedMeeting()
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
                    Text(permissionManager.statuses[type]?.displayName ?? "–")
                        .foregroundStyle(statusColor(for: type))
                        .font(.caption)
                }
            }
        }
    }

    private var footerActions: some View {
        HStack(spacing: 12) {
            Button("Recordings") {
                openWindow(id: "recordings")
            }
            if appState.currentMeetingDirectory != nil {
                Button("Current Notes") {
                    openNotesWindow()
                }
            }
            Button("Open Settings") {
                openWindow(id: "settings-window")
            }
            Button("Review Permissions") {
                openWindow(id: "onboarding")
            }
            Spacer()
            Button("Quit") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }

    private func openNotesWindow() {
        openWindow(id: "meeting-notes")
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
        recordingActionInFlight = true
        Task {
            await appState.startRecording(meetingTitleOverride: meetingDetector.meetingTitle)
            appState.dismissDetection(identifier: identifier)
            recordingActionInFlight = false
        }
    }

    private func dismissDetectedMeeting() {
        let identifier = activeDetectionIdentifier
        guard !identifier.isEmpty else { return }
        appState.dismissDetection(identifier: identifier)
    }

    private func syncMeetingTitleFromDetector() {
        if meetingDetector.isInMeeting {
            appState.meetingTitle = meetingDetector.meetingTitle
        } else if !appState.isRecording {
            appState.meetingTitle = "No meeting detected"
        }
    }

    private func statusColor(for type: PermissionManager.PermissionType) -> Color {
        switch permissionManager.statuses[type] {
        case .granted:
            return .green
        case .denied:
            return .orange
        default:
            return .secondary
        }
    }

    private func toggleRecording() {
        guard !recordingActionInFlight else { return }
        recordingActionInFlight = true
        Task {
            if appState.isRecording {
                await appState.stopRecording()
            } else {
                await appState.startRecording()
            }
            recordingActionInFlight = false
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
        .environmentObject(AppState())
        .environmentObject(PermissionManager())
        .environmentObject(MeetingDetector())
}
