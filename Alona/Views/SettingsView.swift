import SwiftUI
#if DEBUG
import Inject
#endif

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var modelManager = WhisperModelManager.shared
    @State private var selectedTab: SettingsTab = .general
    #if DEBUG
    @ObserveInjection var inject
    #endif

    enum SettingsTab: String, CaseIterable {
        case general = "General"
        case transcriptionModels = "Transcription Models"

        var icon: String {
            switch self {
            case .general:
                "gearshape"
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
            case .general:
                GeneralSettingsView()
            case .transcriptionModels:
                TranscriptionModelsSettingsView(modelManager: self.modelManager)
            }
        }
        .frame(width: 700, height: 500)
        .background(WindowIdentifierSetter(identifier: WindowFocusController.identifier(for: "settings-window")))
        #if DEBUG
            .enableInjection()
        #endif
    }
}

// MARK: - General Settings View

struct GeneralSettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState

        ScrollView {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xl) {
                // Header
                Text("General")
                    .font(DesignSystem.Typography.heading(20))

                // Recording Section
                SettingsSectionCard(title: "Recording", icon: "waveform") {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                        Toggle("Capture system audio", isOn: $appState.captureSystemAudio)

                        Text(
                            "Disabling this hides the macOS \"Currently Sharing\" banner and records microphone audio only.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // Storage Section
                SettingsSectionCard(title: "Storage", icon: "folder") {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                        Text("Recordings are saved to:")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        Text(appState.saveDirectory.path)
                            .font(DesignSystem.Typography.mono(12))
                            .textSelection(.enabled)
                            .padding(DesignSystem.Spacing.md)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.button))

                        Button("Choose Folder...") {
                            self.chooseDirectory()
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            .padding(DesignSystem.Spacing.xl)
        }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.prompt = "Select"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = self.appState.saveDirectory
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                self.appState.updateSaveDirectory(url)
            }
        }
    }
}

// MARK: - Settings Section Card

struct SettingsSectionCard<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            Label(self.title, systemImage: self.icon)
                .font(DesignSystem.Typography.heading(14))
                .foregroundStyle(.primary)

            self.content
        }
        .padding(DesignSystem.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.container))
    }
}

// MARK: - Transcription Models Settings View

struct TranscriptionModelsSettingsView: View {
    @Bindable var modelManager: WhisperModelManager
    @State private var showAllModels = false

    private var displayedModels: [WhisperModel] {
        if self.showAllModels {
            return WhisperModel.allCases
        }
        return WhisperModel.recommendedModels
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                // Header
                Text("Transcription Models")
                    .font(DesignSystem.Typography.heading(20))

                // Active model status
                self.activeModelStatus

                // Model list
                self.modelList

                // Show more/less toggle
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        self.showAllModels.toggle()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(
                            self.showAllModels
                                ? "Show Recommended Only"
                                : "Show All Models (\(WhisperModel.allCases.count))")
                        Image(systemName: self.showAllModels ? "chevron.up" : "chevron.down")
                            .font(.caption2)
                    }
                    .font(.caption)
                    .fontWeight(.medium)
                }
                .buttonStyle(.plain)
                .foregroundStyle(DesignSystem.Colors.primary)

                // Download log
                if !self.modelManager.downloadLogs.isEmpty || self.isAnyDownloadActive {
                    Divider()
                    DownloadLogView(
                        logs: self.modelManager.downloadLogs,
                        onClear: { self.modelManager.clearLogs() })
                }
            }
            .padding(DesignSystem.Spacing.xl)
        }
    }

    private var activeModelStatus: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Active Model")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(self.modelManager.selectedModel.displayName)
                    .fontWeight(.medium)
            }
            Spacer()
            if self.modelManager.isSelectedModelAvailable {
                Label("Ready", systemImage: DesignSystem.StateIcon.success)
                    .foregroundStyle(DesignSystem.Colors.success)
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(DesignSystem.Colors.success.opacity(0.1))
                    .clipShape(Capsule())
            } else {
                Label("Download Required", systemImage: "arrow.down.circle")
                    .foregroundStyle(DesignSystem.Colors.meetingDetected)
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(DesignSystem.Colors.meetingDetected.opacity(0.1))
                    .clipShape(Capsule())
            }
        }
        .padding(DesignSystem.Spacing.md)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.button))
    }

    private var modelList: some View {
        VStack(spacing: 0) {
            ForEach(self.displayedModels) { model in
                VStack(spacing: 0) {
                    ModelSettingsRow(
                        model: model,
                        status: self.modelManager.status(for: model),
                        isSelected: model == self.modelManager.selectedModel,
                        onSelect: { self.modelManager.selectedModel = model },
                        onDownload: { self.modelManager.downloadModel(model) },
                        onCancel: { self.modelManager.cancelDownload(model) },
                        onDelete: { self.modelManager.deleteModel(model) })

                    if model != self.displayedModels.last {
                        Divider()
                            .padding(.leading, 36)
                    }
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.container))
    }

    private var isAnyDownloadActive: Bool {
        self.modelManager.modelStatuses.values.contains { status in
            if case .downloading = status { return true }
            return false
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
        HStack(spacing: DesignSystem.Spacing.md) {
            // Selection indicator
            Image(systemName: self.isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 18))
                .foregroundStyle(self.isSelected ? DesignSystem.Colors.primary : .secondary.opacity(0.5))

            // Model info
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(self.model.displayName)
                        .fontWeight(self.isSelected ? .semibold : .regular)
                        .lineLimit(1)

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

                    if self.model.isQuantized {
                        Text("Quantized")
                            .font(.caption2)
                            .fontWeight(.medium)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.purple.opacity(0.15))
                            .foregroundStyle(.purple)
                            .clipShape(Capsule())
                    }
                }

                HStack(spacing: 6) {
                    Text(self.model.formattedSize)
                    Text("•")
                        .foregroundStyle(.tertiary)
                    Text(self.model.speedMultiplier)
                    Text("•")
                        .foregroundStyle(.tertiary)
                    Text(self.model.qualityDescription)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            // Status / Action
            self.statusView
                .frame(minWidth: 100, alignment: .trailing)
        }
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.vertical, DesignSystem.Spacing.sm)
        .background(self.isSelected ? DesignSystem.Colors.primary.opacity(0.05) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { self.onSelect() }
    }

    @ViewBuilder
    private var statusView: some View {
        switch self.status {
        case .available:
            HStack(spacing: 6) {
                Image(systemName: DesignSystem.StateIcon.success)
                    .foregroundStyle(DesignSystem.Colors.success)
                    .font(.system(size: 14))

                Menu {
                    Button(role: .destructive, action: self.onDelete) {
                        Label("Delete Model", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

        case let .downloading(progress, info):
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 6) {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .frame(width: 60)
                        .tint(DesignSystem.Colors.transcription)

                    Text("\(info.percentComplete)%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 32, alignment: .trailing)

                    Button(action: self.onCancel) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(DesignSystem.Colors.error.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                }

                if info.bytesPerSecond > 0 {
                    Text("\(info.formattedSpeed) • \(info.estimatedTimeRemaining)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

        case .notDownloaded:
            Button(action: self.onDownload) {
                Label("Download", systemImage: "arrow.down.circle")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

        case let .failed(error):
            HStack(spacing: 6) {
                Image(systemName: DesignSystem.StateIcon.error)
                    .font(.system(size: 14))
                    .foregroundStyle(DesignSystem.Colors.error)
                    .help(error)

                Button(action: self.onDownload) {
                    Text("Retry")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }
}

// MARK: - Download Log View

struct DownloadLogView: View {
    let logs: [WhisperModelManager.DownloadLogEntry]
    let onClear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack {
                Text("Download Log")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear") {
                    self.onClear()
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(DesignSystem.Colors.primary)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(self.logs) { entry in
                        HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
                            Text("[\(entry.formattedTimestamp)]")
                                .foregroundStyle(.secondary)
                            Text(entry.message)
                                .foregroundStyle(self.logColor(for: entry))
                        }
                        .font(DesignSystem.Typography.logConsole)
                    }
                }
                .padding(DesignSystem.Spacing.sm)
            }
            .frame(height: 120)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.button))
        }
    }

    private func logColor(for entry: WhisperModelManager.DownloadLogEntry) -> Color {
        if entry.message.lowercased().contains("error") || entry.message.lowercased().contains("failed") {
            return DesignSystem.Colors.error
        } else if entry.message.lowercased().contains("complete") || entry.message.lowercased().contains("success") {
            return DesignSystem.Colors.success
        }
        return .primary
    }
}

#Preview {
    SettingsView()
        .environment(AppState())
}
