import PlaybackKit
import SwiftUI

/// The cover behind the player's controls, never at a shape it isn't: square
/// and sharp across the top at full width (still or moving), over the same
/// cover blurred to fill the rest of the screen, the way Apple Music shows an
/// album without full-screen art. Cropping a square cover to a tall screen
/// threw most of it away and blew up the middle.
struct FullBleedArtwork: View {
    let track: Track
    let mixState: PlaybackEngine.MixState
    let outgoing: Track?

    /// How far the blurred ground spreads, in points.
    static let blur: CGFloat = 60
    /// The share of the square at its foot that fades into the ground, so the
    /// cover has no hard bottom edge.
    static let foot: CGFloat = 0.14

    var body: some View {
        GeometryReader { frame in
            let side = min(frame.size.width, frame.size.height)
            ZStack(alignment: .top) {
                // Blurred, the crop doesn't show: it's a ground, not the cover.
                ArtworkView(
                    url: track.artworkURL, cornerRadius: 0,
                    aspectRatio: frame.size.width / max(frame.size.height, 1)
                )
                .frame(width: frame.size.width, height: frame.size.height)
                .blur(radius: Self.blur)
                // A blur fades at its edges; grown a little, they're off screen.
                .scaleEffect(1.3)
                .overlay(Color.black.opacity(0.2))

                PlayerArtwork(
                    track: track, mixState: mixState, outgoing: outgoing,
                    cornerRadius: 0, showsMotion: true, aspectRatio: 1
                )
                .frame(width: side, height: side)
                .mask { Self.fade }
            }
            .frame(width: frame.size.width, height: frame.size.height)
            .clipped()
            .overlay { Self.shade }
        }
        // Black until the cover arrives, so the light controls never sit on white.
        .background(.black)
    }

    /// Opaque down the square, clear at its very foot.
    static let fade = LinearGradient(
        stops: [
            .init(color: .black, location: 0),
            .init(color: .black, location: 1 - foot),
            .init(color: .clear, location: 1),
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    /// Darkens the cover under the controls so they read over any cover, pale
    /// ones included, and a little at the top for the grab handle. A shade
    /// rather than the sheet's colour: the cover runs behind the controls.
    static let shade = LinearGradient(
        stops: [
            .init(color: .black.opacity(0.3), location: 0),
            .init(color: .clear, location: 0.12),
            .init(color: .clear, location: 0.3),
            .init(color: .black.opacity(0.6), location: 0.55),
            .init(color: .black.opacity(0.8), location: 0.75),
            .init(color: .black.opacity(0.85), location: 1),
        ],
        startPoint: .top,
        endPoint: .bottom
    )
}
