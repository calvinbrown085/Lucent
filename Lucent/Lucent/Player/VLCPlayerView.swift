import SwiftUI
#if canImport(TVVLCKit)
import TVVLCKit
#elseif canImport(MobileVLCKit)
import MobileVLCKit
#endif

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
