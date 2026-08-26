import SwiftUI
#if canImport(TVVLCKit)
import TVVLCKit
#elseif canImport(MobileVLCKit)
import MobileVLCKit
#endif

/// Hosts live video by adopting `PlayerCoordinator.drawableHost` — the single
/// persistent UIView libVLC renders into — as a subview. Mounting this view
/// steals the host from wherever it was previously parented (hero preview,
/// fullscreen), which moves the video mid-playback without touching
/// `VLCMediaPlayer.drawable`. Reassigning the drawable on a playing player
/// does NOT move the picture: the vout binds to the drawable at creation and
/// never re-reads it, leaving audio-with-black-screen.
struct VLCPlayerView: UIViewRepresentable {
    @Environment(AppModel.self) private var appModel

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .black
        container.isUserInteractionEnabled = false
        adoptHost(into: container)
        return container
    }

    func updateUIView(_ view: UIView, context: Context) {
        adoptHost(into: view)
    }

    private func adoptHost(into container: UIView) {
        let host = appModel.player.drawableHost
        guard host.superview !== container else { return }
        host.frame = container.bounds
        host.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(host)
    }
}
