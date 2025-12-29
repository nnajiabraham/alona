import SwiftUI

struct RecordingsBrowserView: View {
    @Environment(AppState.self) private var appState
    @State private var entries: [MeetingEntry] = []
    @State private var selectedEntryID: MeetingEntry.ID?
    @State private var notesText: String = ""
    @State private var transcriptText: String = ""
    @State private var isEditingTitleFromDetail = false
    @StateObject private var audioPlayer = RecordingAudioPlayer()

    var body: some View {
        NavigationSplitView {
            List(selection: self.$selectedEntryID) {
                ForEach(self.entries) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("Title", text: self.binding(for: entry))
                            .textFieldStyle(.plain)
                            .font(.headline)
                        Text(entry.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    .listRowBackground(self.selectionBackground(for: entry))
                    .tag(entry.id)
                }
            }
            .navigationTitle("Recordings")
            .toolbar {
                Button("Refresh", action: self.loadEntries)
            }
        } detail: {
            if let entry = selectedEntry {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        TextField("Title", text: self.binding(for: entry), onEditingChanged: { editing in
                            self.isEditingTitleFromDetail = editing
                        })
                        .textFieldStyle(.plain)
                        .font(.title2)
                        Text(entry.createdAt.formatted(date: .long, time: .shortened))
                            .foregroundStyle(.secondary)
                        if self.notesText.isEmpty {
                            Text("No notes found")
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Notes")
                                .font(.headline)
                            Text(self.notesText)
                                .textSelection(.enabled)
                                .font(.body)
                        }
                        self.audioSection(for: entry)
                        self.transcriptSection(for: entry)
                    }
                    .padding()
                }
            } else {
                Text("Select a recording")
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear(perform: self.loadEntries)
        .onChange(of: self.selectedEntryID) {
            guard !self.isEditingTitleFromDetail else { return }
            self.audioPlayer.stop()
            self.loadSelectedEntry()
        }
        .onDisappear {
            self.audioPlayer.stop()
        }
        .background(WindowIdentifierSetter(identifier: WindowFocusController.identifier(for: "recordings")))
    }

    private var selectedEntry: MeetingEntry? {
        guard let id = selectedEntryID else { return nil }
        return self.entries.first(where: { $0.id == id })
    }

    private func loadEntries() {
        let fetched = self.appState.meetingFileManager.meetingEntries()
        self.entries = fetched
        if let currentID = selectedEntryID, entries.contains(where: { $0.id == currentID }) {
            self.selectedEntryID = currentID
        } else {
            self.selectedEntryID = self.entries.first?.id
        }
        self.loadSelectedEntry()
    }

    private func loadSelectedEntry() {
        guard let entry = selectedEntry else {
            self.notesText = ""
            self.transcriptText = ""
            return
        }
        self.notesText = self.appState.meetingFileManager.loadNotes(from: entry.directory) ?? ""
        self.transcriptText = self.appState.meetingFileManager.loadTranscript(from: entry.directory) ?? ""
    }

    @ViewBuilder
    private func transcriptSection(for entry: MeetingEntry) -> some View {
        HStack {
            Text("Transcript")
                .font(.headline)
            Spacer()
            Button {
                self.appState.regenerateTranscription(for: entry.directory, notes: self.notesText)
            } label: {
                Label("Regenerate", systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.bordered)
            .disabled(self.appState.isJobActive(for: entry.directory))
        }

        if self.appState.isJobActive(for: entry.directory) {
            Text("Transcription queued…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        if self.transcriptText.isEmpty {
            Text("No transcript found")
                .foregroundStyle(.secondary)
        } else {
            Text(self.transcriptText)
                .textSelection(.enabled)
                .font(.body)
        }
    }

    @ViewBuilder
    private func audioSection(for entry: MeetingEntry) -> some View {
        Text("Audio")
            .font(.headline)

        if let error = audioPlayer.lastError {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
        }

        if let url = appState.meetingFileManager.recordingAudioURL(in: entry.directory) {
            HStack(spacing: 12) {
                Button {
                    if self.audioPlayer.isPlaying, self.audioPlayer.playingURL == url {
                        self.audioPlayer.stop()
                    } else {
                        self.audioPlayer.play(url: url)
                    }
                } label: {
                    Label(
                        self.audioPlayer.isPlaying && self.audioPlayer.playingURL == url ? "Stop" : "Play",
                        systemImage: self.audioPlayer.isPlaying && self.audioPlayer
                            .playingURL == url ? "stop.fill" : "play.fill")
                }
                .buttonStyle(.bordered)

                Text(url.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        } else {
            Text("No audio recording found")
                .foregroundStyle(.secondary)
        }
    }

    private func binding(for entry: MeetingEntry) -> Binding<String> {
        Binding(
            get: {
                self.entries.first(where: { $0.id == entry.id })?.title ?? entry.title
            },
            set: { newValue in
                guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
                self.entries[index].title = newValue
                try? self.appState.meetingFileManager.saveTitle(newValue, to: entry.directory)
            })
    }

    private func selectionBackground(for entry: MeetingEntry) -> some View {
        Group {
            if self.selectedEntryID == entry.id {
                Color.accentColor.opacity(0.15)
            } else {
                Color.clear
            }
        }
    }
}

#Preview {
    RecordingsBrowserView()
        .environment(AppState())
}
