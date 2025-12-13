import SwiftUI

struct RecordingsBrowserView: View {
    @EnvironmentObject private var appState: AppState
    @State private var entries: [MeetingEntry] = []
    @State private var selectedEntryID: MeetingEntry.ID?
    @State private var notesText: String = ""
    @State private var transcriptText: String = ""
    @State private var isEditingTitleFromDetail = false

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedEntryID) {
                ForEach(entries) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("Title", text: binding(for: entry))
                            .textFieldStyle(.plain)
                        .font(.headline)
                    Text(entry.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    .listRowBackground(selectionBackground(for: entry))
                    .tag(entry.id)
                }
            }
            .navigationTitle("Recordings")
            .toolbar {
                Button("Refresh", action: loadEntries)
            }
        } detail: {
            if let entry = selectedEntry {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        TextField("Title", text: binding(for: entry), onEditingChanged: { editing in
                            isEditingTitleFromDetail = editing
                        })
                        .textFieldStyle(.plain)
                            .font(.title2)
                        Text(entry.createdAt.formatted(date: .long, time: .shortened))
                            .foregroundStyle(.secondary)
                        if notesText.isEmpty {
                            Text("No notes found")
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Notes")
                                .font(.headline)
                            Text(notesText)
                                .textSelection(.enabled)
                                .font(.body)
                        }
                        transcriptSection(for: entry)
                    }
                    .padding()
                }
            } else {
                Text("Select a recording")
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear(perform: loadEntries)
        .onChange(of: selectedEntryID) { _ in
            guard !isEditingTitleFromDetail else { return }
            loadSelectedEntry()
        }
    }

    private var selectedEntry: MeetingEntry? {
        guard let id = selectedEntryID else { return nil }
        return entries.first(where: { $0.id == id })
    }

    private func loadEntries() {
        let fetched = appState.meetingFileManager.meetingEntries()
        entries = fetched
        if let currentID = selectedEntryID, entries.contains(where: { $0.id == currentID }) {
            selectedEntryID = currentID
        } else {
            selectedEntryID = entries.first?.id
        }
        loadSelectedEntry()
    }

    private func loadSelectedEntry() {
        guard let entry = selectedEntry else {
            notesText = ""
            transcriptText = ""
            return
        }
        notesText = appState.meetingFileManager.loadNotes(from: entry.directory) ?? ""
        transcriptText = appState.meetingFileManager.loadTranscript(from: entry.directory) ?? ""
    }

    @ViewBuilder
    private func transcriptSection(for entry: MeetingEntry) -> some View {
        HStack {
            Text("Transcript")
                .font(.headline)
            Spacer()
            Button {
                appState.regenerateTranscription(for: entry.directory, notes: notesText)
            } label: {
                Label("Regenerate", systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.bordered)
            .disabled(appState.isJobActive(for: entry.directory))
        }

        if appState.isJobActive(for: entry.directory) {
            Text("Transcription queued…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        if transcriptText.isEmpty {
            Text("No transcript found")
                .foregroundStyle(.secondary)
        } else {
            Text(transcriptText)
                .textSelection(.enabled)
                .font(.body)
        }
    }

    private func binding(for entry: MeetingEntry) -> Binding<String> {
        Binding(
            get: {
                entries.first(where: { $0.id == entry.id })?.title ?? entry.title
            },
            set: { newValue in
                guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
                entries[index].title = newValue
                try? appState.meetingFileManager.saveTitle(newValue, to: entry.directory)
            }
        )
    }

    private func selectionBackground(for entry: MeetingEntry) -> some View {
        Group {
            if selectedEntryID == entry.id {
                Color.accentColor.opacity(0.15)
            } else {
                Color.clear
            }
        }
    }
}

#Preview {
    RecordingsBrowserView()
        .environmentObject(AppState())
}
