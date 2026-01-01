import SwiftUI
#if DEBUG
import Inject
#endif

struct OnboardingView: View {
    @Environment(PermissionManager.self) private var permissionManager
    #if DEBUG
    @ObserveInjection var inject
    #endif

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Welcome to Alona")
                    .font(.title)
                Text("Grant the required permissions so Alona can detect meetings, capture audio, and manage notes.")
                    .foregroundStyle(.secondary)
                self.permissionsList
                HStack {
                    Button("Refresh") {
                        self.permissionManager.refreshAllPermissions()
                    }
                    Spacer()
                    Button("Close") {
                        NSApp.keyWindow?.close()
                    }
                }
            }
            .padding(24)
        }
        .frame(minWidth: 420, minHeight: 420)
        .background(WindowIdentifierSetter(identifier: WindowFocusController.identifier(for: "onboarding")))
        #if DEBUG
            .enableInjection()
        #endif
    }

    private var permissionsList: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(PermissionManager.PermissionType.allCases), id: \.self) { type in
                PermissionRow(type: type)
            }
        }
    }

    private struct PermissionRow: View {
        let type: PermissionManager.PermissionType
        @Environment(PermissionManager.self) private var permissionManager
        #if DEBUG
        @ObserveInjection var inject
        #endif

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(self.type.title)
                        .font(.headline)
                    Spacer()
                    Text(self.permissionManager.statuses[self.type]?.displayName ?? "–")
                        .font(.caption)
                        .padding(6)
                        .background(self.statusColor.opacity(0.2))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                HStack {
                    Button("Request Access") {
                        self.permissionManager.requestPermission(self.type)
                    }
                    Button("Open Settings") {
                        self.permissionManager.openSystemSettings(for: self.type)
                    }
                }
                .buttonStyle(.bordered)
            }
            .padding(12)
            .background(Color.gray.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            #if DEBUG
                .enableInjection()
            #endif
        }

        private var statusColor: Color {
            switch self.permissionManager.statuses[self.type] {
            case .granted: .green
            case .denied: .orange
            default: .gray
            }
        }
    }
}

#Preview {
    OnboardingView()
        .environment(PermissionManager())
}
