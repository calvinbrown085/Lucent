import SwiftUI

/// Per-platform/size-class layout constants. Resolved once in `RootView` and
/// injected via the environment so views don't have to query
/// `horizontalSizeClass` themselves. tvOS short-circuits to a fixed profile
/// because it always renders at 1920×1080 in the regular size class.
struct LayoutMetrics: Sendable, Equatable {
    var channelGridColumns: Int
    var guideTimeColumnWidth: CGFloat
    var guideRowHeight: CGFloat
    var guideChannelRailWidth: CGFloat
    var heroCardSize: CGSize
    var heroHeight: CGFloat
    /// `nil` means "present the mini-guide as a sheet"; non-nil is the side-overlay panel width.
    var miniGuideWidth: CGFloat?
    var contentHorizontalPadding: CGFloat
    /// `nil` means "no max width — fill available space".
    var contentMaxWidth: CGFloat?
    /// True when the guide should fall back to a per-channel timeline list
    /// (iPhone portrait). False keeps the wall-of-grid layout.
    var useTimelineGuide: Bool

    /// Pixels-per-minute for guide grid cell layout. Derived from
    /// `guideTimeColumnWidth` (which is the px-per-30-min slot).
    var pxPerMinute: CGFloat { guideTimeColumnWidth / 30 }

    /// Shrinks `guideTimeColumnWidth` so the channel rail, 8 time slots, and
    /// horizontal padding all fit within `width`. Only narrows — never grows
    /// past the configured default — so tvOS and any container at-or-above
    /// the design width keep their original metrics.
    func adapted(toContainerWidth width: CGFloat) -> LayoutMetrics {
        let slotCount: CGFloat = 8 // mirrors GuideTokens.visibleSlots
        let available = width - guideChannelRailWidth - contentHorizontalPadding
        guard available > 0 else { return self }
        let derived = floor(available / slotCount)
        let resolved = min(derived, guideTimeColumnWidth)
        let clamped = max(72, resolved)
        var copy = self
        copy.guideTimeColumnWidth = clamped
        return copy
    }

    static let tvOS = LayoutMetrics(
        channelGridColumns: 6,
        guideTimeColumnWidth: 200,
        guideRowHeight: 88,
        guideChannelRailWidth: 240,
        heroCardSize: CGSize(width: 360, height: 220),
        heroHeight: 280,
        miniGuideWidth: 540,
        contentHorizontalPadding: 80,
        contentMaxWidth: 1400,
        useTimelineGuide: false
    )

    static let iPadRegular = LayoutMetrics(
        channelGridColumns: 4,
        guideTimeColumnWidth: 160,
        guideRowHeight: 76,
        guideChannelRailWidth: 200,
        heroCardSize: CGSize(width: 280, height: 180),
        heroHeight: 220,
        miniGuideWidth: 540,
        contentHorizontalPadding: 40,
        contentMaxWidth: 900,
        useTimelineGuide: false
    )

    /// iPhone landscape and Split View on iPad.
    static let iPhoneLandscape = LayoutMetrics(
        channelGridColumns: 3,
        guideTimeColumnWidth: 96,
        guideRowHeight: 64,
        guideChannelRailWidth: 140,
        heroCardSize: CGSize(width: 220, height: 140),
        heroHeight: 180,
        miniGuideWidth: nil,
        contentHorizontalPadding: 24,
        contentMaxWidth: nil,
        useTimelineGuide: false
    )

    static let iPhoneCompact = LayoutMetrics(
        channelGridColumns: 2,
        guideTimeColumnWidth: 96,
        guideRowHeight: 64,
        guideChannelRailWidth: 120,
        heroCardSize: CGSize(width: 220, height: 140),
        heroHeight: 180,
        miniGuideWidth: nil,
        contentHorizontalPadding: 20,
        contentMaxWidth: nil,
        useTimelineGuide: true
    )

    static func resolve(
        horizontalSizeClass hsc: UserInterfaceSizeClass?,
        verticalSizeClass vsc: UserInterfaceSizeClass?
    ) -> LayoutMetrics {
        #if os(tvOS)
        return .tvOS
        #else
        // Compact width = iPhone portrait, or iPhone landscape on small devices,
        // or iPad multitasking in narrow Split View. Falls back to the timeline guide.
        if hsc == .compact {
            // On iPhone landscape (regular vertical / compact horizontal is rare —
            // iPhone landscape is usually compact/compact), keep the grid.
            if vsc == .compact {
                return .iPhoneLandscape
            }
            return .iPhoneCompact
        }
        return .iPadRegular
        #endif
    }
}

private struct LayoutMetricsKey: EnvironmentKey {
    static let defaultValue: LayoutMetrics = {
        #if os(tvOS)
        return .tvOS
        #else
        return .iPadRegular
        #endif
    }()
}

extension EnvironmentValues {
    var layoutMetrics: LayoutMetrics {
        get { self[LayoutMetricsKey.self] }
        set { self[LayoutMetricsKey.self] = newValue }
    }
}
