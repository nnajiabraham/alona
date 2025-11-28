import AppKit
import SwiftUI

struct MeetingNotesView: View {
    @EnvironmentObject private var appState: AppState
    @State private var selectedRange = NSRange(location: 0, length: 0)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            toolbar
            NotesTextView(text: $appState.notesDraft, selectedRange: $selectedRange)
                .frame(minHeight: 300)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .padding(20)
        .frame(minWidth: 420, minHeight: 360)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(appState.meetingTitle)
                    .font(.title3)
                    .bold()
                Text("Duration: \(formattedDuration)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Label(appState.isRecording ? "Recording" : "Idle",
                  systemImage: appState.isRecording ? "record.circle.fill" : "pause.circle")
                .foregroundColor(appState.isRecording ? .red : .secondary)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Button {
                insertTimestamp()
            } label: {
                Label("Timestamp", systemImage: "clock")
            }
            .buttonStyle(.bordered)

            Button {
                insertBullet()
            } label: {
                Label("Bullet", systemImage: "list.bullet")
            }
            .buttonStyle(.bordered)

            Spacer()
        }
    }

    private func insertTimestamp() {
        let snippet = "[\(formattedDuration)] "
        applySnippet(snippet)
    }

    private func insertBullet() {
        applySnippet("• ")
    }

    private func applySnippet(_ snippet: String) {
        let result = NotesInsertion.inserting(snippet: snippet, in: appState.notesDraft, range: selectedRange)
        appState.notesDraft = result.text
        selectedRange = result.range
    }

    private var formattedDuration: String {
        let totalSeconds = Int(appState.recordingDuration)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

struct NotesTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var selectedRange: NSRange

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as? NSTextView
        textView?.delegate = context.coordinator
        textView?.isRichText = false
        textView?.isAutomaticQuoteSubstitutionEnabled = false
        textView?.isAutomaticDashSubstitutionEnabled = false
        textView?.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView?.backgroundColor = .textBackgroundColor
        textView?.string = text
        if let range = textView?.selectedRange() { selectedRange = range }
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context _: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
        if textView.selectedRange() != selectedRange {
            textView.setSelectedRange(selectedRange)
            textView.scrollRangeToVisible(selectedRange)
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
            parent.text = textView.string
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.selectedRange = textView.selectedRange()
        }
    }
}

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

#Preview {
    MeetingNotesView()
        .environmentObject(AppState())
}
