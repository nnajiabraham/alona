import SwiftUI

/// A floating notification popup similar to Granola's meeting detection notification.
/// Shows for 7 seconds then auto-dismisses.
struct MeetingDetectedPopup: View {
    let appName: String
    let meetingTitle: String
    let onStartRecording: () -> Void
    let onDismiss: () -> Void

    @State private var isVisible = true
    @State private var opacity: Double = 0

    var body: some View {
        if self.isVisible {
            HStack(spacing: 12) {
                // Close button
                Button {
                    self.dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .frame(width: 20, height: 20)

                // Meeting info
                VStack(alignment: .leading, spacing: 2) {
                    Text("Meeting detected")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Text(self.appName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Take Notes button
                Button {
                    self.onStartRecording()
                    self.dismiss()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "note.text")
                            .font(.caption)
                        Text("Take Notes")
                            .font(.subheadline)
                            .fontWeight(.medium)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.15), radius: 10, x: 0, y: 4)
            .frame(maxWidth: 320)
            .opacity(self.opacity)
            .onAppear {
                withAnimation(.easeIn(duration: 0.2)) {
                    self.opacity = 1
                }
                // Auto-dismiss after 7 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 7) {
                    self.dismiss()
                }
            }
        }
    }

    private func dismiss() {
        withAnimation(.easeOut(duration: 0.2)) {
            self.opacity = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.isVisible = false
            self.onDismiss()
        }
    }
}

#Preview {
    VStack {
        Spacer()
        MeetingDetectedPopup(
            appName: "Zoom",
            meetingTitle: "Team Standup",
            onStartRecording: {},
            onDismiss: {})
            .padding()
    }
    .frame(width: 400, height: 300)
    .background(Color.gray.opacity(0.2))
}
