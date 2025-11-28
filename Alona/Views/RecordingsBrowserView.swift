import SwiftUI

struct RecordingsBrowserView: View {
    @EnvironmentObject private var appState: AppState
    @State private var entries: [MeetingEntry] = []
    @State private var selectedEntry: MeetingEntry?
    @State private var notesText: String = ""
    @State private var transcriptText: String = ""

    var body: some View {
        NavigationSplitView {
            List(entries, selection: $selectedEntry) { entry in
                VStack(alignment: .leading) {
                    Text(entry.title)
                        .font(.headline)
                    Text(entry.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                        Text(entry.title)
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
                        if transcriptText.isEmpty {
                            Text("No transcript found")
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Transcript")
                                .font(.headline)
                            Text(transcriptText)
                                .textSelection(.enabled)
                                .font(.body)
                        }
                    }
                    .padding()
                }
            } else {
                Text("Select a recording")
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear(perform: loadEntries)
        .onChange(of: selectedEntry) { _ in
            loadSelectedEntry()
        }
    }

    private func loadEntries() {
        let fetched = appState.meetingFileManager.meetingEntries()
        entries = fetched
        if !entries.contains(where: { $0 == selectedEntry }) {
            selectedEntry = entries.first
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
}

#Preview {
    RecordingsBrowserView()
        .environmentObject(AppState())
}
