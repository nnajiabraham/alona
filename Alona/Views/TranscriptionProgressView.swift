import SwiftUI

struct TranscriptionProgressView: View {
    let state: TranscriptionState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.footnote)
                .foregroundStyle(.secondary)
            ProgressView(value: progress)
                .progressViewStyle(.linear)
            Text(message)
                .font(.caption)
                .foregroundStyle(messageColor)
        }
        .padding(12)
        .background(Color.gray.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var title: String {
        switch state {
        case .idle:
            return "Transcription"
        case .preparing:
            return "Transcription – Preparing"
        case .processing:
            return "Transcription – In Progress"
        case .summarizing:
            return "Summary"
        case .completed:
            return "Post-processing Complete"
        case .failed:
            return "Transcription Failed"
        }
    }

    private var progress: Double {
        switch state {
        case .idle:
            return 0
        case .preparing:
            return 0.1
        case let .processing(value):
            return max(0.1, min(0.9, value))
        case .summarizing:
            return 0.95
        case .completed:
            return 1.0
        case .failed:
            return 1.0
        }
    }

    private var message: String {
        switch state {
        case .idle:
            return "Waiting for recording"
        case .preparing:
            return "Loading transcription model"
        case .processing:
            return "Transcribing audio locally"
        case .summarizing:
            return "Generating placeholder summary"
        case .completed:
            return "Artifacts saved"
        case let .failed(error):
            return error
        }
    }

    private var messageColor: Color {
        if case .failed = state {
            return .red
        }
        return .secondary
    }
}

#Preview {
    VStack(spacing: 16) {
        TranscriptionProgressView(state: .processing(0.4))
        TranscriptionProgressView(state: .summarizing)
        TranscriptionProgressView(state: .failed("Model missing"))
    }
    .padding()
}
