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
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                Text("Welcome to Alona")
                    .font(DesignSystem.Typography.heading(24))
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
            .padding(DesignSystem.Spacing.xl)
        }
        .frame(minWidth: 420, minHeight: 420)
        .background(WindowIdentifierSetter(identifier: WindowFocusController.identifier(for: "onboarding")))
        #if DEBUG
            .enableInjection()
        #endif
    }

    private var permissionsList: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
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
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                HStack {
                    Text(self.type.title)
                        .font(DesignSystem.Typography.heading(14))
                    Spacer()
                    HStack(spacing: DesignSystem.Spacing.xs) {
                        Image(systemName: self.statusIcon)
                            .font(.system(size: DesignSystem.IconSize.inline))
                            .foregroundStyle(self.statusColor)
                        Text(self.permissionManager.statuses[self.type]?.displayName ?? "–")
                            .font(.caption)
                    }
                    .padding(.horizontal, DesignSystem.Spacing.sm)
                    .padding(.vertical, 6)
                    .background(self.statusColor.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.button))
                }
                HStack(spacing: DesignSystem.Spacing.sm) {
                    Button("Request Access") {
                        self.permissionManager.requestPermission(self.type)
                    }
                    Button("Open Settings") {
                        self.permissionManager.openSystemSettings(for: self.type)
                    }
                }
                .buttonStyle(.bordered)
            }
            .padding(DesignSystem.Spacing.md)
            .background(Color.gray.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.container))
            #if DEBUG
                .enableInjection()
            #endif
        }

        private var statusIcon: String {
            switch self.permissionManager.statuses[self.type] {
            case .granted:
                DesignSystem.StateIcon.success
            case .denied:
                DesignSystem.StateIcon.error
            default:
                "questionmark.circle"
            }
        }

        private var statusColor: Color {
            switch self.permissionManager.statuses[self.type] {
            case .granted:
                DesignSystem.Colors.success
            case .denied:
                DesignSystem.Colors.meetingDetected
            default:
                .gray
            }
        }
    }
}

#Preview {
    OnboardingView()
        .environment(PermissionManager())
}
