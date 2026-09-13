import SwiftUI
import TVCore

/// In-app "starting soon" banner raised by `ReminderService`. Rendered as a
/// sibling layer at the root so it shows over whichever screen is up.
struct ReminderBanner: View {
    let reminder: ProgramReminder
    let onWatch: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 18) {
            Image(systemName: "bell.badge.fill")
                .font(.system(size: 28))
                .foregroundStyle(GuideTokens.accent2)
            VStack(alignment: .leading, spacing: 4) {
                Text(reminder.title)
                    .font(.headline)
                    .lineLimit(1)
                    .foregroundStyle(GuideTokens.text)
                Text("Starts \(reminder.start, format: .dateTime.hour().minute()) on \(reminder.channelNumber) \(reminder.channelName)")
                    .font(.subheadline)
                    .foregroundStyle(GuideTokens.text2)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            Button(action: onWatch) {
                Label("Watch", systemImage: "play.fill")
                    .font(.headline)
            }
            .buttonStyle(.glassProminent)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.headline)
            }
            .buttonStyle(.glass)
            .accessibilityLabel("Dismiss reminder")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .frame(maxWidth: 820)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .padding(.top, 24)
    }
}
