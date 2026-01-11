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
        Form {
            Section("Recording") {
                Toggle("Capture system audio", isOn: $appState.captureSystemAudio)
                Text("Disabling this hides the macOS \"Currently Sharing\" banner and records microphone audio only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Transcription Model") {
                ModelSelectionView(modelManager: self.modelManager, showAllModels: self.$showAllModels)
            }

            Section("Storage") {
                VStack(alignment: .leading, spacing: 4) {
                    Text(appState.saveDirectory.path)
                        .font(.caption)
                        .textSelection(.enabled)
                    Button("Choose Folder") {
                        self.chooseDirectory()
                    }
                }
            }
        }
        .padding()
        .frame(width: 480, height: 520)
        .background(WindowIdentifierSetter(identifier: WindowFocusController.identifier(for: "settings-window")))
        #if DEBUG
            .enableInjection()
        #endif
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Current selection
            HStack {
                Text("Selected:")
                    .foregroundStyle(.secondary)
                Text(self.modelManager.selectedModel.displayName)
                    .fontWeight(.medium)
                Spacer()
                if self.modelManager.isSelectedModelAvailable {
                    Label("Ready", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                } else {
                    Label("Not Downloaded", systemImage: "arrow.down.circle")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }
            }

            Divider()

            // Model list
            ForEach(self.displayedModels) { model in
                ModelRowView(
                    model: model,
                    status: self.modelManager.status(for: model),
                    isSelected: model == self.modelManager.selectedModel,
                    onSelect: { self.modelManager.selectedModel = model },
                    onDownload: { self.modelManager.downloadModel(model) },
                    onCancel: { self.modelManager.cancelDownload(model) },
                    onDelete: { self.modelManager.deleteModel(model) })
            }

            // Show more/less toggle
            Button {
                self.showAllModels.toggle()
            } label: {
                HStack {
                    Text(self.showAllModels ? "Show Recommended Only" : "Show All Models")
                    Image(systemName: self.showAllModels ? "chevron.up" : "chevron.down")
                }
                .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.blue)
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
                .foregroundStyle(self.isSelected ? .blue : .secondary)
                .onTapGesture { self.onSelect() }

            // Model info
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(self.model.displayName)
                        .fontWeight(self.isSelected ? .semibold : .regular)

                    if self.model == .largeV3Turbo {
                        Text("Recommended")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.blue.opacity(0.2))
                            .foregroundStyle(.blue)
                            .clipShape(Capsule())
                    }

                    if self.model.isQuantized {
                        Text("Quantized")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.purple.opacity(0.2))
                            .foregroundStyle(.purple)
                            .clipShape(Capsule())
                    }
                }

                HStack(spacing: 8) {
                    Text(self.model.formattedSize)
                    Text("•")
                    Text(self.model.speedMultiplier)
                    Text("•")
                    Text(self.model.qualityDescription)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            // Status / Action button
            self.statusView
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture { self.onSelect() }
    }

    @ViewBuilder
    private var statusView: some View {
        switch self.status {
        case .available:
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)

                Menu {
                    Button(role: .destructive, action: self.onDelete) {
                        Label("Delete Model", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 24)
            }

        case let .downloading(progress):
            HStack(spacing: 8) {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(width: 60)

                Text("\(Int(progress * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 35, alignment: .trailing)

                Button(action: self.onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            }

        case .notDownloaded:
            Button(action: self.onDownload) {
                Label("Download", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

        case let .failed(error):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .help(error)

                Button(action: self.onDownload) {
                    Text("Retry")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }
}

#Preview {
    SettingsView()
        .environment(AppState())
}
