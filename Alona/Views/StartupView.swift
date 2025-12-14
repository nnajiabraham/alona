import SwiftUI

struct StartupView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var permissionManager: PermissionManager
    @Environment(\.openWindow) private var openWindow
    @StateObject private var modelManager = WhisperModelManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Text("Alona runs from the menu bar (top-right near the system clock). Use the buttons below for quick access while we finish wiring the menu experience.")
                .font(.body)
                .foregroundStyle(.secondary)
            Divider()
            controls
            Spacer()
            footer
        }
        .padding(24)
        .frame(minWidth: 420, minHeight: 320)
        .background(StartupWindowIdentifierSetter())
        .task {
            modelManager.refreshStatus()
            permissionManager.refreshAllPermissions()
        }
        .onChange(of: appState.notesWindowRequestID) { _ in
            WindowFocusController.focusOrOpen(windowID: "meeting-notes", openWindow: openWindow)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Welcome to Alona")
                .font(.title2)
                .bold()
            Text(appState.isRecording ? "Recording in progress" : "Idle")
                .foregroundStyle(appState.isRecording ? .red : .secondary)
        }
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
        .environmentObject(AppState())
        .environmentObject(PermissionManager())
}
