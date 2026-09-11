import PlaybackKit
import SwiftUI

/// The cover of what is playing — or, while a mix is heard, the two covers
/// crossing.
///
/// The queue moves on to the incoming record the moment a mix begins, so for
/// the length of the mix the "current" cover is a record the listener can
/// barely hear yet. This shows the hand-over instead: the incoming cover
/// wipes across the outgoing one as the crossfader travels, so the picture
/// says what the room hears — mostly the old record, then mostly the new one,
/// then only the new one.
///
/// Only in the app. The lock screen, Control Center and the car take one cover
/// and one title from `MPNowPlayingInfoCenter` and cannot be animated; they
/// switch to the incoming record as the mix begins, which is when the queue
/// does.
struct PlayerArtwork: View {
    let track: Track
    let mixState: PlaybackEngine.MixState
    let outgoing: Track?
    var cornerRadius: CGFloat = 6

    var body: some View {
        if case .mixing(_, _, let progress) = mixState, let outgoing {
            MixingArtwork(
                incoming: track.artworkURL,
                outgoing: outgoing.artworkURL,
                progress: progress,
                cornerRadius: cornerRadius
            )
        } else {
            ArtworkView(url: track.artworkURL, cornerRadius: cornerRadius)
        }
    }
}

/// Two covers, the incoming one revealed left to right by `progress`.
struct MixingArtwork: View {
    let incoming: URL?
    let outgoing: URL?
    /// 0 is all outgoing, 1 is all incoming.
    let progress: Double
    var cornerRadius: CGFloat = 6

    /// How wide the soft edge of the wipe is, as a fraction of the cover. Wide
    /// enough that a step of the fade never reads as a line moving; narrow
    /// enough that the edge is an edge.
    static let edge = 0.08

    var body: some View {
        ArtworkView(url: outgoing, cornerRadius: cornerRadius)
            .overlay {
                ArtworkView(url: incoming, cornerRadius: cornerRadius)
                    .mask { Self.wipe(progress: progress) }
            }
            .accessibilityHidden(true)
    }

    /// Opaque to the left of the crossfader, clear to the right, blurred over
    /// `edge` around it. Solid black at 0 or 1 — the gradient's own stops go
    /// past the ends there, which is what makes the first and last frames a
    /// whole cover rather than a cover with a faint seam.
    static func wipe(progress: Double) -> LinearGradient {
        let p = min(1, max(0, progress))
        let lead = p * (1 + 2 * edge) - edge
        return LinearGradient(
            stops: [
                .init(color: .black, location: 0),
                .init(color: .black, location: min(1, max(0, lead - edge))),
                .init(color: .clear, location: min(1, max(0, lead + edge))),
                .init(color: .clear, location: 1),
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}
