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
            // Sidebar: Recording list
            self.recordingsList
        } detail: {
            // Detail: Recording content
            if let entry = selectedEntry {
                self.recordingDetail(for: entry)
            } else {
                self.emptyState
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

    // MARK: - Recordings List (Sidebar)

    private var recordingsList: some View {
        List(selection: self.$selectedEntryID) {
            ForEach(self.entries) { entry in
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                    Text(entry.title)
                        .font(DesignSystem.Typography.heading(13))
                        .lineLimit(1)

                    Text(entry.createdAt.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, DesignSystem.Spacing.xs)
                .tag(entry.id)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Recordings")
        .toolbar {
            Button {
                self.loadEntries()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh")
        }
    }

    // MARK: - Recording Detail

    private func recordingDetail(for entry: MeetingEntry) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Header section
                self.headerSection(for: entry)

                Divider()
                    .padding(.vertical, DesignSystem.Spacing.lg)

                // Audio Player section
                self.audioPlayerSection(for: entry)

                Divider()
                    .padding(.vertical, DesignSystem.Spacing.lg)

                // Transcript section
                self.transcriptSection(for: entry)

                // Notes section (always show - editable)
                Divider()
                    .padding(.vertical, DesignSystem.Spacing.lg)

                self.notesSection(for: entry)
            }
            .padding(DesignSystem.Spacing.xl)
        }
    }

    // MARK: - Header Section

    private func headerSection(for entry: MeetingEntry) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            // Editable title
            TextField("Title", text: self.binding(for: entry), onEditingChanged: { editing in
                self.isEditingTitleFromDetail = editing
            })
            .textFieldStyle(.plain)
            .font(DesignSystem.Typography.heading(24))

            // Date and time
            Text(entry.createdAt.formatted(date: .long, time: .shortened))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Audio Player Section

    private func audioPlayerSection(for entry: MeetingEntry) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            Text("Audio")
                .font(DesignSystem.Typography.heading(14))
                .foregroundStyle(.primary)

            if let error = audioPlayer.lastError {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    Image(systemName: DesignSystem.StateIcon.error)
                        .foregroundStyle(DesignSystem.Colors.error)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(DesignSystem.Colors.error)
                }
            }

            if let url = appState.meetingFileManager.recordingAudioURL(in: entry.directory) {
                HStack(spacing: DesignSystem.Spacing.md) {
                    // Play/Stop button
                    Button {
                        if self.audioPlayer.isPlaying, self.audioPlayer.playingURL == url {
                            self.audioPlayer.stop()
                        } else {
                            self.audioPlayer.play(url: url)
                        }
                    } label: {
                        HStack(spacing: DesignSystem.Spacing.sm) {
                            Image(
                                systemName: self.audioPlayer.isPlaying && self.audioPlayer.playingURL == url
                                    ? "pause.fill" : "play.fill")
                                .font(.system(size: 12))

                            Text(
                                self.audioPlayer.isPlaying && self.audioPlayer.playingURL == url
                                    ? "Pause" : "Play")
                        }
                    }
                    .buttonStyle(.bordered)

                    // Filename
                    Text(url.lastPathComponent)
                        .font(DesignSystem.Typography.mono(11))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .padding(DesignSystem.Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.button))
            } else {
                Text("No audio recording found")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(DesignSystem.Spacing.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.button))
            }
        }
    }

    // MARK: - Transcript Section

    private func transcriptSection(for entry: MeetingEntry) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            HStack {
                Text("Transcript")
                    .font(DesignSystem.Typography.heading(14))
                    .foregroundStyle(.primary)

                Spacer()

                // Transcription status or regenerate button
                if self.appState.isJobActive(for: entry.directory) {
                    HStack(spacing: DesignSystem.Spacing.xs) {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text("Transcribing...")
                            .font(.caption)
                            .foregroundStyle(DesignSystem.Colors.transcription)
                    }
                } else {
                    Button {
                        self.appState.regenerateTranscription(for: entry.directory, notes: self.notesText)
                    } label: {
                        Label("Regenerate", systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            // Transcript content
            if self.transcriptText.isEmpty {
                VStack(spacing: DesignSystem.Spacing.sm) {
                    Image(systemName: "text.quote")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text("No transcript available")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(DesignSystem.Spacing.xl)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.button))
            } else {
                Text(self.transcriptText)
                    .font(DesignSystem.Typography.mono(12))
                    .textSelection(.enabled)
                    .padding(DesignSystem.Spacing.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.button))
            }
        }
    }

    // MARK: - Notes Section

    private func notesSection(for entry: MeetingEntry) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            HStack {
                Text("Notes")
                    .font(DesignSystem.Typography.heading(14))
                    .foregroundStyle(.primary)

                Spacer()

                // Word count
                Text("\(self.notesWordCount) words")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Editable notes text area
            TextEditor(text: self.$notesText)
                .font(DesignSystem.Typography.mono(12))
                .scrollContentBackground(.hidden)
                .padding(DesignSystem.Spacing.sm)
                .frame(minHeight: 120)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.button))
                .overlay(
                    RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.button)
                        .stroke(Color.primary.opacity(0.1), lineWidth: 1))
                .onChange(of: self.notesText) {
                    self.saveNotes(for: entry)
                }
        }
    }

    private var notesWordCount: Int {
        self.notesText
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .count
    }

    private func saveNotes(for entry: MeetingEntry) {
        // Debounced save - the MeetingFileManager handles this
        try? self.appState.meetingFileManager.saveNotes(self.notesText, to: entry.directory)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: DesignSystem.Spacing.md) {
            Image(systemName: "doc.text")
                .font(.system(size: DesignSystem.IconSize.hero))
                .foregroundStyle(.secondary)

            Text("Select a recording")
                .font(.title3)
                .foregroundStyle(.secondary)

            Text("Choose a recording from the sidebar to view details")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Computed Properties

    private var selectedEntry: MeetingEntry? {
        guard let id = selectedEntryID else { return nil }
        return self.entries.first(where: { $0.id == id })
    }

    // MARK: - Methods

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
}

#Preview {
    RecordingsBrowserView()
        .environment(AppState())
}
