import AppKit
import SwiftUI

struct MeetingNotesView: View {
    @Environment(AppState.self) private var appState
    @State private var selectedRange = NSRange(location: 0, length: 0)

    var body: some View {
        @Bindable var appState = appState
        VStack(alignment: .leading, spacing: 16) {
            self.header
            self.toolbar
            GeometryReader { editorProxy in
                NotesTextView(text: $appState.notesDraft, selectedRange: self.$selectedRange)
                    .frame(width: editorProxy.size.width, height: editorProxy.size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .frame(minHeight: 280)
        }
        .padding(20)
        .frame(minWidth: 420, minHeight: 360, alignment: .topLeading)
        .background(WindowIdentifierSetter(identifier: WindowFocusController.identifier(for: "meeting-notes")))
    }

    private var header: some View {
        TextField("Meeting title", text: Binding(
            get: { self.appState.meetingTitle },
            set: { self.appState.updateActiveMeetingTitle($0) }))
            .textFieldStyle(.plain)
            .font(.title3)
            .bold()
            .disabled(self.appState.currentMeetingDirectory == nil)
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Button {
                self.insertTimestamp()
            } label: {
                Label("Timestamp", systemImage: "clock")
            }
            .buttonStyle(.bordered)

            Button {
                self.insertBullet()
            } label: {
                Label("Bullet", systemImage: "list.bullet")
            }
            .buttonStyle(.bordered)

            Spacer()
        }
    }

    private func insertTimestamp() {
        let snippet = "[\(formattedDuration)] "
        self.applySnippet(snippet)
    }

    private func insertBullet() {
        self.applySnippet("• ")
    }

    private func applySnippet(_ snippet: String) {
        let result = NotesInsertion.inserting(snippet: snippet, in: self.appState.notesDraft, range: self.selectedRange)
        self.appState.notesDraft = result.text
        self.selectedRange = result.range
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
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        let textView = scrollView.documentView as? NSTextView
        textView?.delegate = context.coordinator
        textView?.isRichText = false
        textView?.isAutomaticQuoteSubstitutionEnabled = false
        textView?.isAutomaticDashSubstitutionEnabled = false
        textView?.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView?.backgroundColor = .textBackgroundColor
        textView?.string = self.text
        if let range = textView?.selectedRange() { self.selectedRange = range }
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
        .environment(AppState())
}
