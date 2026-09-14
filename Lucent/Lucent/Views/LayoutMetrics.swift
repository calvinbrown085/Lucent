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
    /// iPad regular width: keep the live picture docked beside the tabs
    /// instead of taking over the screen on every tune.
    var supportsDockedPlayer: Bool = false
    var dockedPlayerWidth: CGFloat = 400
    /// 30-minute columns visible at once in the grid guide (8 = 4 hours).
    var guideVisibleSlots: Int = 8
    /// Multiplier applied to the guide's fixed point sizes (designed at
    /// 1920×1080) so the same layout reads on a phone.
    var typeScale: CGFloat = 1.0
    /// Phone: drop the hero art tile and horizontally scroll the chip row.
    var compactGuide: Bool = false

    /// Pixels-per-minute for guide grid cell layout. Derived from
    /// `guideTimeColumnWidth` (which is the px-per-30-min slot).
    var pxPerMinute: CGFloat { guideTimeColumnWidth / 30 }

    /// Shrinks `guideTimeColumnWidth` so the channel rail, 8 time slots, and
    /// horizontal padding all fit within `width`. Only narrows — never grows
    /// past the configured default — so tvOS and any container at-or-above
    /// the design width keep their original metrics.
    func adapted(toContainerWidth width: CGFloat) -> LayoutMetrics {
        let slotCount = CGFloat(guideVisibleSlots)
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
        channelGridColumns: 5,
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
        useTimelineGuide: false,
        supportsDockedPlayer: true
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
        useTimelineGuide: false,
        guideVisibleSlots: 5,
        typeScale: 0.62,
        compactGuide: true
    )

    static let iPhoneCompact = LayoutMetrics(
        channelGridColumns: 2,
        guideTimeColumnWidth: 96,
        guideRowHeight: 64,
        guideChannelRailWidth: 96,
        heroCardSize: CGSize(width: 220, height: 140),
        heroHeight: 150,
        miniGuideWidth: nil,
        contentHorizontalPadding: 16,
        contentMaxWidth: nil,
        useTimelineGuide: false,
        guideVisibleSlots: 3,
        typeScale: 0.62,
        compactGuide: true
    )

    static func resolve(
        horizontalSizeClass hsc: UserInterfaceSizeClass?,
        verticalSizeClass vsc: UserInterfaceSizeClass?
    ) -> LayoutMetrics {
        #if os(tvOS)
        return .tvOS
        #else
        // Plus/Max-size iPhones report a *regular* horizontal size class in
        // landscape, which used to route them to the iPad profile: hero card,
        // wide chip row, no room left for the guide rows. Decide by idiom
        // first, size class second.
        if UIDevice.current.userInterfaceIdiom == .phone {
            return vsc == .compact ? .iPhoneLandscape : .iPhoneCompact
        }
        // iPad in a narrow Split View slot behaves like a phone in portrait.
        if hsc == .compact {
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
