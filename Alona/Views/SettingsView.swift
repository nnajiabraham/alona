import SwiftUI
#if DEBUG
import Inject
#endif

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var modelManager = WhisperModelManager.shared
    @State private var showAllModels = false
    #if DEBUG
    @ObserveInjection var inject
    #endif

    var body: some View {
        @Bindable var appState = appState
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // MARK: - Recording Section

                SettingsSectionView(title: "Recording") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Capture system audio", isOn: $appState.captureSystemAudio)
                        Text(Self.systemAudioHelpText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                // MARK: - Transcription Model Section

                SettingsSectionView(title: "Transcription Model") {
                    ModelSelectionView(modelManager: self.modelManager, showAllModels: self.$showAllModels)
                }

                Divider()

                // MARK: - Storage Section

                SettingsSectionView(title: "Storage") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(appState.saveDirectory.path)
                            .font(.caption)
                            .textSelection(.enabled)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.primary.opacity(0.05))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        Button("Choose Folder") {
                            self.chooseDirectory()
                        }
                    }
                }
            }
            .padding(20)
        }
        .frame(width: 500, height: 560)
        .background(WindowIdentifierSetter(identifier: WindowFocusController.identifier(for: "settings-window")))
        #if DEBUG
            .enableInjection()
        #endif
    }

    // MARK: - Constants

    // swiftlint:disable:next line_length
    private static let systemAudioHelpText = "Disabling this hides the macOS \"Currently Sharing\" banner and records microphone audio only."

    // MARK: - Private Methods

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

// MARK: - Settings Section Container

struct SettingsSectionView<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(self.title)
                .font(.headline)
                .foregroundStyle(.primary)

            self.content
        }
    }
}

// MARK: - Model Selection View

struct ModelSelectionView: View {
    @Bindable var modelManager: WhisperModelManager
    @Binding var showAllModels: Bool

    private var displayedModels: [WhisperModel] {
        if self.showAllModels {
            return WhisperModel.allCases
        }
        return WhisperModel.recommendedModels
    }

    // Calculate dynamic height based on model count
    private var modelListHeight: CGFloat {
        let rowHeight: CGFloat = 56
        let maxVisibleRows: CGFloat = 5
        let modelCount = CGFloat(self.displayedModels.count)
        return min(modelCount * rowHeight, maxVisibleRows * rowHeight)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Current selection status
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
                    Label("Ready", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.green.opacity(0.1))
                        .clipShape(Capsule())
                } else {
                    Label("Download Required", systemImage: "arrow.down.circle")
                        .foregroundStyle(.orange)
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.orange.opacity(0.1))
                        .clipShape(Capsule())
                }
            }
            .padding(12)
            .background(Color.primary.opacity(0.03))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            // Model list with scroll
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(self.displayedModels) { model in
                            VStack(spacing: 0) {
                                ModelRowView(
                                    model: model,
                                    status: self.modelManager.status(for: model),
                                    isSelected: model == self.modelManager.selectedModel,
                                    onSelect: { self.modelManager.selectedModel = model },
                                    onDownload: { self.modelManager.downloadModel(model) },
                                    onCancel: { self.modelManager.cancelDownload(model) },
                                    onDelete: { self.modelManager.deleteModel(model) })

                                // Divider between rows (except last)
                                if model != self.displayedModels.last {
                                    Divider()
                                        .padding(.leading, 36)
                                }
                            }
                        }
                    }
                }
                .frame(height: self.modelListHeight)
            }
            .background(Color.primary.opacity(0.02))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.primary.opacity(0.1), lineWidth: 1))

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
            .foregroundStyle(.blue)

            // Download log (only show if there are logs or a download is active)
            if !self.modelManager.downloadLogs.isEmpty || self.isAnyDownloadActive {
                Divider()
                    .padding(.vertical, 4)

                DownloadLogView(
                    logs: self.modelManager.downloadLogs,
                    onClear: { self.modelManager.clearLogs() })
            }
        }
    }

    private var isAnyDownloadActive: Bool {
        self.modelManager.modelStatuses.values.contains { status in
            if case .downloading = status { return true }
            return false
        }
    }
}

// MARK: - Model Row View

struct ModelRowView: View {
    let model: WhisperModel
    let status: WhisperModelManager.ModelStatus
    let isSelected: Bool
    let onSelect: () -> Void
    let onDownload: () -> Void
    let onCancel: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Selection indicator
            Image(systemName: self.isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 18))
                .foregroundStyle(self.isSelected ? .blue : .secondary.opacity(0.5))

            // Model info
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(self.model.displayName)
                        .fontWeight(self.isSelected ? .semibold : .regular)
                        .lineLimit(1)

                    if self.model == .largeV3Turbo {
                        Text("Recommended")
                            .font(.caption2)
                            .fontWeight(.medium)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.blue.opacity(0.15))
                            .foregroundStyle(.blue)
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

            // Status / Action button
            self.statusView
                .frame(minWidth: 90, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(self.isSelected ? Color.blue.opacity(0.05) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { self.onSelect() }
    }

    @ViewBuilder
    private var statusView: some View {
        switch self.status {
        case .available:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
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

                    Text("\(info.percentComplete)%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 32, alignment: .trailing)

                    Button(action: self.onCancel) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.red.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                }

                // Speed and ETA
                if info.bytesPerSecond > 0 {
                    Text("\(info.formattedSpeed) • \(info.estimatedTimeRemaining)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                } else {
                    Text("Starting...")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
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
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.red)
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
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Download Log")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                if !self.logs.isEmpty {
                    Button("Clear") {
                        self.onClear()
                    }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
                }
            }

            if self.logs.isEmpty {
                Text("No download activity")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(self.logs) { entry in
                                HStack(alignment: .top, spacing: 8) {
                                    Text(entry.formattedTimestamp)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .monospacedDigit()
                                        .frame(width: 55, alignment: .leading)

                                    self.logIcon(for: entry.type)
                                        .font(.caption2)
                                        .frame(width: 12)

                                    Text(entry.message)
                                        .font(.caption)
                                        .foregroundStyle(self.logColor(for: entry.type))
                                        .lineLimit(2)
                                }
                                .id(entry.id)
                            }
                        }
                        .padding(8)
                    }
                    .frame(height: 100)
                    .background(Color.black.opacity(0.3))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .onChange(of: self.logs.count) {
                        if let lastEntry = self.logs.last {
                            withAnimation {
                                proxy.scrollTo(lastEntry.id, anchor: .bottom)
                            }
                        }
                    }
                }
            }
        }
    }

    private func logIcon(for type: WhisperModelManager.DownloadLogEntry.LogType) -> some View {
        Group {
            switch type {
            case .info:
                Image(systemName: "info.circle")
                    .foregroundStyle(.blue)
            case .progress:
                Image(systemName: "arrow.down.circle")
                    .foregroundStyle(.cyan)
            case .warning:
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            case .error:
                Image(systemName: "xmark.circle")
                    .foregroundStyle(.red)
            case .success:
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(.green)
            }
        }
    }

    private func logColor(for type: WhisperModelManager.DownloadLogEntry.LogType) -> Color {
        switch type {
        case .info: .secondary
        case .progress: .primary
        case .warning: .orange
        case .error: .red
        case .success: .green
        }
    }
}

#Preview {
    SettingsView()
        .environment(AppState())
}
