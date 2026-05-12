import Foundation
import Observation
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

    /// User preference, 0–2. Capped further by the available HDHR tuner count.
    var prewarmCount: Int = 1
    /// Set this from the discovered HDHR `TunerCount`. Default 2 (HDHR4-2US).
    var availableTuners: Int = 2

    private var prewarmed: [Channel.ID: VLCMediaPlayer] = [:]

    /// Current audio delay (microseconds, signed) to apply to every player.
    /// Driven by `AudioLatencyMonitor` via `applyAudioDelayToAllPlayers(_:)`.
    private var currentAudioDelayMicros: Int = 0

    init() {}

    /// Switch active playback to `channel`. Reuses a prewarmed player if one exists.
    func tune(to channel: Channel) {
        // Fully stop (not pause) the prior player so HDHR releases its tuner.
        // Pause keeps the HTTP socket open and the tuner reserved; on a 2-tuner
        // device, two sequential channel switches would otherwise exhaust the
        // tuner budget before the new stream can acquire one, producing the
        // mpeg2video "Invalid frame dimensions 0x0" spam with no picture.
        if let prior = activeChannel, let priorPlayer = activePlayer, prior.id != channel.id {
            priorPlayer.stop()
            priorPlayer.media = nil
        }

        let player: VLCMediaPlayer
        if let existing = prewarmed.removeValue(forKey: channel.id) {
            player = existing
        } else {
            player = makePlayer(for: channel)
        }

        player.audio?.isMuted = false
        player.play()
        activePlayer = player
        activeChannel = channel
        applyAudioDelay(to: player)
    }

    /// Refresh the prewarmed pool for a list of neighbor channels (typically the
    /// channel above and below the active one in the lineup). Honors `prewarmCount`
    /// and the available tuner budget — one tuner is always reserved for the
    /// active stream.
    func updatePrewarm(neighbors: [Channel]) {
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
        // VLC's decode/display pipeline lags its audio output by a fixed
        // amount; positive value delays audio (ms) to realign with picture.
        let options: [String: NSNumber] = [
            "network-caching": NSNumber(value: 3000),
            "live-caching": NSNumber(value: 3000),
            "clock-jitter": NSNumber(value: 0),
            "clock-synchro": NSNumber(value: 0),
            "audio-desync": NSNumber(value: 0),
        ]
        media.addOptions(options)
        let player = VLCMediaPlayer()
        player.media = media
        return player
    }
}
