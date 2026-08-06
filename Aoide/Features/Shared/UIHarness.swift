#if DEBUG
import JellyfinKit
import SwiftUI

/// A scratch screen for looking at layout without a server.
///
/// Reached with the launch argument `-AoideUIHarness`. Debug-only: it exists so
/// components can be checked against real pixels rather than reasoned about, which
/// is the only way to catch things like a control that is a few points off centre.
struct UIHarness: View {
    @State private var favorite = false

    var body: some View {
        ScrollView {
            VStack(spacing: 34) {
                sample("Album — not favourited") {
                    DetailActionRow(isFavorite: false, onLeading: {}, onPlay: {}, onTrailing: {})
                }
                sample("Album — favourited") {
                    DetailActionRow(isFavorite: true, onLeading: {}, onPlay: {}, onTrailing: {})
                }
                sample("Artist — station instead of shuffle") {
                    DetailActionRow(
                        leadingIcon: "dot.radiowaves.left.and.right",
                        leadingLabel: "Start Station",
                        trailingIcon: "shuffle",
                        trailingLabel: "Shuffle",
                        trailingFills: false,
                        onLeading: {}, onPlay: {}, onTrailing: {}
                    )
                }
                sample("Track rows — the per-song download control") {
                    VStack(spacing: 0) {
                        ForEach(UIHarness.sampleTracks) { track in
                            TrackRow(track: track, position: track.indexNumber, showsArtist: true)
                            Divider()
                        }
                    }
                }
                sample("Player secondary row — AirPlay beside SF Symbols") {
                    HStack {
                        Image(systemName: "shuffle")
                        Spacer()
                        RoutePickerButton().frame(width: 28, height: 28)
                        Spacer()
                        Image(systemName: "list.bullet")
                        Spacer()
                        Image(systemName: "repeat")
                    }
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 40)
                }
                sample("Disabled — empty playlist") {
                    DetailActionRow(isEnabled: false, onLeading: {}, onPlay: {}, onTrailing: {})
                }
            }
            .padding(.vertical, 28)
        }
        .appBackground()
    }

    /// Decoded rather than constructed: `JellyfinItem` is a wire type with no public
    /// memberwise initialiser, and inventing one purely for a debug screen would put
    /// a second way to build it into the shipping API.
    static let sampleTracks: [JellyfinItem] = {
        let json = Data("""
        [
          {"id":"h1","name":"A Song With Quite a Long Title","type":"Audio","artists":["Someone"],"indexNumber":1,"runTimeTicks":2010000000},
          {"id":"h2","name":"Short One","type":"Audio","artists":["Someone Else"],"indexNumber":2,"runTimeTicks":1350000000}
        ]
        """.utf8)
        return (try? JSONDecoder().decode([JellyfinItem].self, from: json)) ?? []
    }()

    /// A centre line is drawn behind each row: if the capsule is off centre by even
    /// a couple of points, it shows against this immediately.
    private func sample<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tint)
                .tracking(0.6)
            content()
                .overlay(alignment: .center) {
                    Rectangle().fill(.red.opacity(0.6)).frame(width: 1)
                }
        }
        .pageMargin()
    }
}
#endif
