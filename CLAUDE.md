# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

**Lucent** is a native app for watching live TV from an **HDHomeRun** tuner, with EPG data from either **Gracenote** (default, postal-code-based) or a self-hosted **XMLTV** URL. **tvOS 26** is the primary target; the same app target also builds for **iOS / iPadOS 26** (`TARGETED_DEVICE_FAMILY = 1,2,3`). v1 goal: beat Jellyfin's Live TV on instant guide grid, instant channel switching, and correct **Liquid Glass** usage.

### Locked tech stack — do not propose alternates
- Swift 6 with strict concurrency (`SWIFT_STRICT_CONCURRENCY = complete`, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`)
- SwiftUI (no UIKit except `VLCPlayerView` which wraps a UIView for VLC's drawable)
- AVFoundation where it works; **TVVLCKit** for actual playback (HDHR serves raw MPEG-TS over HTTP, which AVPlayer cannot play)
- **GRDB 7.x** for the EPG cache
- Foundation `XMLParser` SAX (never DOM) for XMLTV
- `@Observable` (Observation framework), not `ObservableObject`

### v1 scope is locked tight
HDHR-only. **No** DVR / recordings / series passes / remote streaming / auth / SSDP / Top Shelf. Don't propose adding these. Live-TV pause/rewind (time-shift) is filed for a later build — see memory. **PiP (iOS / iPadOS) is back in** as of 2026-09-12, see "Picture in Picture" below; it is never available on tvOS.

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
│       ├── Player/               — PlayerCoordinator, VLCPlayerView, SleepTimer,
│       │                           AudioLatencyMonitor, AudioSessionConfigurator (iOS-only)
│       ├── Settings/             — SettingsStore (UserDefaults-backed) + FavoritesCloudSync (iCloud KVS)
│       ├── Location/             — CoreLocation → postal code
│       └── Views/                — SwiftUI screens (adaptive via LayoutMetrics)
├── TVCore/                       — sibling Swift package (cross-platform data layer)
│   └── Sources/TVCore/
│       ├── Models/               — Channel, Program, Source
│       ├── Networking/           — HDHRClient, HDHRDiscovery
│       ├── EPG/                  — EPGStore (GRDB), EPGService, XMLTVParser
│       └── Guide/Gracenote/      — GracenoteAPIClient + IngestService
├── Frameworks/                   — gitignored, holds TVVLCKit.xcframework (~600 MB) + MobileVLCKit.xcframework (~264 MB)
├── scripts/fetch-tvvlckit.sh     — populates Frameworks/ for tvOS builds
├── scripts/fetch-mobilevlckit.sh — populates Frameworks/ for iOS / iPadOS builds
├── scripts/generate-placeholder-icons.sh — regenerates placeholder app icons (idempotent)
├── tools/logo-gen/               — standalone SwiftPM CLI that renders the app logo assets
└── docs/                         — static marketing/support/privacy site (plain HTML)
```

CI: `.github/workflows/swift.yml` runs `swift build` / `swift test` on macos-latest for pushes/PRs to main.

TestFlight: `scripts/testflight.sh [tvos|ios|all] [--build N] [--no-upload] [--dry-run]` archives with `generic/platform=…`, exports with method `app-store-connect` and `destination upload`. Auth via `ASC_KEY_ID` / `ASC_ISSUER_ID` / `ASC_KEY_PATH` (App Store Connect API key) or, if unset, the Apple ID signed into Xcode. Build number defaults to a UTC `yyyyMMddHHmm` timestamp so it always increases. Logs land in `build/testflight/`.

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

# Build for the iOS Simulator (same scheme — one multi-platform target)
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project Lucent/Lucent.xcodeproj -scheme Lucent \
  -destination "platform=iOS Simulator,name=iPhone 16 Pro,OS=latest" build

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
                                ──owns──▶ FavoritesCloudSync   (iCloud key-value store)
                                ──owns──▶ PlayerCoordinator    (VLCKit, app-target only)
                                ──owns──▶ SleepTimer           (countdown + "still watching?" warning)
                                ──owns──▶ AudioLatencyMonitor  (route latency → VLC audio delay)
                                ──owns──▶ LocationService      (CoreLocation → postalCode)
                                ──owns──▶ EPGStore             (GRDB actor, Documents/epg.sqlite)
                                ──owns──▶ EPGService           (XMLTV path)
                                ──owns──▶ GracenoteIngestService (Gracenote path)
                                ──owns──▶ HDHRDiscovery        (LAN /24 scan)
```

`bootstrap()` in `AppModel`: if no HDHR IP saved, scan the local /24; if exactly one device responds, claim it. Then call `discover.json` + `lineup.json` on the HDHR, build `[Channel]` with overrides applied, and kick off a background guide refresh.

### Two guide sources, one store

`SettingsStore.guideSource` switches between `.gracenote` and `.xmltvURL`:

- **Gracenote**: `GracenoteIngestService` hits `tvlistings.gracenote.com/api/grid` in 6-hour chunks (the endpoint's `timespan` cap), maps each chunk to an `XMLTVEvent` stream, and feeds it through `EPGStore.ingest`. It also fetches one **lookback** chunk before the anchor (so in-progress programs aren't missing), ordered first so a mid-refresh network drop still leaves "now" covered.
- **XMLTV**: `EPGService.refresh(from:)` does `URLSession.download` to a temp file, then `XMLTVParser.parse(contentsOf:)` SAX-streams it through the same ingest path. Always download to disk first — never load XMLTV into memory.

Both paths converge on `EPGStore.ingest(AsyncThrowingStream<XMLTVEvent>)`, which writes in **500-row transactions** so a 100k-program ingest doesn't hold one giant write lock. Purge policies differ per path: Gracenote keeps `historyDays` (7 days) of history; XMLTV purges programs that ended more than 6 hours ago.

### Demo mode (App Store review)

Typing `demo` into the device-address field in Settings (`SettingsStore.hdhrIP`)
switches the app onto `TVCore/Demo/DemoContent.swift`: a fictional 14-station
lineup plus a generated week of listings, ingested through the same
`EPGStore.ingest` path as Gracenote and XMLTV. `AppModel.bootstrap()` short-
circuits before the LAN scan, `refreshGuide()` re-seeds instead of fetching, and
`PlayerCoordinator.isDemoMode` stops any `VLCMediaPlayer` from being built — the
UI renders `DemoVideoView` (a synthetic station ident) via `LiveVideoLayer`
wherever video would go. Nothing touches the network.

Demo rows are keyed `demo.<guideNumber>`, so they can't collide with real cache
rows; `SettingsStore.demoListingsPresent` remembers they're there and the next
non-demo `bootstrap()` purges them via
`EPGStore.deletePrograms(channelXmltvIDPrefix:)`. Keep everything in
`DemoContent` fictional — no real call signs, network names or show titles.

### The xmltvID join key (this is the subtle part)

`Program` rows are keyed by `channelXmltvID`. The right key for a `Channel` depends on the active guide source — see `AppModel.resolvedXmltvID`:

| Source | Default key | Why |
|---|---|---|
| `.gracenote` | `Channel.guideNumber` (e.g. `"8.1"`) | Matches Gracenote's `channelNo`, including subchannels |
| `.xmltvURL` | `Channel.guideName` | XMLTV files vary; this is a reasonable default |

Per-channel overrides live in `SettingsStore.xmltvOverrides`. **When you change `guideSource` or edit overrides, you must call `AppModel.rebuildChannelMapping()`** — `refreshGuide()` already does this. If listings stop showing up after a source switch, the join key is the first place to look; `AppModel.dumpStoreStats()` prints which xmltvIDs are stored vs. queried.

### Instant channel switching

`PlayerCoordinator` keeps a small pool of **prewarmed** `VLCMediaPlayer`s for the channels above and below the active one. On `tune(to:)` it swaps a prewarmed player into `activePlayer` instead of constructing one — that's what makes up/down feel instant. Budget: `min(prewarmCount, availableTuners - 1)` (one tuner is always reserved for the active stream; HDHR4-2US has 2 tuners, so default is 1 prewarm).

VLC live-stream tuning options (set on each `VLCMedia` in `makePlayer`): `network-caching=3000`, `live-caching=3000`, `audio-desync=0`. 3000 ms is deliberate — 1500 ms wasn't enough on iOS over WiFi (sparse MPEG-2 GOPs from HDHR produced "Invalid frame dimensions 0x0" spam); don't lower it without testing on WiFi. Clock synchro stays at VLC's default (enabled): `clock-jitter=0`/`clock-synchro=0` were tried for faster lock-on but froze in a constant lip-sync error, since clock synchro is what re-aligns A/V against the broadcast PCR clock per device.

A/V sync is handled at runtime, not via `audio-desync`: `AudioLatencyMonitor` tracks the audio output route's latency and pushes a signed microsecond delay to every player (active + prewarmed) through `PlayerCoordinator.applyAudioDelayToAllPlayers`, which sets `currentAudioPlaybackDelay`. On iOS, `AudioSessionConfigurator.activate()` must run before VLC's first `play()` or VLC settles on `.soloAmbient` and audio dies in the background.

`VLCMediaPlayer` is **not Sendable** and must be used on the main thread. The project-wide `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` makes this automatic for `PlayerCoordinator`.

**Drawable invariant**: libVLC's iOS/tvOS vout binds to `player.drawable` when the video output is created and never re-reads it — reassigning `drawable` on a playing player leaves video rendering in the old view (audio plays, screen black). All players render into the single persistent `PlayerCoordinator.drawableHost` UIView (bound before `play()`), and `VLCPlayerView` moves video between screens (hero preview ⇄ fullscreen) by reparenting that host view. Never set `drawable` on a live player.

### Search, rails, reminders, docked player

- **Search tab** (`Views/SearchView.swift`) runs `EPGStore.search` over an FTS5 external-content table (`program_fts`, migration `v4_program_fts`, kept in sync by triggers). User input is sanitised into `"term"*` prefix tokens, so odd input never throws.
- **On Now / Up Next rails** on `ChannelGridView` use `nowPlayingBatch` + `upNextBatch` for favorites (first 12 visible channels if none are starred).
- **Guide chrome**: `GuideJumpTarget` chips (Now / Tonight / Tomorrow / Weekend) and a `GuideGenreFilter` menu that runs one `programs(inCategoryContaining:)` query per window and filters rows. on tvOS `onMoveCommand` fires *in addition to* the focus engine's own move, so `moveFocusHorizontally` acts only at the window edges (clipped cell or off-screen neighbour) and lets the engine handle in-row moves — doing both double-steps; every row always has a focusable cell (`GuideEmptyRowCell`) so vertical focus never gets stuck.
- **Reminders** (`Reminders/ReminderService.swift`) — **parked behind `FeatureFlags.reminders = false`** (`FeatureFlags.swift`); the code stays, the UI, banner, notification delegate and ticker are all gated. Persisted in UserDefaults, 5-minute lead. In-app banner (`ReminderBanner`, mounted in `RootView`) on both platforms; iOS also schedules `UNCalendarNotificationTrigger`s and `AppDelegate` routes taps to `AppModel.watch(channelID:)`. `lucent://tune/<channelID>` and `lucent://tune?number=8.1` deep links do the same.
- **Now Playing chips**: captions / audio-track pickers (`PlayerCoordinator.refreshTracks`, libVLC track indexes, `-1` = off), signal meter (`HDHRClient.tunerStatus` → `/status.json`, polled every 2 s while the overlay is up), direct channel entry (`ChannelNumberPad`, also fed by hardware-keyboard digits), and a last-channel toggle (Play/Pause on tvOS, recents kept in `SettingsStore.recentChannelIDs`).
- **iPad docked player**: `LayoutMetrics.supportsDockedPlayer` + `SettingsStore.dockedPlayerEnabled` make tunes land in `DockedPlayerPane` (a sibling column in `RootView`) instead of fullscreen. `AppModel.isFullscreenPresented` / `dockedPlayerVisible` guarantee only one `VLCPlayerView` is mounted at a time (drawable invariant). The guide hero hides its live preview while the dock is visible.
- `Program` carries `year` and `credits` (migration `v3_program_metadata`); XMLTV `<credits>`/`<date>` and Gracenote `releaseYear` feed them. `ProgramDetailView` shows them plus "Also airing" via `EPGStore.airings(ofTitle:)`.

### Backgrounding

`RootView` forwards `scenePhase` to `AppModel.sceneDidEnterBackground` / `sceneDidBecomeActive`. tvOS tears the player down immediately (no PiP exists, so audio under the home screen is a bug); iOS waits 1.5 s and tears down only if system PiP didn't take the stream. The stopped channel is remembered and re-tuned on return **only** if a player surface (fullscreen, dock, pending presentation) is still up.

### Picture in Picture (iOS / iPadOS only)

`SettingsStore.pipEnabled` (default on) sets `PlayerCoordinator.usesMemoryOutput`. When on, `tune` does **not** set `drawable`; instead `onActivePlayerWillChange` fires before `play()` and `PIPController.attachVLCSource` installs libVLC memory callbacks (`Player/VLCVideoMemoryBridge.{h,m}`, imported via the bridging header; libVLC C symbols are forward-declared because the headers are excluded from MobileVLCKit's modulemap). `PIPFrameSource` asks VLC for NV12, copies each frame into a pooled `CVPixelBuffer`, wraps it as a `CMSampleBuffer` and enqueues it into every registered `AVSampleBufferDisplayLayer` — `VLCPlayerView` mounts a `SampleBufferDisplayView` per screen (fullscreen, hero tile, iPad dock), so several can show the same stream. The most recently mounted layer is bound to `AVPictureInPictureController`; `canStartPictureInPictureAutomaticallyFromInline` starts PiP on backgrounding. `Info.plist` carries `UIBackgroundModes = audio` (App Store Connect rejects a `picture-in-picture` entry; PiP needs only audio). With PiP off, or on tvOS, the drawable-host path above is used unchanged. Toggling the setting retunes the active channel so the path switches immediately. The Swift 6.2.3 frontend crashes on the `async` form of `pictureInPictureController(_:skipByInterval:)`; keep the completion-handler form.

### Adaptive layout (iOS/iPadOS vs tvOS)

`LayoutMetrics` (`Views/LayoutMetrics.swift`) holds per-platform/size-class layout constants, resolved once in `RootView` and injected via `@Environment(\.layoutMetrics)` — views read metrics from the environment instead of querying `horizontalSizeClass` themselves. tvOS short-circuits to a fixed 1920×1080 profile. The grid guide is the default on every platform: iPhone uses `guideVisibleSlots = 3` (5 in landscape), `typeScale = 0.62` applied to every fixed point size in `GuideView`, and `compactGuide` (drops the hero art tile, scrolls the chip row). `TimelineGuideView` is an opt-in via `SettingsStore.preferTimelineGuide`, applied in `RootView.resolvedMetrics`.

## Bundle / project conventions

- App target name is **Lucent** (earlier spec drafts called it "HDHRTV" — ignore those).
- Bundle ID `CalvinBrown.Lucent`.
- `Lucent.entitlements` contains only the iCloud key-value store entitlement (`com.apple.developer.ubiquity-kvstore-identifier`), used by `FavoritesCloudSync` to sync favorites across devices. App Group entitlement removed for v1 (was `group.dev.lucent.shared`, reserved for a future Top Shelf extension).
- Deployment targets: tvOS 26.2, iOS 26.0.

## Logging conventions

Diagnostic prints in TVCore and AppModel are tagged `[Lucent][<subsystem>]` (e.g. `[Lucent][Gracenote]`, `[Lucent][AppModel]`). Match this prefix when adding new diagnostics so they grep cleanly.
