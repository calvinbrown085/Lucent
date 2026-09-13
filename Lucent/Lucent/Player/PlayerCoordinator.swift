import Foundation
import Observation
import UIKit
#if canImport(TVVLCKit)
import TVVLCKit
#elseif canImport(MobileVLCKit)
import MobileVLCKit
#endif
import TVCore

/// Owns the active `VLCMediaPlayer` and a small pool of prewarmed players
/// for adjacent channels. Swapping to a prewarmed player on channel change
/// is what makes up/down feel instant.
///
/// VLC is required because HDHomeRun's `/auto/v<channel>` endpoint serves raw
/// MPEG-TS over HTTP, which AVPlayer cannot play.
@Observable
final class PlayerCoordinator {
    private(set) var activeChannel: Channel?
    private(set) var activePlayer: VLCMediaPlayer?

    /// The one UIView libVLC ever renders into. VLC's iOS/tvOS video output
    /// binds to the drawable when the vout is created and never re-reads it,
    /// so reassigning `drawable` on a playing player leaves video rendering
    /// in the old, possibly detached view (audio keeps going, screen is
    /// black). Moving video between screens (hero preview ⇄ fullscreen) is
    /// therefore done by reparenting this host view — `VLCPlayerView` handles
    /// that — never by touching `drawable` on a live player.
    let drawableHost = UIView()

    /// User preference, 0–2. Capped further by the available HDHR tuner count.
    var prewarmCount: Int = 1
    /// Set this from the discovered HDHR `TunerCount`. Default 2 (HDHR4-2US).
    var availableTuners: Int = 2

    /// Demo mode: there is no tuner and no stream, so no `VLCMediaPlayer` is
    /// ever built. `tune(to:)` still records the active channel — that's what
    /// the guide, mini-guide and Now Playing chrome read — and the UI renders
    /// `DemoVideoView` in place of `VLCPlayerView`. Kept as a stored flag
    /// rather than inspecting settings so the coordinator stays free of
    /// dependencies on `AppModel`; `AppModel` sets it on bootstrap and on
    /// every `tune`.
    var isDemoMode = false

    /// iOS / iPadOS only: render through libVLC memory callbacks into
    /// `AVSampleBufferDisplayLayer`s instead of the GPU drawable. This is what
    /// makes system Picture in Picture possible (see `PIPController`). The
    /// flag is read at `tune` time: `onActivePlayerWillChange` installs the
    /// callbacks before `play()`, and `drawable` is left unset.
    var usesMemoryOutput = false

    /// libVLC deinterlace filter name applied to every new player; nil = off.
    /// Read at `makePlayer` time, so changing it takes effect on next tune.
    var deinterlaceFilter: String? = DeinterlaceMode.platformDefault.vlcFilterName

    /// Fires inside `tune(to:)` *before* `player.play()` so observers can
    /// install per-player resources (libVLC requires video callbacks be set
    /// before playback begins). `nil` means there is no active player.
    var onActivePlayerWillChange: ((VLCMediaPlayer?) -> Void)?

    private var prewarmed: [Channel.ID: VLCMediaPlayer] = [:]

    /// A selectable audio or subtitle track on the active stream. `id` is
    /// libVLC's track index; `-1` is the "off" entry libVLC lists for subtitles.
    struct MediaTrack: Identifiable, Hashable {
        let id: Int
        let name: String
    }

    /// Track lists for the active player. libVLC only knows about a stream's
    /// tracks once the demuxer has run, so these are empty at `tune` time and
    /// filled in by `refreshTracks()`, which the Now Playing chrome calls when
    /// it opens the picker. Broadcast MPEG-TS carries CEA-608/708 captions
    /// and SAP audio here.
    private(set) var subtitleTracks: [MediaTrack] = []
    private(set) var audioTracks: [MediaTrack] = []
    private(set) var currentSubtitleTrackID: Int = -1
    private(set) var currentAudioTrackID: Int = -1

    /// Caption preference: `nil` means off; otherwise "keep captions on",
    /// re-applied after every channel change by picking the first real
    /// subtitle track on the new stream.
    var captionsPreferred = false

    /// Current audio delay (microseconds, signed) to apply to every player.
    /// Driven by `AudioLatencyMonitor` via `applyAudioDelayToAllPlayers(_:)`.
    private var currentAudioDelayMicros: Int = 0

    init() {}

    /// Switch active playback to `channel`. Reuses a prewarmed player if one exists.
    func tune(to channel: Channel) {
        // Re-selecting the channel that's already playing is a no-op — falling
        // through would build a fresh player and re-buffer the live stream from
        // scratch (~3s of black). A stopped/ended/errored player falls through
        // so re-tuning still works as a retry.
        if let prior = activeChannel, prior.id == channel.id,
           let priorPlayer = activePlayer,
           priorPlayer.state != .stopped, priorPlayer.state != .ended, priorPlayer.state != .error {
            return
        }

        // Fully stop (not pause) the prior player so HDHR releases its tuner.
        // Pause keeps the HTTP socket open and the tuner reserved; on a 2-tuner
        // device, two sequential channel switches would otherwise exhaust the
        // tuner budget before the new stream can acquire one, producing the
        // mpeg2video "Invalid frame dimensions 0x0" spam with no picture.
        if let prior = activeChannel, let priorPlayer = activePlayer, prior.id != channel.id {
            priorPlayer.stop()
            priorPlayer.media = nil
        }

        // Demo mode stops here: record the channel so the chrome updates, but
        // never point VLC at the placeholder demo:// URL.
        if isDemoMode {
            if activeChannel?.id == channel.id { return }
            activePlayer?.stop()
            activePlayer?.media = nil
            activePlayer = nil
            activeChannel = channel
            return
        }

        let player: VLCMediaPlayer
        if let existing = prewarmed.removeValue(forKey: channel.id) {
            player = existing
        } else {
            player = makePlayer(for: channel)
        }

        if usesMemoryOutput {
            onActivePlayerWillChange?(player)
        } else {
            // Bind the drawable before play() so the vout is created against
            // the persistent host view. Safe on prewarmed players too — they
            // never played, so no vout exists yet.
            player.drawable = drawableHost
        }
        player.audio?.isMuted = false
        player.play()
        activePlayer = player
        activeChannel = channel
        applyAudioDelay(to: player)
        subtitleTracks = []
        audioTracks = []
        currentSubtitleTrackID = -1
        currentAudioTrackID = -1
        if captionsPreferred { scheduleCaptionReapply(for: player) }
    }

    // MARK: - Tracks

    /// Re-read the active player's audio and subtitle track lists.
    func refreshTracks() {
        guard let player = activePlayer else {
            subtitleTracks = []
            audioTracks = []
            return
        }
        subtitleTracks = Self.tracks(indexes: player.videoSubTitlesIndexes, names: player.videoSubTitlesNames)
        audioTracks = Self.tracks(indexes: player.audioTrackIndexes, names: player.audioTrackNames)
        currentSubtitleTrackID = Int(player.currentVideoSubTitleIndex)
        currentAudioTrackID = Int(player.currentAudioTrackIndex)
    }

    func selectSubtitleTrack(_ id: Int) {
        guard let player = activePlayer else { return }
        player.currentVideoSubTitleIndex = Int32(id)
        currentSubtitleTrackID = id
        captionsPreferred = id >= 0
    }

    func selectAudioTrack(_ id: Int) {
        guard let player = activePlayer else { return }
        player.currentAudioTrackIndex = Int32(id)
        currentAudioTrackID = id
    }

    /// Captions on/off toggle for the overlay chip: on picks the first real
    /// subtitle track, off selects libVLC's `-1` "Disable" entry.
    func toggleCaptions() {
        refreshTracks()
        if currentSubtitleTrackID >= 0 {
            selectSubtitleTrack(-1)
        } else if let first = subtitleTracks.first(where: { $0.id >= 0 }) {
            selectSubtitleTrack(first.id)
        } else {
            // No track yet (stream still buffering). Remember the intent so
            // it applies once the demuxer has found the caption track.
            captionsPreferred = true
            scheduleCaptionReapply(for: activePlayer)
        }
    }

    var captionsOn: Bool { currentSubtitleTrackID >= 0 }

    private var captionReapplyTask: Task<Void, Never>?

    /// Subtitle tracks appear a few seconds into playback. Poll briefly after
    /// a tune (or a toggle on a still-buffering stream) and enable the first
    /// one found. Bounded so it can't spin forever on a stream with none.
    private func scheduleCaptionReapply(for player: VLCMediaPlayer?) {
        captionReapplyTask?.cancel()
        guard let player else { return }
        captionReapplyTask = Task { @MainActor [weak self] in
            for _ in 0..<12 {
                try? await Task.sleep(for: .milliseconds(750))
                guard let self, !Task.isCancelled, self.activePlayer === player, self.captionsPreferred else { return }
                self.refreshTracks()
                if let first = self.subtitleTracks.first(where: { $0.id >= 0 }) {
                    if self.currentSubtitleTrackID < 0 {
                        player.currentVideoSubTitleIndex = Int32(first.id)
                        self.currentSubtitleTrackID = first.id
                    }
                    return
                }
            }
        }
    }

    private static func tracks(indexes: [Any]?, names: [Any]?) -> [MediaTrack] {
        guard let indexes, let names, indexes.count == names.count else { return [] }
        return zip(indexes, names).compactMap { pair in
            guard let idx = (pair.0 as? NSNumber)?.intValue else { return nil }
            let name = (pair.1 as? String) ?? "Track \(idx)"
            return MediaTrack(id: idx, name: name)
        }
    }

    /// Refresh the prewarmed pool for a list of neighbor channels (typically the
    /// channel above and below the active one in the lineup). Honors `prewarmCount`
    /// and the available tuner budget — one tuner is always reserved for the
    /// active stream.
    func updatePrewarm(neighbors: [Channel]) {
        guard !isDemoMode else { return }
        let budget = max(0, min(prewarmCount, availableTuners - 1))
        let target = Array(neighbors.prefix(budget))
        let targetIDs = Set(target.map(\.id))

        for (id, player) in prewarmed where !targetIDs.contains(id) {
            player.stop()
            player.media = nil
            prewarmed.removeValue(forKey: id)
        }

        for channel in target where prewarmed[channel.id] == nil {
            let player = makePlayer(for: channel)
            player.audio?.isMuted = true
            // Begin buffering without rendering: setting media starts the HTTP
            // fetch + parse; `.play()` would also start decode and need a
            // drawable. We let the swap-in moment trigger play().
            prewarmed[channel.id] = player
            applyAudioDelay(to: player)
        }
    }

    /// Push a new audio delay (microseconds, signed) onto every player we own.
    /// Called by `AudioLatencyMonitor` whenever the active output route's
    /// latency changes. VLCKit accepts the value before the audio decoder is
    /// running, so this is safe on freshly-prewarmed players.
    func applyAudioDelayToAllPlayers(_ micros: Int) {
        currentAudioDelayMicros = micros
        if let active = activePlayer { applyAudioDelay(to: active) }
        for (_, p) in prewarmed { applyAudioDelay(to: p) }
    }

    private func applyAudioDelay(to player: VLCMediaPlayer) {
        player.currentAudioPlaybackDelay = currentAudioDelayMicros
    }

    func tearDown() {
        activePlayer?.stop()
        activePlayer?.media = nil
        activePlayer = nil
        activeChannel = nil
        onActivePlayerWillChange?(nil)
        captionReapplyTask?.cancel()
        subtitleTracks = []
        audioTracks = []
        for (_, p) in prewarmed {
            p.stop()
            p.media = nil
        }
        prewarmed.removeAll()
    }

    private func makePlayer(for channel: Channel) -> VLCMediaPlayer {
        let media = VLCMedia(url: channel.streamURL)
        // Live stream tuning. 1500ms was not enough on iOS over WiFi — sparse
        // MPEG-2 GOPs from HDHR plus packet jitter still produced "Invalid
        // frame dimensions 0x0" spam with no video. 3000ms gives the decoder
        // a full GOP of headroom before it tries to render.
        // Clock synchro is left at VLC's default (enabled): it continuously
        // re-aligns audio/video against the broadcast PCR clock, which is
        // what absorbs per-device A/V offset on a live stream. It was
        // previously disabled (clock-jitter=0, clock-synchro=0) for faster
        // lock-on, but that froze in a constant lip-sync error with nothing
        // to correct it. Restore those two options only if tuning lock-on
        // regresses badly — and expect to need the manual audio-sync trim.
        let options: [String: NSNumber] = [
            "network-caching": NSNumber(value: 3000),
            "live-caching": NSNumber(value: 3000),
            "audio-desync": NSNumber(value: 0),
        ]
        media.addOptions(options)
        let player = VLCMediaPlayer()
        player.media = media
        // Explicit rather than VLC's "auto": auto picks the "x" filter, which
        // profiles at ~40% of app CPU on 1080i. "linear" is a cheap
        // line-doubler that looks fine at phone/tablet sizes.
        var filter = deinterlaceFilter
        #if DEBUG
        // A/B hook for on-device profiling (LUCENT_DEINTERLACE=x|linear|off).
        if let override = ProcessInfo.processInfo.environment["LUCENT_DEINTERLACE"] {
            filter = override == "off" ? nil : override
        }
        #endif
        player.setDeinterlaceFilter(filter)
        return player
    }
}
