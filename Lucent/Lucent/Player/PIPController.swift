#if !os(tvOS)
import AVKit
import CoreMedia
import MobileVLCKit
import Observation
import UIKit

/// Owns the system Picture-in-Picture pipeline. PIP shows the same
/// `AVSampleBufferDisplayLayer` that backs the in-app `VLCPlayerView` — when
/// PIP starts, the system migrates that layer into its floating window.
/// Decoded VLC frames flow into the layer via `PIPFrameSource` (libVLC
/// memory callbacks), so the pipeline does not depend on the app's GPU
/// pipeline being awake — it keeps producing frames in background.
///
/// Why sample-buffer PIP at all: HDHR streams are MPEG-TS, decoded only by
/// VLC; AVPlayer can't play them, so there's no native `AVPlayerLayer` PIP.
@Observable
@MainActor
final class PIPController: NSObject {
    /// Whether the system PIP window is currently visible.
    private(set) var isActive: Bool = false
    /// Mirrors `AVPictureInPictureController.isPictureInPicturePossible`.
    /// Drives whether the chip in NowPlayingView is visible.
    private(set) var isPossible: Bool = false
    /// Static device capability — false on platforms/builds without PIP.
    let isSupported: Bool = AVPictureInPictureController.isPictureInPictureSupported()

    /// Set by NowPlayingView so the controller can decide whether to tear the
    /// VLC player down once PIP stops.
    var nowPlayingMounted: Bool = false
    /// Closure the controller calls to let AppModel run player teardown
    /// without taking a strong reference to AppModel.
    var onShouldTearDownPlayer: (() -> Void)?

    /// Single frame source shared by in-app display and PIP. `VLCPlayerView`
    /// registers its sample-buffer layer here; `attachVLCSource(_:)` rewires
    /// it to whichever VLCMediaPlayer is currently active.
    let frameSource = PIPFrameSource()

    private var pipController: AVPictureInPictureController?
    private var possibilityKVO: NSKeyValueObservation?
    private weak var boundLayer: AVSampleBufferDisplayLayer?

    /// Wire AVPiP to the in-app player view's sample-buffer layer. Called
    /// from `VLCPlayerView.makeUIView` on the next runloop tick (so the view
    /// is in a window). Subsequent calls with the same layer are no-ops;
    /// calls with a different layer replace the controller.
    func bind(sampleBufferLayer: AVSampleBufferDisplayLayer) {
        if boundLayer === sampleBufferLayer, pipController != nil { return }
        boundLayer = sampleBufferLayer

        // Replace any previous controller; ContentSource holds a strong ref
        // to the layer and we don't want stale references.
        possibilityKVO?.invalidate()
        possibilityKVO = nil
        pipController = nil

        guard isSupported else { return }
        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: sampleBufferLayer,
            playbackDelegate: self
        )
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        // When the app backgrounds and the source layer has frames in flight,
        // the system auto-starts PIP. Our frame source pumps continuously
        // while a VLC player is attached, so this kicks in naturally.
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        self.pipController = controller

        possibilityKVO = controller.observe(
            \.isPictureInPicturePossible,
            options: [.initial, .new]
        ) { [weak self] ctrl, _ in
            let possible = ctrl.isPictureInPicturePossible
            Task { @MainActor in self?.isPossible = possible }
        }
    }

    /// Attach `player` as the source whose decoded frames feed the layer.
    /// Pass `nil` to detach (e.g. after tearDown).
    func attachVLCSource(_ player: VLCMediaPlayer?) {
        frameSource.attach(to: player)
    }

    func toggle() { isActive ? stop() : start() }

    func start() {
        guard isSupported, let pip = pipController else { return }
        pip.startPictureInPicture()
    }

    func stop() {
        pipController?.stopPictureInPicture()
    }
}

extension PIPController: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        Task { @MainActor in self.isActive = true }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        Task { @MainActor in
            self.isActive = false
            // If the user closed NowPlayingView while PIP was up, tear the
            // VLC player down now that PIP is gone too.
            if !self.nowPlayingMounted {
                self.onShouldTearDownPlayer?()
            }
        }
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        Task { @MainActor in
            self.isActive = false
            print("[Lucent][PIP] failed to start: \(error)")
        }
    }
}

extension PIPController: AVPictureInPictureSampleBufferPlaybackDelegate {
    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        setPlaying playing: Bool
    ) {
        // HDHR is live — no pause. Intentionally a no-op.
    }

    nonisolated func pictureInPictureControllerTimeRangeForPlayback(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> CMTimeRange {
        // Infinite range tells the system this is a live stream and to hide
        // the scrubber + skip buttons.
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    nonisolated func pictureInPictureControllerIsPlaybackPaused(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> Bool {
        false
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {
        // We don't currently downscale the libVLC output to PIP render size;
        // the sample-buffer layer scales for us.
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion completionHandler: @escaping @Sendable () -> Void
    ) {
        // Live: no skip. Call completion immediately so the system doesn't wait.
        completionHandler()
    }
}
#endif
