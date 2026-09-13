#if !os(tvOS)
import AVKit
import CoreMedia
import MobileVLCKit
import Observation
import UIKit

/// Owns the system Picture-in-Picture pipeline on iOS / iPadOS.
///
/// HDHR streams are MPEG-TS decoded only by VLC, so there is no
/// `AVPlayerLayer` to hand AVKit. Instead VLC decodes into pixel buffers via
/// `PIPFrameSource`, which feeds an `AVSampleBufferDisplayLayer`; AVKit
/// migrates that layer into its floating window when PiP starts, and the
/// frame source keeps pumping in the background because it never touches
/// the GPU display path.
@Observable
@MainActor
final class PIPController: NSObject {
    /// Whether the system PiP window is currently visible.
    private(set) var isActive = false
    /// Mirrors `AVPictureInPictureController.isPictureInPicturePossible`.
    private(set) var isPossible = false
    /// Static device capability.
    let isSupported = AVPictureInPictureController.isPictureInPictureSupported()

    /// Set by the views that host video so the controller knows whether
    /// anything in-app still needs the player once PiP stops.
    var inAppVideoMounted = false
    /// Lets AppModel run player teardown without a strong reference.
    var onShouldTearDownPlayer: (() -> Void)?
    /// Called when the user taps "return to app" on the PiP window; the app
    /// should make sure the fullscreen player is on screen.
    var onRestoreUserInterface: (() -> Void)?

    /// Set by AVKit's restore callback, which precedes `didStop` only when
    /// the user chose to come back to the app. A `didStop` without it means
    /// the PiP window was closed with its X — the user wants playback to
    /// end, audio included.
    private var restoreRequested = false

    /// Single frame source shared by every in-app display layer and PiP.
    let frameSource = PIPFrameSource()

    private var pipController: AVPictureInPictureController?
    private var possibilityKVO: NSKeyValueObservation?
    private weak var boundLayer: AVSampleBufferDisplayLayer?

    /// Wire AVKit to a display layer that is in a window. Calls with the
    /// layer already bound are no-ops; a different layer replaces the
    /// controller (e.g. fullscreen view replaced the hero tile).
    func bind(sampleBufferLayer: AVSampleBufferDisplayLayer) {
        if boundLayer === sampleBufferLayer, pipController != nil { return }
        // Don't steal the source out from under a live PiP session.
        if isActive { return }
        boundLayer = sampleBufferLayer

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
        // Backgrounding the app while video is on screen starts PiP without
        // a tap, the way the TV app behaves.
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        pipController = controller

        possibilityKVO = controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] ctrl, _ in
            let possible = ctrl.isPictureInPicturePossible
            Task { @MainActor in self?.isPossible = possible }
        }
    }

    /// Attach `player` as the source whose decoded frames feed the layers.
    /// Must run before the player's first `play()`.
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
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ c: AVPictureInPictureController) {
        Task { @MainActor in self.isActive = true }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ c: AVPictureInPictureController) {
        Task { @MainActor in
            self.isActive = false
            let returningToApp = self.restoreRequested
            self.restoreRequested = false
            if !returningToApp {
                // Closed with the X: stop the stream outright. Previously
                // this only tore down when nothing in-app was mounted, so
                // backgrounding the app, then closing PiP, left audio
                // running with no picture anywhere.
                self.onShouldTearDownPlayer?()
            } else if !self.inAppVideoMounted {
                self.onRestoreUserInterface?()
            }
        }
    }

    nonisolated func pictureInPictureController(
        _ c: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        // The main-actor hop is enqueued before AVKit's subsequent didStop
        // hop, so the flag is set by the time didStop reads it. Completing
        // synchronously avoids sending the non-Sendable handler across actors.
        Task { @MainActor in
            self.restoreRequested = true
            if !self.inAppVideoMounted { self.onRestoreUserInterface?() }
        }
        completionHandler(true)
    }

    nonisolated func pictureInPictureController(
        _ c: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        Task { @MainActor in
            self.isActive = false
            print("[Lucent][PIP] failed to start: \(error)")
        }
    }
}

extension PIPController: AVPictureInPictureSampleBufferPlaybackDelegate {
    nonisolated func pictureInPictureController(_ c: AVPictureInPictureController, setPlaying playing: Bool) {
        // Live stream — no pause. Intentionally a no-op.
    }

    nonisolated func pictureInPictureControllerTimeRangeForPlayback(_ c: AVPictureInPictureController) -> CMTimeRange {
        // Infinite range = live: AVKit hides the scrubber and skip buttons.
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    nonisolated func pictureInPictureControllerIsPlaybackPaused(_ c: AVPictureInPictureController) -> Bool {
        false
    }

    nonisolated func pictureInPictureController(
        _ c: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {}

    // Completion-handler form rather than the async one: the Swift 6.2.3
    // frontend crashes emitting the ObjC thunk for the async variant.
    nonisolated func pictureInPictureController(
        _ c: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion completionHandler: @escaping @Sendable () -> Void
    ) {
        // Live — nothing to skip within.
        completionHandler()
    }
}
#endif
