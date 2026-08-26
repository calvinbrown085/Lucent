import AVFoundation
import Foundation
import UIKit

/// Tracks the current audio output route's latency and computes a libVLC
/// audio delay that keeps audio aligned with VLC's video pipeline. VLC's
/// `currentAudioPlaybackDelay` shifts audio playout by a signed number of
/// microseconds — positive delays audio, negative advances it. Audio output
/// latency (CoreAudio buffer + DAC + transducer) typically exceeds VLC's
/// drawable-pipeline latency, so the computed delay is usually negative.
///
/// Polarity: `D = videoPipelineLatency − audioOutputLatency`. Apply with
/// `player.currentAudioPlaybackDelay = D`.
final class AudioLatencyMonitor {
    /// Constant offset for residual VLC video-pipeline lag. Positive values
    /// shift the target toward "delay audio more"; tune empirically per
    /// platform if route compensation alone leaves a systematic offset.
    var videoPipelineLatencyMicros: Int = 0

    /// User-tunable A/V sync trim from Settings (microseconds, positive delays
    /// audio). Folded into every recompute on top of the route compensation —
    /// this is the knob for "voices arrive before lips move".
    var userOffsetMicros: Int = 0

    /// Clamp on what we'll send to VLC. AirPlay / Bluetooth can report
    /// 1–2 seconds of output latency; passing that verbatim degrades audio
    /// quality more than the residual sync error it would correct. Wide
    /// enough that a full ±500 ms user trim survives on top of the route
    /// compensation.
    let maxAbsDelayMicros: Int = 1_000_000

    private(set) var currentAudioDelayMicros: Int = 0

    var onChange: ((Int) -> Void)?

    func start() {
        recompute(reason: "start")

        // AppModel owns this for the app's lifetime; no teardown path is
        // needed. The closures capture `[weak self]`, so a later release
        // would just no-op.
        let center = NotificationCenter.default
        center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.recompute(reason: "routeChange")
            }
        }
        center.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.recompute(reason: "foreground")
            }
        }
    }

    func recompute(reason: String) {
        let outputLatencyMicros = Int(AVAudioSession.sharedInstance().outputLatency * 1_000_000)
        let raw = videoPipelineLatencyMicros + userOffsetMicros - outputLatencyMicros
        let clamped = max(-maxAbsDelayMicros, min(maxAbsDelayMicros, raw))
        guard clamped != currentAudioDelayMicros else { return }
        currentAudioDelayMicros = clamped
        print("[Lucent][AudioSync] reason=\(reason) outputLatencyUs=\(outputLatencyMicros) delayUs=\(clamped)")
        onChange?(clamped)
    }
}
