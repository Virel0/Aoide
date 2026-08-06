import AVKit
import SwiftUI

/// The AirPlay button.
///
/// Wraps `AVRoutePickerView` rather than drawing our own: the system view is the
/// only thing that can present the route sheet, and it also animates the glyph while
/// audio is routed elsewhere — which is how you can tell at a glance that the sound
/// is going to the kitchen speaker rather than the phone.
struct RoutePickerButton: UIViewRepresentable {
    var tint: UIColor = .secondaryLabel
    var activeTint: UIColor = .tintColor

    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = tint
        view.activeTintColor = activeTint
        // Otherwise a long press offers to mirror the whole screen, which for an
        // audio app sends the music to a TV as a side effect of a video feature.
        view.prioritizesVideoDevices = false
        view.setContentHuggingPriority(.required, for: .horizontal)
        view.setContentHuggingPriority(.required, for: .vertical)
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {
        view.tintColor = tint
        view.activeTintColor = activeTint
    }
}
