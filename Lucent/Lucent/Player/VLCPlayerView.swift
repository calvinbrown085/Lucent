import SwiftUI
import TVVLCKit

/// Renders the coordinator's active `VLCMediaPlayer` into a UIView.
/// On every update, if the active player exists and isn't already drawing
/// into our view, we re-attach it. That handles the channel-swap case
/// where `activePlayer` becomes a different `VLCMediaPlayer` instance.
struct VLCPlayerView: UIViewRepresentable {
    @Environment(AppModel.self) private var appModel

    func makeUIView(context: Context) -> UIView {
        let view = VLCDrawableView()
        view.backgroundColor = .black
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
