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
            VStack(spacing: DesignSystem.Spacing.md) {
                // Header row with icon and text
                HStack(spacing: DesignSystem.Spacing.md) {
                    // Video icon in rounded square
                    Image(systemName: "video.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.primary)
                        .padding(DesignSystem.Spacing.sm)
                        .background(Color.white.opacity(0.3))
                        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.button))

                    // Meeting info
                    Text("Meeting Detected: ")
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        +
                        Text(self.meetingTitle.isEmpty ? self.appName : self.meetingTitle)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.primary)
                }

                // Action buttons
                HStack(spacing: DesignSystem.Spacing.md) {
                    // Ignore button
                    Button {
                        self.dismiss()
                    } label: {
                        Text("Ignore")
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, DesignSystem.Spacing.sm)
                            .background(Color.white.opacity(0.2))
                            .foregroundColor(.primary)
                            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.button))
                    }
                    .buttonStyle(.plain)

                    // Record button
                    Button {
                        self.onStartRecording()
                        self.dismiss()
                    } label: {
                        Text("Record")
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, DesignSystem.Spacing.sm)
                            .background(Color.white.opacity(0.3))
                            .foregroundColor(.primary)
                            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.button))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(DesignSystem.Spacing.lg)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.container + 4))
            .shadow(color: .black.opacity(0.2), radius: 20, x: 0, y: 8)
            .frame(maxWidth: 340)
            .opacity(self.opacity)
            .onAppear {
                withAnimation(.easeIn(duration: 0.25)) {
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
            meetingTitle: "Project Sync",
            onStartRecording: {},
            onDismiss: {})
            .padding()
    }
    .frame(width: 500, height: 400)
    .background(
        Image(systemName: "photo")
            .resizable()
            .aspectRatio(contentMode: .fill)
            .opacity(0.3))
}
