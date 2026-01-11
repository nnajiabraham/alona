import SwiftUI

struct TranscriptionQueueView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Transcription Queue")
                    .font(.title3)
                    .bold()
                Spacer()
                if let active = activeJobTitle {
                    Text("Processing: \(active)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            List {
                if self.appState.transcriptionJobs.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "waveform")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("No queued jobs")
                            .font(.headline)
                        Text("New transcriptions appear here automatically or when you regenerate from Recordings.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
                } else {
                    ForEach(self.appState.transcriptionJobs) { job in
                        self.jobRow(job)
                    }
                }
            }
            .listStyle(.inset)
        }
        .padding(20)
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
                        .font(.headline)
                    Text(job.requestedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(job.state.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(job.state.statusColor)
            }
            if let progress = job.state.progressValue {
                ProgressView(value: progress)
            }
            if let error = job.state.errorDescription {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if job.state.isBusy {
                Button("Cancel") {
                    self.appState.cancelTranscriptionJob(job)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 4)
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

    fileprivate var statusColor: Color {
        switch self {
        case .pending, .preparing, .processing, .summarizing:
            .accentColor
        case .completed:
            .green
        case .failed:
            .red
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
