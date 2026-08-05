import PlaybackKit
import SwiftUI

/// The bar above the tab bar. On iOS 26 this sits in the tab view's bottom
/// accessory slot, which is the same mechanism Apple Music uses — so it inherits
/// the glass material and the expand/collapse behaviour rather than imitating them.
struct MiniPlayerView: View {
    @State private var engine = PlaybackEngine.shared
    @Binding var isShowingNowPlaying: Bool

    var body: some View {
        if let track = engine.currentTrack {
            HStack(spacing: 12) {
                ArtworkView(url: track.artworkURL, cornerRadius: 4)
                    .frame(width: 32, height: 32)

                Text(track.title)
                    .font(.subheadline)
                    .lineLimit(1)

                Spacer(minLength: 0)

                Button {
                    engine.togglePlayPause()
                } label: {
                    Image(systemName: engine.state.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)

                Button {
                    engine.next()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.title3)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .contentShape(.rect)
            .onTapGesture { isShowingNowPlaying = true }
        }
    }
}
