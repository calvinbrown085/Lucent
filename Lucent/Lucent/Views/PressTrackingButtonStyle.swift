import SwiftUI

#if !os(tvOS)
/// Drives a parent view's `isPressed` state from the Button's own press
/// configuration instead of a `DragGesture(minimumDistance: 0)`, which would
/// swallow the parent `ScrollView`'s vertical pan on iOS / iPadOS.
struct PressTrackingButtonStyle: ButtonStyle {
    let onPressedChange: (Bool) -> Void
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, isPressed in
                onPressedChange(isPressed)
            }
    }
}
#endif
