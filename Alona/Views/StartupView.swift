import SwiftUI

struct StartupView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var permissionManager: PermissionManager
    @Environment(\.openWindow) private var openWindow

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
                    openWindow(id: "recordings")
                }
                .buttonStyle(.bordered)

                if appState.currentMeetingDirectory != nil {
                    Button("Current Notes") {
                        openWindow(id: "meeting-notes")
                    }
                    .buttonStyle(.bordered)
                }
            }

            HStack(spacing: 12) {
                Button("Open Settings") {
                    openWindow(id: "settings-window")
                }
                Button("Review Permissions") {
                    openWindow(id: "onboarding")
                }
            }
        }
    }

    private var footer: some View {
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
