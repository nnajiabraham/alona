import SwiftUI

struct TranscriptionProgressView: View {
    let state: TranscriptionState

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                Image(systemName: self.statusIcon)
                    .font(.system(size: DesignSystem.IconSize.inline))
                    .foregroundStyle(self.iconColor)
                Text(self.title)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: self.progress)
                .progressViewStyle(.linear)
                .tint(self.progressColor)
            Text(self.message)
                .font(.caption)
                .foregroundStyle(self.messageColor)
        }
        .padding(DesignSystem.Spacing.md)
        .background(Color.gray.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.container))
    }

    private var statusIcon: String {
        switch self.state {
        case .idle:
            DesignSystem.StateIcon.idle
        case .preparing, .processing, .summarizing:
            DesignSystem.StateIcon.transcribing
        case .completed:
            DesignSystem.StateIcon.success
        case .failed:
            DesignSystem.StateIcon.error
        }
    }

    private var iconColor: Color {
        switch self.state {
        case .idle:
            .secondary
        case .preparing, .processing, .summarizing:
            DesignSystem.Colors.transcription
        case .completed:
            DesignSystem.Colors.success
        case .failed:
            DesignSystem.Colors.error
        }
    }

    private var progressColor: Color {
        switch self.state {
        case .failed:
            DesignSystem.Colors.error
        case .completed:
            DesignSystem.Colors.success
        default:
            DesignSystem.Colors.transcription
        }
    }

    private var title: String {
        switch self.state {
        case .idle:
            "Transcription"
        case .preparing:
            "Transcription – Preparing"
        case .processing:
            "Transcription – In Progress"
        case .summarizing:
            "Summary"
        case .completed:
            "Post-processing Complete"
        case .failed:
            "Transcription Failed"
        }
    }

    private var progress: Double {
        switch self.state {
        case .idle:
            0
        case .preparing:
            0.1
        case let .processing(value):
            max(0.1, min(0.9, value))
        case .summarizing:
            0.95
        case .completed:
            1.0
        case .failed:
            1.0
        }
    }

    private var message: String {
        switch self.state {
        case .idle:
            "Waiting for recording"
        case .preparing:
            "Loading transcription model"
        case .processing:
            "Transcribing audio locally"
        case .summarizing:
            "Generating placeholder summary"
        case .completed:
            "Artifacts saved"
        case let .failed(error):
            error
        }
    }

    private var messageColor: Color {
        if case .failed = self.state {
            return DesignSystem.Colors.error
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
