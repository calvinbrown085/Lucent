import SwiftUI
#if canImport(TVVLCKit)
import TVVLCKit
#elseif canImport(MobileVLCKit)
import AVFoundation
import MobileVLCKit
#endif

#if os(tvOS)
/// tvOS path: VLC renders directly into a UIView via its GPU drawable. No PIP
/// on tvOS, so the memory-callback rewrite doesn't apply.
struct VLCPlayerView: UIViewRepresentable {
    @Environment(AppModel.self) private var appModel

    func makeUIView(context: Context) -> UIView {
        let view = VLCDrawableView()
        view.backgroundColor = .black
        view.isUserInteractionEnabled = false
        attach(player: appModel.player.activePlayer, to: view)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        attach(player: appModel.player.activePlayer, to: view)
    }

    private func attach(player: VLCMediaPlayer?, to view: UIView) {
        guard let player else { return }
        let drawable = player.drawable as? UIView
        if drawable !== view {
            player.drawable = view
        }
    }
}

private final class VLCDrawableView: UIView {}

#else
/// iOS / iPadOS path: VLC writes decoded frames into pixel buffers via
/// `PIPFrameSource` (libVLC memory callbacks). Those frames are enqueued
/// onto this view's `AVSampleBufferDisplayLayer` for in-app display. The
/// same layer is handed to `AVPictureInPictureController` so the system can
/// migrate it into the floating PIP window when PIP starts.
struct VLCPlayerView: UIViewRepresentable {
    @Environment(AppModel.self) private var appModel

    func makeUIView(context: Context) -> SampleBufferDisplayView {
        let view = SampleBufferDisplayView()
        view.backgroundColor = .black
        view.isUserInteractionEnabled = false

        let frameSource = appModel.pip.frameSource
        frameSource.addDisplayTarget(view.sampleBufferLayer)

        // Defer until the view is in a window — AVPiP refuses to attach to a
        // layer that isn't in the view hierarchy yet.
        let pip = appModel.pip
        let layer = view.sampleBufferLayer
        Task { @MainActor in
            pip.bind(sampleBufferLayer: layer)
        }
        return view
    }

    func updateUIView(_ view: SampleBufferDisplayView, context: Context) {
        // Nothing — frames are pushed by PIPFrameSource.
    }

    static func dismantleUIView(_ view: SampleBufferDisplayView, coordinator: ()) {
        // The frame source holds a weak ref to the layer, so we don't have to
        // unregister; once the view is freed the entry self-prunes.
    }
}

final class SampleBufferDisplayView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var sampleBufferLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        sampleBufferLayer.videoGravity = .resizeAspect
    }

    required init?(coder: NSCoder) { fatalError() }
}
#endif
