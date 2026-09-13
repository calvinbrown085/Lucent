import SwiftUI
import TVCore

/// Direct channel entry: type "8.1" (or "8" and pick from the matches) and
/// go. Used as a focusable overlay on tvOS/iPad and a sheet on iPhone. Also
/// fed by hardware-keyboard digits from `NowPlayingView`.
struct ChannelNumberPad: View {
    @Binding var entry: String
    let channels: [Channel]
    let onTune: (Channel) -> Void
    let onClose: () -> Void

    @FocusState private var focusedKey: String?

    private let keys: [[String]] = [
        ["1", "2", "3"],
        ["4", "5", "6"],
        ["7", "8", "9"],
        [".", "0", "⌫"],
    ]

    private var matches: [Channel] {
        let trimmed = entry.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        let exact = channels.filter { $0.guideNumber == trimmed }
        let prefix = channels.filter { $0.guideNumber != trimmed && $0.guideNumber.hasPrefix(trimmed) }
        return Array((exact + prefix).prefix(6))
    }

    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Text("Go to channel")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(GuideTokens.text)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.glass)
                .accessibilityLabel("Close")
            }

            Text(entry.isEmpty ? "–" : entry)
                .font(.system(size: 48, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(entry.isEmpty ? GuideTokens.text4 : GuideTokens.text)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(GuideTokens.surface, in: .rect(cornerRadius: 16))

            HStack(alignment: .top, spacing: 24) {
                VStack(spacing: 12) {
                    ForEach(keys, id: \.self) { row in
                        HStack(spacing: 12) {
                            ForEach(row, id: \.self) { key in
                                Button { press(key) } label: {
                                    Text(key)
                                        .font(.system(size: 26, weight: .semibold, design: .rounded))
                                        .frame(width: 84, height: 60)
                                }
                                .buttonStyle(.glass)
                                .focused($focusedKey, equals: key)
                            }
                        }
                    }
                    Button {
                        if let first = matches.first { onTune(first) }
                    } label: {
                        Label("Go", systemImage: "arrow.right")
                            .font(.headline)
                            .frame(width: 84 * 3 + 24, height: 56)
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(matches.isEmpty)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(matches.isEmpty ? (entry.isEmpty ? "Enter a channel number" : "No match") : "Matches")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(GuideTokens.text3)
                    ForEach(matches) { ch in
                        Button { onTune(ch) } label: {
                            HStack(spacing: 12) {
                                Text(ch.guideNumber)
                                    .font(.system(.body, design: .rounded).weight(.bold))
                                    .monospacedDigit()
                                    .frame(width: 70, alignment: .leading)
                                Text(ch.guideName)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .frame(width: 260)
                        }
                        .buttonStyle(.glass)
                    }
                }
                .frame(minWidth: 280, alignment: .topLeading)
            }
        }
        .padding(28)
        .background(Color.black.opacity(0.82), in: .rect(cornerRadius: 28))
        .overlay(
            RoundedRectangle(cornerRadius: 28)
                .stroke(GuideTokens.borderStrong, lineWidth: 1)
        )
        .onAppear {
            // Land focus on the pad so the remote drives it immediately.
            focusedKey = "5"
        }
    }

    private func press(_ key: String) {
        switch key {
        case "⌫":
            if !entry.isEmpty { entry.removeLast() }
        case ".":
            if !entry.isEmpty, !entry.contains(".") { entry.append(".") }
        default:
            if entry.count < 6 { entry.append(key) }
        }
    }
}
