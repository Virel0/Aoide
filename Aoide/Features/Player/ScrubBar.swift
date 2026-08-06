import SwiftUI

/// The Now Playing progress bar.
///
/// Deliberately not a `Slider`. Now Playing is presented as a sheet, and a sheet
/// runs its own drag-to-dismiss recogniser over the whole surface. When that
/// recogniser claims a drag, the Slider's gesture is *cancelled* rather than ended —
/// and `onEditingChanged(false)`, the only signal SwiftUI offers that a drag
/// finished, never arrives. The scrubber was then left holding the position the
/// finger stopped at, permanently ahead of a song that carried on playing.
///
/// Owning the gesture fixes it at the root: `highPriorityGesture` wins against the
/// sheet before the competition starts, so `onEnded` is reliable. It also buys the
/// bar that thickens under a finger, which Apple Music has and a stock Slider can't
/// be persuaded into.
struct ScrubBar: View {
    /// Where playback actually is.
    let elapsed: Double
    let duration: Double
    /// Where the finger is, while there is one. Owned by the caller so it can also
    /// render the time labels from the dragged position rather than the real one.
    @Binding var dragPosition: Double?
    let onCommit: (Double) -> Void

    private let idleHeight: CGFloat = 7
    private let activeHeight: CGFloat = 12

    @State private var isDragging = false

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let position = dragPosition ?? elapsed
            let fraction = duration > 0 ? min(max(position / duration, 0), 1) : 0

            ZStack(alignment: .leading) {
                Capsule().fill(.fill.tertiary)
                Capsule()
                    .fill(.primary.opacity(0.85))
                    .frame(width: width * fraction)
            }
            .frame(height: isDragging ? activeHeight : idleHeight)
            // Centred inside a taller row: the bar itself is too thin to hit
            // reliably, and the row keeps a fixed height so nothing below it moves
            // when the bar thickens.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .contentShape(.rect)
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard duration > 0, width > 0 else { return }
                        isDragging = true
                        dragPosition = seconds(at: value.location.x, width: width)
                    }
                    .onEnded { value in
                        defer {
                            isDragging = false
                            dragPosition = nil
                        }
                        guard duration > 0, width > 0 else { return }
                        onCommit(seconds(at: value.location.x, width: width))
                    }
            )
            .animation(.easeOut(duration: 0.15), value: isDragging)
        }
        .frame(height: 28)
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue(Duration.seconds(dragPosition ?? elapsed).clockDescription)
        .accessibilityAdjustableAction { direction in
            guard duration > 0 else { return }
            // Fifteen seconds a step, matching the system's skip controls.
            let step: Double = direction == .increment ? 15 : -15
            onCommit(min(max(elapsed + step, 0), duration))
        }
    }

    private func seconds(at x: CGFloat, width: CGFloat) -> Double {
        min(max(Double(x / width), 0), 1) * duration
    }
}
