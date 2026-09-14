import SwiftUI
import TVCore

/// The picture demo mode paints where live video would be.
///
/// Demo mode never hands the placeholder `lucent-demo://` URL to VLC, so there
/// is no decoder and no drawable to render — this view stands in for both. It's
/// deliberately a *synthetic station ident*, not a video file: it costs no
/// bundle weight, it can name the channel and program it's standing in for, and
/// it changes instantly on channel switch, which is what makes the demo show
/// off fast tuning.
///
/// It is content, not chrome, so per the project's Liquid Glass rule there is
/// no `glassEffect` anywhere in here — the Now Playing overlay chips remain the
/// only glass on that screen.
struct DemoVideoView: View {
    let channel: Channel
    var program: Program?
    /// Hero-tile rendering: same motion, smaller type, fewer labels.
    var compact: Bool = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                backdrop

                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                    Canvas { ctx, size in
                        draw(in: &ctx, size: size, time: context.date.timeIntervalSinceReferenceDate)
                    }
                }
                .allowsHitTesting(false)

                vignette

                if compact {
                    compactOverlay
                } else {
                    fullOverlay(size: geo.size)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .background(Color.black)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Demo mode: simulated picture for \(channel.guideNumber) \(channel.guideName)")
    }

    // MARK: - Painted layers

    private var backdrop: some View {
        LinearGradient(
            colors: [
                Color(hue: hue, saturation: 0.62, brightness: 0.34),
                Color(hue: hue, saturation: 0.78, brightness: 0.15),
                Color(hue: (hue + 0.08).truncatingRemainder(dividingBy: 1), saturation: 0.72, brightness: 0.08),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var vignette: some View {
        RadialGradient(
            colors: [.clear, .black.opacity(0.55)],
            center: .center,
            startRadius: 0,
            endRadius: compact ? 260 : 900
        )
        .allowsHitTesting(false)
    }

    /// Everything that moves: drifting light blobs for depth, antenna arcs
    /// sweeping out of the lower-left corner, and a slow horizontal sheen.
    private func draw(in ctx: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        let tint = Color(hue: hue, saturation: 0.45, brightness: 1.0)

        // Drifting blobs — the "there is footage under here" layer.
        for i in 0..<3 {
            let speed = 0.05 + Double(i) * 0.017
            let phase = time * speed + Double(i) * 2.1
            let cx = size.width * (0.5 + 0.34 * cos(phase))
            let cy = size.height * (0.5 + 0.30 * sin(phase * 1.37))
            let radius = min(size.width, size.height) * (0.34 + 0.06 * sin(phase * 0.8))
            let rect = CGRect(x: cx - radius, y: cy - radius, width: radius * 2, height: radius * 2)
            ctx.fill(
                Path(ellipseIn: rect),
                with: .radialGradient(
                    Gradient(colors: [tint.opacity(0.22), .clear]),
                    center: CGPoint(x: cx, y: cy),
                    startRadius: 0,
                    endRadius: radius
                )
            )
        }

        // Antenna arcs: over-the-air signal, expanding and fading.
        let origin = CGPoint(x: size.width * 0.13, y: size.height * 0.9)
        let maxRadius = hypot(size.width, size.height) * 1.05
        let arcCount = 5
        let arcPeriod = 3.4
        for i in 0..<arcCount {
            var phase = (time / arcPeriod + Double(i) / Double(arcCount)).truncatingRemainder(dividingBy: 1)
            if phase < 0 { phase += 1 }
            let radius = maxRadius * phase
            guard radius > 1 else { continue }
            var path = Path()
            path.addArc(
                center: origin,
                radius: radius,
                startAngle: .degrees(-92),
                endAngle: .degrees(4),
                clockwise: false
            )
            ctx.stroke(
                path,
                with: .color(tint.opacity(0.5 * (1 - phase) * (1 - phase))),
                lineWidth: compact ? 1.5 : 3
            )
        }

        // Sheen: a wide soft band travelling left to right.
        let sheenPeriod = 7.5
        var sweep = (time / sheenPeriod).truncatingRemainder(dividingBy: 1)
        if sweep < 0 { sweep += 1 }
        let bandWidth = size.width * 0.42
        let x = -bandWidth + (size.width + bandWidth * 2) * sweep
        ctx.fill(
            Path(CGRect(x: x - bandWidth / 2, y: 0, width: bandWidth, height: size.height)),
            with: .linearGradient(
                Gradient(colors: [.clear, .white.opacity(0.055), .clear]),
                startPoint: CGPoint(x: x - bandWidth / 2, y: 0),
                endPoint: CGPoint(x: x + bandWidth / 2, y: 0)
            )
        )
    }

    // MARK: - Labels

    private func fullOverlay(size: CGSize) -> some View {
        let scale = max(0.55, min(1.0, size.width / 1920))
        // Portrait phone: the Now Playing chips already carry the channel and
        // this row would sit under the status bar, so the station bug and
        // clock are dropped there.
        let showTopRow = size.width >= 700
        return VStack(spacing: 0) {
            if showTopRow {
                HStack(alignment: .top) {
                    channelBug(scale: scale)
                    Spacer()
                    clock(scale: scale)
                }
            }
            Spacer()
            ident(scale: scale)
            Spacer()
            HStack(alignment: .bottom) {
                Text("SIMULATED PICTURE — NO TUNER CONNECTED")
                    .font(.system(size: 15 * scale, weight: .semibold))
                    .tracking(1.4)
                    .foregroundStyle(.white.opacity(0.42))
                Spacer()
            }
        }
        .padding(.horizontal, 64 * scale)
        .padding(.vertical, 52 * scale)
        .safeAreaPadding(.all)
    }

    private var compactOverlay: some View {
        VStack {
            HStack {
                Text("DEMO")
                    .font(.system(size: 11, weight: .heavy))
                    .tracking(1.6)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.45), in: .rect(cornerRadius: 4))
                    .foregroundStyle(.white.opacity(0.85))
                Spacer()
            }
            Spacer()
            HStack {
                Text(channel.guideName.uppercased())
                    .font(.system(size: 13, weight: .heavy))
                    .tracking(1.6)
                    .lineLimit(1)
                    .foregroundStyle(.white.opacity(0.75))
                Spacer()
            }
        }
        .padding(14)
    }

    private func channelBug(scale: CGFloat) -> some View {
        HStack(spacing: 12 * scale) {
            TimelineView(.periodic(from: .now, by: 0.6)) { context in
                let on = Int(context.date.timeIntervalSinceReferenceDate / 0.6) % 2 == 0
                Circle()
                    .fill(GuideTokens.live)
                    .frame(width: 12 * scale, height: 12 * scale)
                    .opacity(on ? 1 : 0.3)
            }
            Text("LIVE")
                .font(.system(size: 17 * scale, weight: .heavy))
                .tracking(1.8)
            Text(channel.guideNumber)
                .font(.system(size: 20 * scale, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.75))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 20 * scale)
        .padding(.vertical, 12 * scale)
        .background(.black.opacity(0.32), in: .capsule)
        .overlay(Capsule().stroke(.white.opacity(0.14), lineWidth: 1))
    }

    private func clock(scale: CGFloat) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(context.date, format: .dateTime.hour().minute())
                .font(.system(size: 22 * scale, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.7))
                .padding(.horizontal, 18 * scale)
                .padding(.vertical, 10 * scale)
                .background(.black.opacity(0.32), in: .capsule)
        }
    }

    private func ident(scale: CGFloat) -> some View {
        VStack(spacing: 14 * scale) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 54 * scale, weight: .light))
                .foregroundStyle(.white.opacity(0.9))
            Text(channel.guideName)
                .font(.system(size: 76 * scale, weight: .bold, design: .rounded))
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .foregroundStyle(.white)
            if let program {
                Text(program.title)
                    .font(.system(size: 30 * scale, weight: .medium))
                    .lineLimit(1)
                    .foregroundStyle(.white.opacity(0.78))
                progressBar(for: program, scale: scale)
            }
            Text("LUCENT DEMO MODE")
                .font(.system(size: 15 * scale, weight: .heavy))
                .tracking(3.0)
                .foregroundStyle(.white.opacity(0.5))
                .padding(.top, 4 * scale)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: 900 * scale)
    }

    /// Progress through the current program, refreshed every 10s — the same
    /// clock the guide's now-line runs on, so the two agree.
    private func progressBar(for program: Program, scale: CGFloat) -> some View {
        TimelineView(.periodic(from: .now, by: 10)) { context in
            let total = max(1, program.stop.timeIntervalSince(program.start))
            let elapsed = context.date.timeIntervalSince(program.start)
            let fraction = max(0, min(1, elapsed / total))
            VStack(spacing: 8 * scale) {
                GeometryReader { bar in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.18))
                        Capsule()
                            .fill(.white.opacity(0.85))
                            .frame(width: bar.size.width * fraction)
                    }
                }
                .frame(height: 5 * scale)
                HStack {
                    Text(program.start, format: .dateTime.hour().minute())
                    Spacer()
                    Text(program.stop, format: .dateTime.hour().minute())
                }
                .font(.system(size: 15 * scale, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.55))
            }
            .frame(width: 420 * scale)
        }
        .frame(height: 34 * scale)
    }

    /// Stable per-channel hue so every station keeps its own colour identity
    /// across launches and between the hero tile and fullscreen.
    ///
    /// Drawn from a curated set rather than the full wheel: at the low
    /// brightness this backdrop runs at, yellows and yellow-greens turn to mud,
    /// and every station deserves to look deliberate.
    private static let hues: [Double] = [
        0.60,  // blue
        0.68,  // indigo
        0.78,  // violet
        0.88,  // magenta
        0.96,  // crimson
        0.04,  // red-orange
        0.08,  // amber
        0.45,  // teal
        0.52,  // cyan
        0.36,  // spruce
    ]

    private var hue: Double {
        var hash: UInt64 = 5381
        for byte in channel.guideNumber.utf8 {
            hash = (hash &* 33) &+ UInt64(byte)
        }
        return Self.hues[Int(hash % UInt64(Self.hues.count))]
    }
}

/// Live picture for a channel: real video normally, the demo ident in demo mode.
/// Both `NowPlayingView` and the guide hero tile go through here so the two
/// screens can never disagree about which one they're showing.
struct LiveVideoLayer: View {
    let channel: Channel
    var program: Program?
    var compact: Bool = false

    @Environment(AppModel.self) private var appModel

    var body: some View {
        if appModel.isDemoMode {
            DemoVideoView(channel: channel, program: program, compact: compact)
        } else {
            VLCPlayerView()
        }
    }
}
