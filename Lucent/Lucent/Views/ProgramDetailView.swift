import SwiftUI
import TVCore

struct ProgramDetailView: View {
    let program: Program
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @State private var alsoAiring: [Program] = []

    private var channel: Channel? { appModel.channel(forXmltvID: program.channelXmltvID) }

    private var isAiring: Bool {
        let now = Date.now
        return program.start <= now && program.stop > now
    }

    var body: some View {
        ZStack {
            RadialGradient(
                colors: [GuideTokens.bgGrad1, GuideTokens.bgGrad2],
                center: .top,
                startRadius: 200,
                endRadius: 1400
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 8) {
                            if let channel {
                                Text("\(channel.guideNumber) · \(channel.guideName)")
                                    .font(.headline)
                                    .foregroundStyle(GuideTokens.text3)
                            }
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

                    metaRow

                    if let desc = program.desc, !desc.isEmpty {
                        Text(desc)
                            .font(.title3)
                            .foregroundStyle(GuideTokens.text2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if !program.credits.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Cast & crew")
                                .font(.headline)
                                .foregroundStyle(GuideTokens.text3)
                            Text(program.credits.joined(separator: " · "))
                                .font(.body)
                                .foregroundStyle(GuideTokens.text2)
                        }
                    }

                    actions

                    if !alsoAiring.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Also airing")
                                .font(.headline)
                                .foregroundStyle(GuideTokens.text3)
                            ForEach(alsoAiring) { p in
                                alsoAiringRow(p)
                            }
                        }
                    }
                }
                .padding(60)
            }
        }
        .task {
            alsoAiring = (try? await appModel.airings(of: program)) ?? []
        }
    }

    private var metaRow: some View {
        HStack(spacing: 16) {
            Label {
                Text(program.start, format: .dateTime.weekday().hour().minute())
                Text("–")
                Text(program.stop, format: .dateTime.hour().minute())
            } icon: {
                Image(systemName: "clock")
            }
            .foregroundStyle(GuideTokens.text2)
            if let ep = program.episodeNumber, !ep.isEmpty {
                tag(ep, fill: GuideTokens.surface, text: GuideTokens.text2)
            }
            if let year = program.year {
                tag(String(year), fill: GuideTokens.surface, text: GuideTokens.text2)
            }
            if let rating = program.rating, !rating.isEmpty {
                tag(rating, fill: GuideTokens.surface, text: GuideTokens.text2)
            }
            if program.isNew {
                tag("NEW", fill: GuideTokens.accent.opacity(0.18), text: GuideTokens.accent2)
            }
            if program.isLive {
                tag("LIVE", fill: GuideTokens.live, text: .white)
            }
            ForEach(program.categories.prefix(3), id: \.self) { cat in
                tag(cat, fill: GuideTokens.surface, text: GuideTokens.text2)
            }
        }
    }

    private func tag(_ text: String, fill: Color, text color: Color) -> some View {
        Text(text)
            .font(.caption.weight(.heavy))
            .tracking(0.6)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(fill, in: .capsule)
            .overlay(Capsule().stroke(GuideTokens.border, lineWidth: 1))
            .foregroundStyle(color)
    }

    private var actions: some View {
        HStack(spacing: 14) {
            if isAiring, let channel {
                Button {
                    dismiss()
                    appModel.watch(channelID: channel.id)
                } label: {
                    Label("Watch Live", systemImage: "play.fill")
                }
                .buttonStyle(.glassProminent)
            }
            if FeatureFlags.reminders, program.start > .now, let channel {
                let set = appModel.reminders.isSet(programID: program.id)
                Button {
                    appModel.reminders.toggle(program: program, channel: channel)
                } label: {
                    Label(set ? "Reminder Set" : "Remind Me", systemImage: set ? "bell.fill" : "bell")
                }
                .buttonStyle(.glass)
            }
        }
    }

    private func alsoAiringRow(_ p: Program) -> some View {
        let ch = appModel.channel(forXmltvID: p.channelXmltvID)
        let set = appModel.reminders.isSet(programID: p.id)
        return HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(p.start, format: .dateTime.weekday(.abbreviated).month().day().hour().minute())
                    .font(.body.monospacedDigit())
                    .foregroundStyle(GuideTokens.text)
                Text(ch.map { "\($0.guideNumber) \($0.guideName)" } ?? p.channelXmltvID)
                    .font(.caption)
                    .foregroundStyle(GuideTokens.text3)
            }
            if let s = p.subtitle, !s.isEmpty {
                Text(s)
                    .font(.subheadline)
                    .foregroundStyle(GuideTokens.text2)
                    .lineLimit(1)
            }
            Spacer()
            if FeatureFlags.reminders, p.start > .now, let ch {
                Button {
                    appModel.reminders.toggle(program: p, channel: ch)
                } label: {
                    Image(systemName: set ? "bell.fill" : "bell")
                }
                .buttonStyle(.glass)
                .accessibilityLabel(set ? "Remove reminder" : "Remind me")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(GuideTokens.surface, in: .rect(cornerRadius: 12))
    }
}
