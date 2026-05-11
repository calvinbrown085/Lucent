import SwiftUI
#if canImport(TVVLCKit)
import TVVLCKit
#elseif canImport(MobileVLCKit)
import MobileVLCKit
#endif

/// Renders the coordinator's active `VLCMediaPlayer` into a UIView.
/// On every update, if the active player exists and isn't already drawing
/// into our view, we re-attach it. That handles the channel-swap case
/// where `activePlayer` becomes a different `VLCMediaPlayer` instance.
struct VLCPlayerView: UIViewRepresentable {
    @Environment(AppModel.self) private var appModel

    func makeUIView(context: Context) -> UIView {
        let view = VLCDrawableView()
        view.backgroundColor = .black
        view.isUserInteractionEnabled = false
        attach(player: appModel.player.activePlayer, to: view)
        #if !os(tvOS)
        // Defer until the next runloop so `view.superview` exists when PIP
        // mounts the sample-buffer host as a sibling.
        let model = appModel
        DispatchQueue.main.async {
            model.pip.bind(sourceView: view)
        }
        #endif
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
