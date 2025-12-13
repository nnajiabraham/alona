import Foundation

protocol SummaryProviding {
    func generateSummary(transcript: String, notes: String) async throws -> String
}

final class SummaryManager: SummaryProviding {
    private let provider: SummaryProviding

    init(provider: SummaryProviding = PlaceholderSummaryProvider()) {
        self.provider = provider
    }

    func generateSummary(transcript: String, notes: String) async throws -> String {
        try await provider.generateSummary(transcript: transcript, notes: notes)
    }
}

struct PlaceholderSummaryProvider: SummaryProviding {
    func generateSummary(transcript: String, notes: String) async throws -> String {
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let date = Date().formatted(date: .abbreviated, time: .shortened)
        let notesSnippet = notes.isEmpty ? "*No notes provided*" : notes.prefix(200)
        let transcriptSnippet = transcript.isEmpty ? "*Transcript pending*" : transcript.prefix(200)
        return """
        # Meeting Summary
        *Generated: \(date)*

        ## Highlights
        - Placeholder summary derived from transcript and notes.
        - Transcript sample: \(transcriptSnippet)…

        ## Notes Snapshot
        \(notesSnippet)…

        ## Next Steps
        - [ ] Replace placeholder generator with ML-powered provider.
        """
    }
}
