import SwiftUI
#if DEBUG
    import Inject
#endif

struct OnboardingView: View {
    @EnvironmentObject private var permissionManager: PermissionManager
    #if DEBUG
        @ObserveInjection var inject
    #endif

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Welcome to Alona")
                    .font(.title)
                Text("Grant the required permissions so Alona can detect meetings, capture audio, and manage notes locally.")
                    .foregroundStyle(.secondary)
                permissionsList
                HStack {
                    Button("Refresh") {
                        permissionManager.refreshAllPermissions()
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
        @EnvironmentObject private var permissionManager: PermissionManager
        #if DEBUG
            @ObserveInjection var inject
        #endif

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(type.title)
                        .font(.headline)
                    Spacer()
                    Text(permissionManager.statuses[type]?.displayName ?? "–")
                        .font(.caption)
                        .padding(6)
                        .background(statusColor.opacity(0.2))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                HStack {
                    Button("Request Access") {
                        permissionManager.requestPermission(type)
                    }
                    Button("Open Settings") {
                        permissionManager.openSystemSettings(for: type)
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
            switch permissionManager.statuses[type] {
            case .granted: return .green
            case .denied: return .orange
            default: return .gray
            }
        }
    }
}

#Preview {
    OnboardingView()
        .environmentObject(PermissionManager())
}
