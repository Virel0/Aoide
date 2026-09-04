import PlaybackKit
import SwiftUI

/// The bar above the tab bar. On iOS 26 this sits in the tab view's bottom
/// accessory slot, which is the same mechanism Apple Music uses — so it inherits
/// the glass material and the expand/collapse behaviour rather than imitating them.
struct MiniPlayerView: View {
    @State private var engine = PlaybackEngine.shared
    @Binding var isShowingNowPlaying: Bool

    var body: some View {
        // The accessory slot draws its glass container whether or not we fill it, so
        // an empty branch reads as a broken pill. Conditionally applying the
        // modifier instead would rebuild the TabView and throw away the selected tab
        // the moment music started — so the idle state gets real content instead.
        if let track = engine.currentTrack {
            HStack(spacing: 12) {
                ArtworkView(url: track.artworkURL, cornerRadius: 4)
                    .frame(width: Design.Size.miniPlayerArtwork, height: Design.Size.miniPlayerArtwork)

                VStack(alignment: .leading, spacing: 1) {
                    Text(track.title)
                        .font(.subheadline)
                        .lineLimit(1)
                    if let failure = engine.lastFailure {
                        // The player's reason, verbatim. Vague reassurance here
                        // would hide the one line that says what is wrong.
                        Text("Couldn't play \(failure.trackTitle): \(failure.message)")
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .lineLimit(2)
                    } else if !track.artist.isEmpty {
                        Text(track.artist)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

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
        } else {
            IdleMiniPlayer()
        }
    }
}

/// What the accessory shows before anything has been played.
///
/// Rather than an empty pill, it offers the one action that always makes sense on
/// a music library you own: play something at random.
private struct IdleMiniPlayer: View {
    @Environment(LibraryStore.self) private var store
    @State private var isStarting = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "shuffle")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.tint)
                .frame(width: Design.Size.miniPlayerArtwork, height: Design.Size.miniPlayerArtwork)

            Text("Shuffle your library")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 0)

            if isStarting {
                ProgressView()
            }
        }
        .padding(.horizontal, 12)
        .contentShape(.rect)
        .onTapGesture {
            guard !isStarting else { return }
            isStarting = true
            Task {
                await store.shuffleEverything()
                isStarting = false
            }
        }
    }
}
