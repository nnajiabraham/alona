import SwiftUI
#if DEBUG
    import Inject
#endif

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    #if DEBUG
        @ObserveInjection var inject
    #endif

    var body: some View {
        @Bindable var appState = appState
        Form {
            Section("Recording") {
                Toggle("Capture system audio", isOn: $appState.captureSystemAudio)
                Text("Disabling this hides the macOS “Currently Sharing” banner and records microphone audio only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Storage") {
                VStack(alignment: .leading, spacing: 4) {
                    Text(appState.saveDirectory.path)
                        .font(.caption)
                        .textSelection(.enabled)
                    Button("Choose Folder") {
                        chooseDirectory()
                    }
                }
            }
        }
        .padding()
        .frame(width: 420)
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
        panel.directoryURL = appState.saveDirectory
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                appState.updateSaveDirectory(url)
            }
        }
    }
}

#Preview {
    SettingsView()
        .environment(AppState())
}
