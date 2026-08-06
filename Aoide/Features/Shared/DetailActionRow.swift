import SwiftUI

/// Shuffle, Play, Favourite — the row that sits under the artwork on an album,
/// playlist or artist page.
///
/// Extracted from the detail views so its geometry is defined in one place and can
/// be rendered on its own. The centring is explicit rather than inherited from
/// whatever intrinsic size a button style happens to produce: both flanking
/// controls are pinned to the same width, so the capsule is centred by
/// construction and cannot drift when one glyph is wider than the other.
struct DetailActionRow: View {
    /// Only meaningful when the trailing control is the favourite heart.
    var isFavorite: Bool = false
    var leadingIcon: String = "shuffle"
    var leadingLabel: String = "Shuffle"
    /// Album and playlist pages put Favourite here; an artist page has nothing to
    /// favourite, so it puts Shuffle there and Station on the left.
    var trailingIcon: String = "heart"
    var trailingLabel: String?
    var trailingFills: Bool = true
    var isEnabled: Bool = true

    var onLeading: () -> Void
    var onPlay: () -> Void
    var onTrailing: () -> Void

    /// Both circles share this, so the capsule between them is always centred.
    private let circle: CGFloat = 50
    private let height: CGFloat = 50

    var body: some View {
        HStack(spacing: 14) {
            Button(action: onLeading) {
                Image(systemName: leadingIcon)
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: circle, height: height)
                    .contentShape(.rect)
            }
            .buttonStyle(.bordered)
            .clipShape(.circle)
            .accessibilityLabel(leadingLabel)

            Button(action: onPlay) {
                Label("Play", systemImage: "play.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(height: height)
            }
            .buttonStyle(.borderedProminent)
            .clipShape(.capsule)

            Button(action: onTrailing) {
                Image(systemName: trailingFills && isFavorite ? "\(trailingIcon).fill" : trailingIcon)
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: circle, height: height)
                    .contentShape(.rect)
            }
            .buttonStyle(.bordered)
            .clipShape(.circle)
            .accessibilityLabel(
                trailingLabel ?? (isFavorite ? "Remove from Favourites" : "Add to Favourites")
            )
        }
        .disabled(!isEnabled)
        // Fixed so the two circles can never be squeezed to different widths by a
        // long title elsewhere in the layout.
        .fixedSize(horizontal: false, vertical: true)
    }
}
