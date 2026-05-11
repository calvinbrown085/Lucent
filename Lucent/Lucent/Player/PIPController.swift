#if !os(tvOS)
import AVKit
import CoreMedia
import Observation
import UIKit

/// Owns the system Picture-in-Picture pipeline. Mounts a hidden
/// `AVSampleBufferDisplayLayer` host view as a sibling of the live VLC
/// drawable, builds an `AVPictureInPictureController` from a sample-buffer
/// content source, and drives a `PIPFrameSource` that snapshots VLC's view
/// and pumps `CMSampleBuffer`s into the display layer while PIP is active.
///
/// Why sample-buffer PIP: HDHR streams are MPEG-TS and only VLC can decode
/// them — AVPlayer can't, so we don't get a free `AVPlayerLayer`.
@Observable
@MainActor
final class PIPController: NSObject {
    /// Whether the system PIP window is currently visible.
    private(set) var isActive: Bool = false
    /// Mirrors `AVPictureInPictureController.isPictureInPicturePossible`. Drives
    /// whether the chip in NowPlayingView is visible.
    private(set) var isPossible: Bool = false
    /// Static device capability — false on platforms / builds without PIP.
    let isSupported: Bool = AVPictureInPictureController.isPictureInPictureSupported()

    /// Set by NowPlayingView so the controller can decide whether to tear the
    /// VLC player down once PIP stops.
    var nowPlayingMounted: Bool = false
    /// Closure the controller calls to let AppModel run player teardown
    /// without taking a strong reference to AppModel.
    var onShouldTearDownPlayer: (() -> Void)?

    private let displayHostView = PIPHostView()
    private var pipController: AVPictureInPictureController?
    private let frameSource = PIPFrameSource()
    private weak var sourceView: UIView?
    private var possibilityKVO: NSKeyValueObservation?

    /// Called from `VLCPlayerView.makeUIView` once the drawable view is in a
    /// window hierarchy. Mounts the sample-buffer host as a sibling and lazily
    /// constructs the AVPictureInPictureController.
    func bind(sourceView: UIView) {
        self.sourceView = sourceView

        if displayHostView.superview == nil, let parent = sourceView.superview {
            // Mount BELOW the VLC view so we never cover it visually. Alpha
            // ~zero (still > 0) keeps the layer eligible for AVPiP attach.
            parent.insertSubview(displayHostView, belowSubview: sourceView)
            displayHostView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                displayHostView.leadingAnchor.constraint(equalTo: sourceView.leadingAnchor),
                displayHostView.trailingAnchor.constraint(equalTo: sourceView.trailingAnchor),
                displayHostView.topAnchor.constraint(equalTo: sourceView.topAnchor),
                displayHostView.bottomAnchor.constraint(equalTo: sourceView.bottomAnchor),
            ])
            displayHostView.alpha = 0.001
            displayHostView.isUserInteractionEnabled = false
        }

        attachControllerIfNeeded()
        // Prime the sample-buffer layer immediately so AVPiP can auto-start
        // from inline when the app backgrounds — the layer needs frames in
        // flight before the OS will hand it off to a floating PIP window.
        startFeeding()
    }

    func toggle() { isActive ? stop() : start() }

    func start() {
        guard isSupported, let pip = pipController else { return }
        // Ensure the layer is being fed before asking AVPiP to take over —
        // the controller refuses to start if the layer has no enqueued frames.
        startFeeding()
        pip.startPictureInPicture()
    }

    func stop() {
        pipController?.stopPictureInPicture()
        // frameSource.stop() runs from pictureInPictureControllerDidStop…
    }

    /// Begin pumping frames from the VLC drawable into the sample-buffer
    /// layer. Idempotent — calling while already feeding is a no-op because
    /// `PIPFrameSource.start` calls `stop()` first.
    func startFeeding() {
        guard isSupported,
              let source = sourceView,
              let sbdl = displayHostView.sampleBufferLayer else { return }
        frameSource.start(target: source, into: sbdl)
    }

    /// Stop the capture loop. Safe to call when feeding isn't active.
    func stopFeeding() {
        frameSource.stop()
    }

    private func attachControllerIfNeeded() {
        guard pipController == nil,
              isSupported,
              let sbdl = displayHostView.sampleBufferLayer else { return }

        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: sbdl,
            playbackDelegate: self
        )
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        // Hand the layer to a floating PIP window automatically when the app
        // backgrounds. Requires the sample-buffer layer to be receiving frames
        // continuously — see `startFeeding()` called from `bind`.
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        self.pipController = controller

        possibilityKVO = controller.observe(
            \.isPictureInPicturePossible,
            options: [.initial, .new]
        ) { [weak self] ctrl, _ in
            let possible = ctrl.isPictureInPicturePossible
            Task { @MainActor in
                self?.isPossible = possible
            }
        }
    }
}

/// UIView whose backing layer IS an `AVSampleBufferDisplayLayer`. AVPiP
/// requires the layer to be in a window's view hierarchy.
private final class PIPHostView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var sampleBufferLayer: AVSampleBufferDisplayLayer? { layer as? AVSampleBufferDisplayLayer }
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
            self.frameSource.stop()
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
            self.frameSource.stop()
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
        Task { @MainActor in
            self.frameSource.targetRenderSize = newRenderSize
        }
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
