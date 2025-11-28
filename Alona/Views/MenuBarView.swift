import SwiftUI
#if DEBUG
    import Inject
#endif

struct MenuBarView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var permissionManager: PermissionManager
    @Environment(\.openWindow) private var openWindow
    #if DEBUG
        @ObserveInjection var inject
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            recordingControls
            Divider()
            permissionSummary
            Divider()
            footerActions
        }
        .padding(16)
        .frame(minWidth: 300)
        .task {
            permissionManager.refreshAllPermissions()
        }
        #if DEBUG
        .enableInjection()
        #endif
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

    private var recordingControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recording")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button(action: appState.toggleRecording) {
                Label(appState.isRecording ? "Stop Recording" : "Start Recording",
                      systemImage: appState.isRecording ? "stop.circle.fill" : "record.circle")
                    .foregroundColor(appState.isRecording ? .red : .primary)
            }
            .buttonStyle(.borderedProminent)
        }
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
        HStack {
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
}

#Preview {
    MenuBarView()
        .environmentObject(AppState())
        .environmentObject(PermissionManager())
}
