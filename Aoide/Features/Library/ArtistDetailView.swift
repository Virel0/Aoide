import JellyfinKit
import SwiftUI

/// An artist page: hero artwork, transport, then their records.
///
/// Apple Music separates Albums / Singles & EPs / Appears On. Jellyfin doesn't mark
/// release type, so rather than invent a distinction we'd get wrong, this splits on
/// something the data actually supports — track count — and labels it honestly.
struct ArtistDetailView: View {
    let artist: JellyfinItem

    @Environment(LibraryStore.self) private var store
    @State private var albums: [JellyfinItem] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var palette: ArtworkPalette?

    private var fullLength: [JellyfinItem] { albums.filter { ($0.childCount ?? 99) > 3 } }
    private var shortReleases: [JellyfinItem] { albums.filter { ($0.childCount ?? 99) <= 3 } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Design.Spacing.shelf) {
                header

                if isLoading {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                } else if let errorMessage {
                    ErrorRow(message: errorMessage) { Task { await load() } }
                } else if albums.isEmpty {
                    ContentUnavailableView("No Albums", systemImage: "square.stack")
                        .padding(.top, 40)
                } else {
                    if !fullLength.isEmpty {
                        section("Albums", fullLength)
                    }
                    if !shortReleases.isEmpty {
                        section("Singles & EPs", shortReleases)
                    }
                }
            }
            .padding(.bottom, 24)
        }
        .miniPlayerInset()
        .appBackground()
        .navigationTitle(artist.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .task(id: artist.id) {
            guard let url = store.artworkURL(for: artist, width: Design.ArtworkWidth.card) else { return }
            palette = await ArtworkColorExtractor.shared.palette(for: url)
        }
    }

    private var header: some View {
        VStack(spacing: 14) {
            ArtworkView(
                url: store.artworkURL(for: artist, width: Design.ArtworkWidth.hero),
                cornerRadius: Design.Radius.round
            )
            .frame(width: 180, height: 180)
            .shadow(color: .black.opacity(0.28), radius: 18, y: 10)

            Text(artist.name)
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)

            if !albums.isEmpty {
                Text("\(albums.count) album\(albums.count == 1 ? "" : "s")".uppercased())
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .tracking(0.4)
            }

            DetailActionRow(
                leadingIcon: "dot.radiowaves.left.and.right",
                leadingLabel: "Start Station",
                trailingIcon: "shuffle",
                trailingLabel: "Shuffle",
                trailingFills: false,
                isEnabled: !albums.isEmpty,
                onLeading: { Task { await store.startStation(seededBy: artist) } },
                onPlay: { Task { await playEverything(shuffled: false) } },
                onTrailing: { Task { await playEverything(shuffled: true) } }
            )
            .pageMargin()
        }
        .padding(.top, 12)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .background {
            if let tint = palette?.tint {
                LinearGradient(
                    colors: [tint.opacity(0.5), tint.opacity(0.14), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea(edges: .top)
            }
        }
        .animation(.easeOut(duration: 0.45), value: palette)
    }

    private func section(_ title: String, _ items: [JellyfinItem]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            PlainShelfHeader(title: title).pageMargin()
            AlbumGrid(albums: items).pageMargin()
        }
    }

    /// Plays the artist's whole catalogue in release order.
    ///
    /// The play source stays `.unknown` for both buttons. An artist is the one place in
    /// the app that plays from something the history has no word for — it is neither an
    /// album nor a playlist, and calling the shuffle button `.shuffle` while the play
    /// button was `.unknown` would split one page's listening across two meanings.
    private func playEverything(shuffled: Bool) async {
        var everything: [JellyfinItem] = []
        for album in albums {
            guard let tracks = try? await store.tracks(inAlbum: album.id) else { continue }
            everything += tracks
        }
        guard !everything.isEmpty else { return }
        store.play(everything, shuffled: shuffled)
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            albums = try await store.albums(byArtist: artist.id)
        } catch {
            errorMessage = (error as? JellyfinError)?.errorDescription ?? error.localizedDescription
        }
        isLoading = false
    }
}
