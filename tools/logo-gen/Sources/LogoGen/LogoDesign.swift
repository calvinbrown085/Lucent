import SwiftUI

enum Composition {
    case icon
    case topShelf
    case topShelfWide
}

enum Layer {
    case back
    case middle
    case front
    case flat
}

struct LogoDesign: View {
    let pixelSize: CGSize
    let composition: Composition
    let layer: Layer

    var body: some View {
        Group {
            switch composition {
            case .icon:
                iconBody
            case .topShelf, .topShelfWide:
                topShelfBody
            }
        }
        .frame(width: pixelSize.width, height: pixelSize.height)
    }

    private var iconBody: some View {
        ZStack {
            if shouldShow(.back) {
                LogoColors.backgroundFill
                arcsView
            }
            if shouldShow(.middle) {
                glowView
            }
            if shouldShow(.front) {
                glyphView
            }
        }
    }

    private var topShelfBody: some View {
        ZStack {
            LogoColors.backgroundFill
            arcsView
                .opacity(0.7)
            HStack(spacing: pixelSize.height * 0.10) {
                glyphMark
                    .frame(width: pixelSize.height * 0.55, height: pixelSize.height * 0.55)
                Text("LUCENT")
                    .font(.system(size: pixelSize.height * 0.42, weight: .black, design: .default))
                    .tracking(pixelSize.height * 0.035)
                    .foregroundStyle(LogoColors.glyphGradient)
            }
            .shadow(color: LogoColors.cyanGlow.opacity(0.5), radius: pixelSize.height * 0.04)
        }
    }

    private var arcsView: some View {
        let s = min(pixelSize.width, pixelSize.height)
        let pivot = lPivot(in: pixelSize)
        return ZStack {
            ForEach(Array(arcSpecs.enumerated()), id: \.offset) { _, spec in
                ArcShape(center: pivot, radius: spec.radiusFactor * s)
                    .stroke(LogoColors.cyanGlow.opacity(spec.opacity), lineWidth: max(2, s * 0.012))
            }
        }
    }

    private var glowView: some View {
        let s = min(pixelSize.width, pixelSize.height)
        let pivot = lPivot(in: pixelSize)
        let center = UnitPoint(x: pivot.x / pixelSize.width, y: pivot.y / pixelSize.height)
        return Rectangle()
            .fill(
                RadialGradient(
                    colors: [LogoColors.cyanGlow.opacity(0.45), LogoColors.cyanGlow.opacity(0.0)],
                    center: center,
                    startRadius: 0,
                    endRadius: s * 0.6
                )
            )
    }

    private var glyphView: some View {
        glyphMark
            .frame(width: glyphSide(in: pixelSize), height: glyphSide(in: pixelSize))
            .position(glyphCenter(in: pixelSize))
    }

    private var glyphMark: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let t = side * 0.32
            let r = side * 0.06
            Rectangle()
                .fill(LogoColors.glyphGradient)
                .mask {
                    ZStack(alignment: .topLeading) {
                        RoundedRectangle(cornerRadius: r, style: .continuous)
                            .frame(width: t, height: side)
                        RoundedRectangle(cornerRadius: r, style: .continuous)
                            .frame(width: side, height: t)
                            .offset(y: side - t)
                    }
                }
        }
    }

    private func shouldShow(_ which: Layer) -> Bool {
        layer == .flat || layer == which
    }

    private func glyphSide(in size: CGSize) -> CGFloat {
        min(size.width, size.height) * 0.5
    }

    private func glyphCenter(in size: CGSize) -> CGPoint {
        CGPoint(x: size.width / 2, y: size.height / 2)
    }

    private func lPivot(in size: CGSize) -> CGPoint {
        let center = glyphCenter(in: size)
        let half = glyphSide(in: size) / 2
        return CGPoint(x: center.x - half, y: center.y + half)
    }

    private struct ArcSpec {
        let radiusFactor: CGFloat
        let opacity: Double
    }

    private var arcSpecs: [ArcSpec] {
        [
            ArcSpec(radiusFactor: 0.55, opacity: 0.22),
            ArcSpec(radiusFactor: 0.70, opacity: 0.14),
            ArcSpec(radiusFactor: 0.85, opacity: 0.08)
        ]
    }
}

private struct ArcShape: Shape {
    let center: CGPoint
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.addArc(
            center: center,
            radius: radius,
            startAngle: .degrees(270),
            endAngle: .degrees(360),
            clockwise: false
        )
        return p
    }
}

enum LogoColors {
    static let backgroundFill = LinearGradient(
        colors: [
            Color(red: 0.055, green: 0.082, blue: 0.188),
            Color(red: 0.016, green: 0.024, blue: 0.059)
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    static let cyanGlow = Color(red: 0.357, green: 0.722, blue: 1.0)

    static let glyphGradient = LinearGradient(
        colors: [
            Color(red: 0.659, green: 0.890, blue: 1.0),
            Color(red: 0.490, green: 0.827, blue: 1.0),
            Color(red: 0.357, green: 0.722, blue: 1.0)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

