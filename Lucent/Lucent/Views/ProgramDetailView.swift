import SwiftUI
import TVCore

struct ProgramDetailView: View {
    let program: Program
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            RadialGradient(
                colors: [GuideTokens.bgGrad1, GuideTokens.bgGrad2],
                center: .top,
                startRadius: 200,
                endRadius: 1400
            )
            .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(program.title)
                            .font(.largeTitle.weight(.bold))
                            .foregroundStyle(GuideTokens.text)
                        if let s = program.subtitle, !s.isEmpty {
                            Text(s)
                                .font(.title2)
                                .foregroundStyle(GuideTokens.text2)
                        }
                    }
                    Spacer()
                    Button("Close") { dismiss() }
                        .buttonStyle(.glass)
                }

                HStack(spacing: 16) {
                    Label {
                        Text(program.start, format: .dateTime.weekday().hour().minute())
                        Text("–")
                        Text(program.stop, format: .dateTime.hour().minute())
                    } icon: {
                        Image(systemName: "clock")
                    }
                    .foregroundStyle(GuideTokens.text2)
                    if program.isNew {
                        Text("NEW")
                            .font(.caption.weight(.heavy))
                            .tracking(0.6)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(GuideTokens.accent.opacity(0.18), in: .capsule)
                            .foregroundStyle(GuideTokens.accent2)
                    }
                    if program.isLive {
                        Text("LIVE")
                            .font(.caption.weight(.heavy))
                            .tracking(0.8)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(GuideTokens.live, in: .capsule)
                            .foregroundStyle(.white)
                    }
                    ForEach(program.categories.prefix(3), id: \.self) { cat in
                        Text(cat)
                            .font(.caption)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(GuideTokens.surface, in: .capsule)
                            .overlay(Capsule().stroke(GuideTokens.border, lineWidth: 1))
                            .foregroundStyle(GuideTokens.text2)
                    }
                }

                if let desc = program.desc, !desc.isEmpty {
                    ScrollView {
                        Text(desc)
                            .font(.title3)
                            .foregroundStyle(GuideTokens.text2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                Spacer()
            }
            .padding(60)
        }
    }
}
