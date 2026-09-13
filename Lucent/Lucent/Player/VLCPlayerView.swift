import SwiftUI
#if canImport(TVVLCKit)
import TVVLCKit
#elseif canImport(MobileVLCKit)
import MobileVLCKit
import AVFoundation
#endif

/// Hosts live video. Two paths:
///
/// - **Drawable** (tvOS, and iOS with PiP off): adopts
///   `PlayerCoordinator.drawableHost` — the single persistent UIView libVLC
///   renders into — as a subview. Mounting steals the host from wherever it
///   was previously parented, which moves the picture mid-playback without
///   touching `VLCMediaPlayer.drawable`. Reassigning the drawable on a
///   playing player does NOT move the picture: the vout binds to it at
///   creation and never re-reads it, leaving audio-with-black-screen.
/// - **Sample buffer** (iOS with PiP on): an `AVSampleBufferDisplayLayer`
///   registered with `PIPFrameSource`. Any number of these can be mounted at
///   once; each gets every decoded frame. The most recently mounted one is
///   bound to AVKit as the PiP content source.
struct VLCPlayerView: UIViewRepresentable {
    @Environment(AppModel.self) private var appModel

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .black
        container.isUserInteractionEnabled = false
        #if !os(tvOS)
        if appModel.player.usesMemoryOutput {
            let view = SampleBufferDisplayView()
            view.frame = container.bounds
            view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            container.addSubview(view)
            appModel.pip.frameSource.addDisplayTarget(view.sampleBufferLayer)
            appModel.pip.inAppVideoMounted = true
            // AVKit refuses a layer that isn't in a window yet; bind on the
            // next turn once SwiftUI has attached the view.
            let pip = appModel.pip
            let layer = view.sampleBufferLayer
            Task { @MainActor in pip.bind(sampleBufferLayer: layer) }
            return container
        }
        #endif
        adoptHost(into: container)
        return container
    }

    func updateUIView(_ view: UIView, context: Context) {
        #if !os(tvOS)
        if appModel.player.usesMemoryOutput { return }
        #endif
        adoptHost(into: view)
    }

    #if !os(tvOS)
    static func dismantleUIView(_ uiView: UIView, coordinator: ()) {
        // The frame source holds display layers weakly, so nothing to
        // unregister; `inAppVideoMounted` is maintained by the screens.
    }
    #endif

    private func adoptHost(into container: UIView) {
        let host = appModel.player.drawableHost
        guard host.superview !== container else { return }
        host.frame = container.bounds
        host.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(host)
    }
}

#if !os(tvOS)
final class SampleBufferDisplayView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var sampleBufferLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        sampleBufferLayer.videoGravity = .resizeAspect
        backgroundColor = .black
    }

    required init?(coder: NSCoder) { fatalError() }
}
#endif
