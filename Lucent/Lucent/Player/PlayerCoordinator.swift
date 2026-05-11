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

    init() {}

    /// Switch active playback to `channel`. Reuses a prewarmed player if one exists.
    func tune(to channel: Channel) {
        if let prior = activeChannel, let priorPlayer = activePlayer, prior.id != channel.id {
            priorPlayer.pause()
            priorPlayer.audio?.isMuted = true
            prewarmed[prior.id] = priorPlayer
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
        }
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
        // Live stream tuning: short network buffer keeps latency tolerable.
        var options: [String: NSNumber] = [
            "network-caching": NSNumber(value: 500),
            "live-caching": NSNumber(value: 500),
            "clock-jitter": NSNumber(value: 0),
            "clock-synchro": NSNumber(value: 0),
        ]
        #if os(tvOS)
        // VLC's tvOS decode/display pipeline lags its audio output by a fixed
        // amount; positive value delays audio (ms) to realign with picture.
        options["audio-desync"] = NSNumber(value: 120)
        #endif
        media.addOptions(options)
        let player = VLCMediaPlayer()
        player.media = media
        return player
    }
}
