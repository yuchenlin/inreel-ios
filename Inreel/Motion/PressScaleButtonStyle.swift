import SwiftUI

/// Floating-action press feedback: a quick ease-out squish to `Motion.pressScale` on
/// finger-down and a spring back on release (asymmetric = feels physical). Renders the
/// label unstyled like `.plain`. Reduce Motion: no scale, just a slight dim.
struct PressScaleButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        configuration.label
            .contentShape(Rectangle())
            .scaleEffect(pressed && !reduceMotion ? Motion.pressScale : 1)
            .opacity(pressed && reduceMotion ? 0.7 : 1)
            .animation(
                reduceMotion ? Motion.reduced : (pressed ? Motion.press : Motion.release),
                value: pressed
            )
    }
}
