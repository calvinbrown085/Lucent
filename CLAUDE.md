# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

**Lucent** is a native **tvOS 26** app for watching live TV from an **HDHomeRun** tuner, with EPG data from either **Gracenote** (default, postal-code-based) or a self-hosted **XMLTV** URL. v1 goal: beat Jellyfin's Live TV on instant guide grid, instant channel switching, and correct **Liquid Glass** usage.

### Locked tech stack — do not propose alternates
- Swift 6 with strict concurrency (`SWIFT_STRICT_CONCURRENCY = complete`, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`)
- SwiftUI (no UIKit except `VLCPlayerView` which wraps a UIView for VLC's drawable)
- AVFoundation where it works; **TVVLCKit** for actual playback (HDHR serves raw MPEG-TS over HTTP, which AVPlayer cannot play)
- **GRDB 7.x** for the EPG cache
- Foundation `XMLParser` SAX (never DOM) for XMLTV
- `@Observable` (Observation framework), not `ObservableObject`

### v1 scope is locked tight
tvOS-only, HDHR-only. **No** DVR / recordings / series passes / remote streaming / auth / SSDP / PiP / Top Shelf. Don't propose adding these.

### Liquid Glass usage rule
Liquid Glass goes on the **navigation layer only** (tab bar, `NowPlayingView` overlay chips, Settings sheet buttons). **Never** on content (channel cards, EPG cells, video). Don't wrap `VLCPlayerView` in a `UIVisualEffectView` — VLC draws into a `CAEAGLLayer`/`CAMetalLayer` and you'll get black squares. Glass overlays must be sibling SwiftUI layers.

## Repository layout

Two-target setup in one repo:

```
Lucent/                           — repo root
├── Lucent/                       — Xcode project + app target
│   ├── Lucent.xcodeproj/
│   └── Lucent/                   — app sources (PBXFileSystemSynchronizedRootGroup)
│       ├── AppModel.swift        — top-level @Observable, owns everything
│       ├── Player/               — PlayerCoordinator + VLCPlayerView
│       ├── Settings/             — SettingsStore (UserDefaults-backed)
│       ├── Location/             — CoreLocation → postal code
│       └── Views/                — SwiftUI screens
├── TVCore/                       — sibling Swift package (cross-platform data layer)
│   └── Sources/TVCore/
│       ├── Models/               — Channel, Program, Source
│       ├── Networking/           — HDHRClient, HDHRDiscovery
│       ├── EPG/                  — EPGStore (GRDB), EPGService, XMLTVParser
│       └── Guide/Gracenote/      — GracenoteAPIClient + IngestService
├── Frameworks/                   — gitignored, holds TVVLCKit.xcframework (~600 MB) + MobileVLCKit.xcframework (~264 MB)
├── scripts/fetch-tvvlckit.sh     — populates Frameworks/ for tvOS builds
└── scripts/fetch-mobilevlckit.sh — populates Frameworks/ for iOS / iPadOS builds
```

The Xcode project uses `PBXFileSystemSynchronizedRootGroup` for `Lucent/Lucent/`, so **new Swift files under that folder are automatically target members — no pbxproj edits needed for source files**. Swift package products and frameworks still need explicit pbxproj entries.

`TVCore` is a local SwiftPM package with platforms `tvOS 26 / iOS 18 / macOS 15`, kept source-portable (no UIKit/AppKit/TVVLCKit imports). The player layer lives in the **app target** because VLCKit is platform-specific (TVVLCKit on tvOS, MobileVLCKit on iOS / iPadOS) — `PlayerCoordinator.swift` and `VLCPlayerView.swift` use `#if canImport(TVVLCKit)` / `#elseif canImport(MobileVLCKit)` so the same files build for both.

## First-time setup

```bash
scripts/fetch-tvvlckit.sh        # tvOS builds
scripts/fetch-mobilevlckit.sh    # iOS / iPadOS builds (~264 MB)
```

Downloads VLCKit 3.7.3 from videolan.org and extracts it to `Frameworks/`. The Xcode project references both XCFrameworks via `../Frameworks/{TVVLCKit,MobileVLCKit}.xcframework`, with `platformFilter` on the build files so the tvOS slice only links TVVLCKit and the iOS slice only links MobileVLCKit.

## Build, test, run

**This machine's `xcode-select -p` returns CommandLineTools, which lacks tvOS SDKs and `Testing`.** Always prepend `DEVELOPER_DIR` for any `xcodebuild` or `swift` CLI invocation:

```bash
# Build the app for the tvOS Simulator
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project Lucent/Lucent.xcodeproj -scheme Lucent \
  -destination "platform=tvOS Simulator,name=Apple TV 4K (3rd generation),OS=latest" build

# Run TVCore unit tests (swift-testing)
cd TVCore && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test

# Run a single TVCore test by name
cd TVCore && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter XMLTVParserTests
```

Don't try to `sudo xcode-select -s ...` — interactive sudo isn't available from the harness, and the global toolchain switch hasn't been opted into.

## Architecture: how data flows

**`AppModel`** (`Lucent/Lucent/Lucent/AppModel.swift`) is the single `@Observable @MainActor` owner that views read from. Its job is to orchestrate TVCore actors and expose plain values to SwiftUI.

```
LucentApp ──creates──▶ AppModel ──owns──▶ SettingsStore        (UserDefaults)
                                ──owns──▶ PlayerCoordinator    (TVVLCKit, app-target only)
                                ──owns──▶ LocationService      (CoreLocation → postalCode)
                                ──owns──▶ EPGStore             (GRDB actor, Documents/epg.sqlite)
                                ──owns──▶ EPGService           (XMLTV path)
                                ──owns──▶ GracenoteIngestService (Gracenote path)
                                ──owns──▶ HDHRDiscovery        (LAN /24 scan)
```

`bootstrap()` in `AppModel`: if no HDHR IP saved, scan the local /24; if exactly one device responds, claim it. Then call `discover.json` + `lineup.json` on the HDHR, build `[Channel]` with overrides applied, and kick off a background guide refresh.

### Two guide sources, one store

`SettingsStore.guideSource` switches between `.gracenote` and `.xmltvURL`:

- **Gracenote**: `GracenoteIngestService` hits `tvlistings.gracenote.com/api/grid` in 6-hour chunks (the endpoint's `timespan` cap), maps each chunk to an `XMLTVEvent` stream, and feeds it through `EPGStore.ingest`.
- **XMLTV**: `EPGService.refresh(from:)` does `URLSession.download` to a temp file, then `XMLTVParser.parse(contentsOf:)` SAX-streams it through the same ingest path. Always download to disk first — never load XMLTV into memory.

Both paths converge on `EPGStore.ingest(AsyncThrowingStream<XMLTVEvent>)`, which writes in **500-row transactions** so a 100k-program ingest doesn't hold one giant write lock. After every refresh, `purgeOlderThan(now - 6h)` trims the cache.

### The xmltvID join key (this is the subtle part)

`Program` rows are keyed by `channelXmltvID`. The right key for a `Channel` depends on the active guide source — see `AppModel.resolvedXmltvID`:

| Source | Default key | Why |
|---|---|---|
| `.gracenote` | `Channel.guideNumber` (e.g. `"8.1"`) | Matches Gracenote's `channelNo`, including subchannels |
| `.xmltvURL` | `Channel.guideName` | XMLTV files vary; this is a reasonable default |

Per-channel overrides live in `SettingsStore.xmltvOverrides`. **When you change `guideSource` or edit overrides, you must call `AppModel.rebuildChannelMapping()`** — `refreshGuide()` already does this. If listings stop showing up after a source switch, the join key is the first place to look; `AppModel.dumpStoreStats()` prints which xmltvIDs are stored vs. queried.

### Instant channel switching

`PlayerCoordinator` keeps a small pool of **prewarmed** `VLCMediaPlayer`s for the channels above and below the active one. On `tune(to:)` it swaps a prewarmed player into `activePlayer` instead of constructing one — that's what makes up/down feel instant. Budget: `min(prewarmCount, availableTuners - 1)` (one tuner is always reserved for the active stream; HDHR4-2US has 2 tuners, so default is 1 prewarm).

VLC live-stream tuning options (set on each `VLCMedia` in `makePlayer`): `network-caching=500`, `live-caching=500`, `clock-jitter=0`, `clock-synchro=0`. Bump `network-caching` if streams stall.

`VLCMediaPlayer` is **not Sendable** and must be used on the main thread. The project-wide `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` makes this automatic for `PlayerCoordinator`.

## Bundle / project conventions

- App target name is **Lucent** (earlier spec drafts called it "HDHRTV" — ignore those).
- Bundle ID `CalvinBrown.Lucent`.
- App Group entitlement removed for v1 (was `group.dev.lucent.shared`, reserved for a future Top Shelf extension). Re-add to `Lucent.entitlements` when Top Shelf lands.
- Deployment target tvOS 26.2.

## Logging conventions

Diagnostic prints in TVCore and AppModel are tagged `[Lucent][<subsystem>]` (e.g. `[Lucent][Gracenote]`, `[Lucent][AppModel]`). Match this prefix when adding new diagnostics so they grep cleanly.
