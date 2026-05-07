# Lucent

A native **tvOS 26** client for **HDHomeRun** tuners, with EPG data from **Gracenote** (default, postal-code-based) or a self-hosted **XMLTV** URL.

## Why this exists

Jellyfin's Live TV works, but on tvOS it's slow to render the guide grid, slow to switch channels, and predates Liquid Glass. Lucent's v1 goal is narrow and concrete: beat Jellyfin's Live TV experience on three things, on tvOS, today.

- **Instant guide grid.** EPG data is cached locally in SQLite (GRDB) and rendered straight from disk — no spinner, no network round-trip on tab switch.
- **Instant channel switching.** A small pool of prewarmed `VLCMediaPlayer` instances keeps the channels above and below the active one ready to go, so up/down on the remote feels immediate instead of waiting on a fresh tune.
- **Correct Liquid Glass.** Glass goes on the navigation layer only — tab bar, overlay chips, Settings sheet buttons. Never on content (channel cards, EPG cells, video). VLC draws into a `CAEAGLLayer`/`CAMetalLayer`; wrapping it in `UIVisualEffectView` produces black squares, which is why most third-party players currently look wrong.

## Status & scope

v1 is locked tight. tvOS-only, HDHR-only.

**Out of scope for v1:** DVR, recordings, series passes, remote streaming, auth, SSDP discovery beyond a LAN /24 scan, Picture-in-Picture, Top Shelf extension. These aren't being deferred to v1.1 — they're being deliberately left out so v1 can be excellent at the live-TV path.

## Requirements

- A tvOS **26.2** device or simulator
- Xcode with the tvOS 26 SDK
- An **HDHomeRun** tuner reachable on the local network (developed and tested against an HDHR4-2US, 2 tuners)
- One guide source:
  - A US/Canada **postal code** (Gracenote, default), **or**
  - A self-hosted **XMLTV** URL

## Quick start

```bash
git clone <this repo>
cd Lucent
scripts/fetch-tvvlckit.sh
open Lucent/Lucent.xcodeproj
```

`scripts/fetch-tvvlckit.sh` downloads **TVVLCKit 3.7.3** (~600 MB) from videolan.org and extracts it into `Frameworks/TVVLCKit.xcframework/`. The framework is gitignored because of its size — fetching it after clone is a one-time step. The Xcode project links it via `../Frameworks/TVVLCKit.xcframework` (Linked + Embed-Sign in the app target).

Build to a tvOS Simulator or a real Apple TV from Xcode as normal.

## First-run configuration

Open **Settings** in the app:

- **HDHR IP** — left blank, Lucent scans the local /24 on launch and claims the device if exactly one responds. If you have multiple tuners or auto-discovery doesn't find yours, enter the IP manually.
- **Guide source** — `Gracenote` (default) or `XMLTV URL`.
  - For Gracenote: enter your **postal code** (or grant location permission and Lucent will derive it). Country defaults to `USA`.
  - For XMLTV: enter the URL of your XMLTV feed.
- **Prewarm count** — how many channels to keep hot for instant switching. Default `1`. Capped at `availableTuners − 1` (one tuner is always reserved for the active stream), so an HDHR4-2US tops out at 1.
- **Optional** — per-channel `xmltvOverrides` (when the auto-derived xmltvID doesn't match your feed), `lineupIDOverride`, `hideChannelsWithoutGuide`, favorites.

If listings stop showing up after switching guide source, the join key between `Channel` and `Program` is the first place to look — see the [xmltvID join key](./CLAUDE.md#the-xmltvid-join-key-this-is-the-subtle-part) section in `CLAUDE.md`.

## How it works (brief)

- **Playback.** HDHR serves raw MPEG-TS over HTTP, which `AVPlayer` cannot play. Lucent uses **TVVLCKit** wrapped in a thin `VLCPlayerView` (a SwiftUI `UIViewRepresentable`) — see `Lucent/Lucent/Lucent/Player/`.
- **Two guide sources, one cache.** A Gracenote ingest service and an XMLTV parser both converge on `EPGStore.ingest(...)`, which writes in 500-row transactions into a single GRDB-backed SQLite file at `Documents/epg.sqlite`. See `TVCore/Sources/TVCore/EPG/`.
- **Prewarmed players.** `PlayerCoordinator` keeps a small pool of `VLCMediaPlayer` instances primed for the channels adjacent to the active one. `tune(to:)` swaps a prewarmed player into the active slot instead of constructing one — that's what makes up/down feel instant.
- **`@Observable` everywhere.** `AppModel` is the single `@Observable @MainActor` owner that views read from. It orchestrates TVCore actors and exposes plain values to SwiftUI. No `ObservableObject`, no Combine.

For architectural detail — data flow, `xmltvID` resolution, ingest transactions, the Liquid Glass rule — see [CLAUDE.md](./CLAUDE.md).

## Repo layout

```
Lucent/                   — repo root
├── Lucent/               — Xcode project + tvOS app target
├── TVCore/               — local SwiftPM package: HDHR client, EPG store, parsers
├── Frameworks/           — gitignored, holds TVVLCKit.xcframework
└── scripts/              — fetch-tvvlckit.sh, icon generator
```

`TVCore` is kept source-portable (no UIKit / AppKit / TVVLCKit imports) so a future iOS port can reuse it. Player code lives in the app target because TVVLCKit is platform-specific.

## Build, test, run (CLI)

> **Note.** On this machine, `xcode-select -p` returns `CommandLineTools`, which lacks the tvOS SDKs and `Testing`. Prepend `DEVELOPER_DIR` to every `xcodebuild` and `swift test` invocation. If your `xcode-select` already points at `Xcode.app`, you can drop the prefix.

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

## Privacy

Lucent asks for two permissions on first launch. The exact strings shown in the system dialogs:

- **Local network** — *"Lucent communicates with your HDHomeRun tuner on your local network to discover channels and stream live TV."*
- **Location (when in use)** — *"Lucent uses your location to load TV listings for your area."* Only used to derive a postal code for Gracenote; you can skip this and type the postal code manually.

No analytics. No telemetry. No remote servers operated by Lucent — guide data goes directly between your Apple TV and either Gracenote's public listings API or your XMLTV URL.

## Acknowledgments

- **[TVVLCKit](https://code.videolan.org/videolan/VLCKit)** — LGPL-2.1. Fetched at build time, not vendored.
- **[GRDB.swift](https://github.com/groue/GRDB.swift)** — MIT.

The in-app **Acknowledgments** screen (Settings → Acknowledgments) carries the full LGPL notice required by TVVLCKit's license.

## License

MIT — see [LICENSE](./LICENSE).
