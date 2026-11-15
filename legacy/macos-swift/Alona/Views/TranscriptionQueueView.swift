import SwiftUI

struct TranscriptionQueueView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: DesignSystem.Spacing.md) {
            HStack {
                Text("Transcription Queue")
                    .font(DesignSystem.Typography.heading(16))
                Spacer()
                if let active = activeJobTitle {
                    HStack(spacing: DesignSystem.Spacing.xs) {
                        Image(systemName: DesignSystem.StateIcon.transcribing)
                            .font(.system(size: DesignSystem.IconSize.inline))
                            .foregroundStyle(DesignSystem.Colors.transcription)
                        Text("Processing: \(active)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            List {
                if self.appState.transcriptionJobs.isEmpty {
                    VStack(spacing: DesignSystem.Spacing.sm) {
                        Image(systemName: "waveform")
                            .font(.system(size: DesignSystem.IconSize.hero))
                            .foregroundStyle(.secondary)
                        Text("No queued jobs")
                            .font(DesignSystem.Typography.heading(15))
                        Text("New transcriptions appear here automatically or when you regenerate from Recordings.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, DesignSystem.Spacing.xl)
                } else {
                    ForEach(self.appState.transcriptionJobs) { job in
                        self.jobRow(job)
                    }
                }
            }
            .listStyle(.inset)
        }
        .padding(DesignSystem.Spacing.lg + DesignSystem.Spacing.xs) // 20pt
        .frame(minWidth: 460, minHeight: 420)
        .background(WindowIdentifierSetter(identifier: WindowFocusController.identifier(for: "transcription-queue")))
    }

    private var activeJobTitle: String? {
        self.appState.transcriptionJobs.first(where: { $0.state.isBusy })?.title
    }

    @ViewBuilder
    private func jobRow(_ job: TranscriptionJob) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.title)
                        .font(DesignSystem.Typography.heading(14))
                    Text(job.requestedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: DesignSystem.Spacing.xs) {
                    Image(systemName: job.state.statusIcon)
                        .font(.system(size: DesignSystem.IconSize.inline))
                    Text(job.state.displayName)
                        .font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(job.state.statusColor)
            }
            if let progress = job.state.progressValue {
                ProgressView(value: progress)
                    .tint(DesignSystem.Colors.transcription)
            }
            if let error = job.state.errorDescription {
                HStack(spacing: DesignSystem.Spacing.xs) {
                    Image(systemName: DesignSystem.StateIcon.error)
                        .font(.system(size: DesignSystem.IconSize.inline))
                    Text(error)
                        .font(.caption)
                }
                .foregroundStyle(DesignSystem.Colors.error)
            }
            if job.state.isBusy {
                Button("Cancel") {
                    self.appState.cancelTranscriptionJob(job)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, DesignSystem.Spacing.xs)
    }
}

extension TranscriptionJob.State {
    fileprivate var displayName: String {
        switch self {
        case .pending:
            "Pending"
        case .preparing:
            "Preparing"
        case let .processing(value):
            "Processing \(Int(value * 100))%"
        case .summarizing:
            "Summarizing"
        case let .completed(date):
            "Completed \(date.formatted(date: .omitted, time: .shortened))"
        case .failed:
            "Failed"
        case .cancelled:
            "Cancelled"
        }
    }

    fileprivate var statusIcon: String {
        switch self {
        case .pending:
            "clock"
        case .preparing, .processing, .summarizing:
            DesignSystem.StateIcon.transcribing
        case .completed:
            DesignSystem.StateIcon.success
        case .failed:
            DesignSystem.StateIcon.error
        case .cancelled:
            "xmark.circle"
        }
    }

    fileprivate var statusColor: Color {
        switch self {
        case .pending, .preparing, .processing, .summarizing:
            DesignSystem.Colors.transcription
        case .completed:
            DesignSystem.Colors.success
        case .failed:
            DesignSystem.Colors.error
        case .cancelled:
            .secondary
        }
    }

    fileprivate var progressValue: Double? {
        if case let .processing(value) = self {
            return value
        }
        return nil
    }

    fileprivate var errorDescription: String? {
        if case let .failed(message) = self {
            return message
        }
        return nil
    }
}

#Preview {
    let manager = AppState()
    return TranscriptionQueueView()
        .environment(manager)
}
