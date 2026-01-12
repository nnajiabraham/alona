import SwiftUI
#if DEBUG
import Inject
#endif

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var modelManager = WhisperModelManager.shared
    @State private var selectedTab: SettingsTab = .transcriptionModels
    #if DEBUG
    @ObserveInjection var inject
    #endif

    enum SettingsTab: String, CaseIterable {
        case transcriptionModels = "Transcription Models"

        var icon: String {
            switch self {
            case .transcriptionModels:
                "mic.fill"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            // Sidebar
            List(SettingsTab.allCases, id: \.self, selection: self.$selectedTab) { tab in
                Label(tab.rawValue, systemImage: tab.icon)
                    .tag(tab)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            // Detail content
            switch self.selectedTab {
            case .transcriptionModels:
                TranscriptionModelsSettingsView(modelManager: self.modelManager)
            }
        }
        .frame(width: 650, height: 450)
        .background(WindowIdentifierSetter(identifier: WindowFocusController.identifier(for: "settings-window")))
        #if DEBUG
            .enableInjection()
        #endif
    }
}

// MARK: - Transcription Models Settings View

struct TranscriptionModelsSettingsView: View {
    @Bindable var modelManager: WhisperModelManager

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            Text("Transcription Models")
                .font(DesignSystem.Typography.heading(20))
                .padding(.horizontal, DesignSystem.Spacing.xl)
                .padding(.top, DesignSystem.Spacing.xl)
                .padding(.bottom, DesignSystem.Spacing.lg)

            // Model list
            List {
                ForEach(WhisperModel.allCases) { model in
                    ModelSettingsRow(
                        model: model,
                        status: self.modelManager.status(for: model),
                        isSelected: model == self.modelManager.selectedModel,
                        onSelect: { self.modelManager.selectedModel = model },
                        onDownload: { self.modelManager.downloadModel(model) },
                        onCancel: { self.modelManager.cancelDownload(model) },
                        onDelete: { self.modelManager.deleteModel(model) })
                }
            }
            .listStyle(.inset)
        }
    }
}

// MARK: - Model Settings Row

struct ModelSettingsRow: View {
    let model: WhisperModel
    let status: WhisperModelManager.ModelStatus
    let isSelected: Bool
    let onSelect: () -> Void
    let onDownload: () -> Void
    let onCancel: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: DesignSystem.Spacing.lg) {
            // Status icon
            self.statusIcon
                .frame(width: 24, alignment: .center)

            // Model name
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    Text(self.model.displayName)
                        .fontWeight(self.isSelected ? .semibold : .regular)

                    if self.model == .largeV3Turbo {
                        Text("Default")
                            .font(.caption2)
                            .fontWeight(.medium)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(DesignSystem.Colors.primary.opacity(0.15))
                            .foregroundStyle(DesignSystem.Colors.primary)
                            .clipShape(Capsule())
                    }
                }
                Text(self.model.formattedSize)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Status text
            Text(self.statusText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(minWidth: 120, alignment: .leading)

            // Progress (if downloading)
            if case let .downloading(progress, _) = status {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(width: 80)
            }

            // Action button
            self.actionButton
                .frame(width: 80)
        }
        .padding(.vertical, DesignSystem.Spacing.xs)
        .contentShape(Rectangle())
        .onTapGesture {
            if case .available = self.status {
                self.onSelect()
            }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch self.status {
        case .available:
            Image(systemName: DesignSystem.StateIcon.success)
                .foregroundStyle(DesignSystem.Colors.success)
                .font(.system(size: DesignSystem.IconSize.status))

        case .downloading:
            Image(systemName: DesignSystem.StateIcon.downloading)
                .foregroundStyle(DesignSystem.Colors.transcription)
                .font(.system(size: DesignSystem.IconSize.status))

        case .notDownloaded:
            Image(systemName: "arrow.down.circle")
                .foregroundStyle(.secondary)
                .font(.system(size: DesignSystem.IconSize.status))

        case .failed:
            Image(systemName: DesignSystem.StateIcon.error)
                .foregroundStyle(DesignSystem.Colors.error)
                .font(.system(size: DesignSystem.IconSize.status))
        }
    }

    private var statusText: String {
        switch self.status {
        case .available:
            "Status: Ready"
        case let .downloading(_, info):
            "Downloading... \(info.percentComplete)%"
        case .notDownloaded:
            "Status: Not Downloaded"
        case let .failed(error):
            "Failed: \(error)"
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch self.status {
        case .available:
            Button("Delete") {
                self.onDelete()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

        case .downloading:
            Button("Cancel") {
                self.onCancel()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

        case .notDownloaded:
            Button("Download") {
                self.onDownload()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

        case .failed:
            Button("Retry") {
                self.onDownload()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }
}

#Preview {
    SettingsView()
        .environment(AppState())
}
