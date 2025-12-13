import SwiftUI

struct TranscriptionQueueView: View {
    @EnvironmentObject private var appState: AppState

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
                if appState.transcriptionJobs.isEmpty {
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
                    ForEach(appState.transcriptionJobs) { job in
                        jobRow(job)
                    }
                }
            }
            .listStyle(.inset)
        }
        .padding(20)
        .frame(minWidth: 460, minHeight: 420)
    }

    private var activeJobTitle: String? {
        appState.transcriptionJobs.first(where: { $0.state.isBusy })?.title
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
                    appState.cancelTranscriptionJob(job)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 4)
    }
}

private extension TranscriptionJob.State {
    var displayName: String {
        switch self {
        case .pending:
            return "Pending"
        case .preparing:
            return "Preparing"
        case let .processing(value):
            return "Processing \(Int(value * 100))%"
        case .summarizing:
            return "Summarizing"
        case let .completed(date):
            return "Completed \(date.formatted(date: .omitted, time: .shortened))"
        case .failed:
            return "Failed"
        case .cancelled:
            return "Cancelled"
        }
    }

    var statusColor: Color {
        switch self {
        case .pending, .preparing, .processing, .summarizing:
            return .accentColor
        case .completed:
            return .green
        case .failed:
            return .red
        case .cancelled:
            return .secondary
        }
    }

    var progressValue: Double? {
        if case let .processing(value) = self {
            return value
        }
        return nil
    }

    var errorDescription: String? {
        if case let .failed(message) = self {
            return message
        }
        return nil
    }
}

#Preview {
    let manager = AppState()
    return TranscriptionQueueView()
        .environmentObject(manager)
}
