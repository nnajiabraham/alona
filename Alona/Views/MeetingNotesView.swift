import AppKit
import SwiftUI

struct MeetingNotesView: View {
    @Environment(AppState.self) private var appState
    @State private var selectedRange = NSRange(location: 0, length: 0)

    var body: some View {
        @Bindable var appState = appState
        VStack(spacing: 0) {
            // Recording status bar (when recording)
            if self.appState.isRecording {
                self.recordingStatusBar
            }

            // Main content
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                self.headerSection
                Divider()
                self.toolbarSection
                self.editorSection
                self.footerSection
            }
            .padding(DesignSystem.Spacing.lg)
        }
        .frame(minWidth: 480, minHeight: 400, alignment: .topLeading)
        .background(WindowIdentifierSetter(identifier: WindowFocusController.identifier(for: "meeting-notes")))
    }

    // MARK: - Recording Status Bar

    private var recordingStatusBar: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Circle()
                .fill(DesignSystem.Colors.recording)
                .frame(width: 10, height: 10)
                .recordingPulse(isActive: true)

            Text("Recording")
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(DesignSystem.Colors.recording)

            Text("•")
                .foregroundStyle(.secondary)

            Text(self.formattedDuration)
                .font(DesignSystem.Typography.mono(13))
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Spacer()

            Button {
                Task {
                    await self.appState.stopRecording()
                }
            } label: {
                Label("Stop", systemImage: "stop.fill")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .tint(DesignSystem.Colors.recording)
            .controlSize(.small)
        }
        .padding(.horizontal, DesignSystem.Spacing.lg)
        .padding(.vertical, DesignSystem.Spacing.sm)
        .background(DesignSystem.Colors.recording.opacity(0.1))
    }

    // MARK: - Header Section

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            // Meeting title (editable)
            TextField("Meeting title", text: Binding(
                get: { self.appState.meetingTitle },
                set: { self.appState.updateActiveMeetingTitle($0) }))
                .textFieldStyle(.plain)
                .font(DesignSystem.Typography.heading(20))
                .disabled(self.appState.currentMeetingDirectory == nil)

            // Date subtitle
            if self.appState.currentMeetingDirectory != nil {
                Text(Date().formatted(date: .long, time: .shortened))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text("No active recording")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Toolbar Section

    private var toolbarSection: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            // Insert timestamp
            Button {
                self.insertTimestamp()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                    Text("Timestamp")
                }
                .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!self.appState.isRecording)
            .help("Insert current timestamp")

            // Insert bullet
            Button {
                self.insertBullet()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "list.bullet")
                    Text("Bullet")
                }
                .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Insert bullet point")

            // Insert action item
            Button {
                self.insertActionItem()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.square")
                    Text("Action")
                }
                .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Insert action item")

            Spacer()
        }
    }

    // MARK: - Editor Section

    private var editorSection: some View {
        @Bindable var appState = appState
        return GeometryReader { geometry in
            NotesTextView(text: $appState.notesDraft, selectedRange: self.$selectedRange)
                .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .frame(minHeight: 200)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.button))
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.button)
                .stroke(Color.primary.opacity(0.1), lineWidth: 1))
    }

    // MARK: - Footer Section

    private var footerSection: some View {
        HStack {
            // Word count
            Text("\(self.wordCount) words")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            // Auto-save indicator
            if self.appState.currentMeetingDirectory != nil {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(DesignSystem.Colors.success)
                    Text("Auto-saved")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.top, DesignSystem.Spacing.xs)
    }

    // MARK: - Helpers

    private var wordCount: Int {
        self.appState.notesDraft
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .count
    }

    private func insertTimestamp() {
        let snippet = "[\(self.formattedDuration)] "
        self.applySnippet(snippet)
    }

    private func insertBullet() {
        self.applySnippet("• ")
    }

    private func insertActionItem() {
        self.applySnippet("☐ ")
    }

    private func applySnippet(_ snippet: String) {
        let result = NotesInsertion.inserting(
            snippet: snippet,
            in: self.appState.notesDraft,
            range: self.selectedRange)
        self.appState.notesDraft = result.text
        self.selectedRange = result.range
    }

    private var formattedDuration: String {
        let totalSeconds = Int(self.appState.recordingDuration)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

// MARK: - Notes Text View (NSViewRepresentable)

struct NotesTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var selectedRange: NSRange

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        let textView = scrollView.documentView as? NSTextView
        textView?.delegate = context.coordinator
        textView?.isRichText = false
        textView?.isAutomaticQuoteSubstitutionEnabled = false
        textView?.isAutomaticDashSubstitutionEnabled = false
        textView?.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView?.backgroundColor = .textBackgroundColor
        textView?.textContainerInset = NSSize(width: 8, height: 8)
        textView?.string = self.text

        if let range = textView?.selectedRange() {
            self.selectedRange = range
        }
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context _: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        if textView.string != self.text {
            textView.string = self.text
        }
        if textView.selectedRange() != self.selectedRange {
            textView.setSelectedRange(self.selectedRange)
            textView.scrollRangeToVisible(self.selectedRange)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NotesTextView
        weak var textView: NSTextView?

        init(_ parent: NotesTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            self.parent.text = textView.string
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            self.parent.selectedRange = textView.selectedRange()
        }
    }
}

// MARK: - Notes Insertion Helper

enum NotesInsertion {
    static func inserting(snippet: String, in text: String, range: NSRange) -> (text: String, range: NSRange) {
        let nsText = text as NSString
        let cappedLocation = max(0, min(range.location, nsText.length))
        let cappedLength = max(0, min(range.length, nsText.length - cappedLocation))
        let safeRange = NSRange(location: cappedLocation, length: cappedLength)
        let updated = nsText.replacingCharacters(in: safeRange, with: snippet)
        let snippetLength = (snippet as NSString).length
        let newRange = NSRange(location: safeRange.location + snippetLength, length: 0)
        return (updated, newRange)
    }
}

#Preview("Recording Active") {
    let appState = AppState()
    return MeetingNotesView()
        .environment(appState)
        .onAppear {
            appState.notesDraft = "Some meeting notes here\n• Point 1\n• Point 2"
        }
}

#Preview("No Recording") {
    MeetingNotesView()
        .environment(AppState())
}
