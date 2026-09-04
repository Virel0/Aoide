import CurationKit
import JellyfinKit
import SwiftUI

/// Apple Music puts the same actions behind a long press on almost everything, and
/// the consistency is most of why the app feels navigable. These two modifiers keep
/// ours identical everywhere rather than each screen inventing its own set.
extension View {
    /// `source` is where the row being pressed came from, for the play history. It
    /// defaults to `.unknown` because most of the screens using this genuinely have no
    /// answer — a song in the Songs list came from nowhere in particular — and guessing
    /// one would put a fiction in the recap.
    func trackContextMenu(_ track: JellyfinItem, from source: PlaySource = .unknown) -> some View {
        modifier(TrackContextMenu(track: track, source: source))
    }

    func albumContextMenu(_ album: JellyfinItem) -> some View {
        modifier(AlbumContextMenu(album: album))
    }
}

private struct TrackContextMenu: ViewModifier {
    let track: JellyfinItem
    let source: PlaySource
    @Environment(LibraryStore.self) private var store
    @Environment(LocalPlaylistStore.self) private var playlists
    @State private var adding: TrackSelection?

    func body(content: Content) -> some View {
        content.contextMenu {
            Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
                store.playNext([track], from: source)
            }
            Button("Play Last", systemImage: "text.line.last.and.arrowtriangle.forward") {
                store.addToQueue([track], from: source)
            }

            Divider()

            Button("Add to Playlist…", systemImage: "text.badge.plus") {
                adding = TrackSelection([track])
            }

            Divider()

            TasteFlagButtons(track: track)

            Divider()

            Button(
                track.userData?.isFavorite == true ? "Remove from Favourites" : "Favourite",
                systemImage: track.userData?.isFavorite == true ? "heart.slash" : "heart"
            ) {
                Task { await store.toggleFavorite(track) }
            }

            Button("Start Station", systemImage: "dot.radiowaves.left.and.right") {
                Task { await store.startStation(seededBy: track) }
            }

            Divider()

            if DownloadStore.shared.state(for: track.id).isPresent {
                Button("Remove Download", systemImage: "trash") {
                    DownloadStore.shared.remove(track.id)
                }
            } else {
                Button("Download", systemImage: "arrow.down.circle") {
                    store.download([track])
                }
            }
        }
        // Attached to the row, not written inside the menu: a context menu is dismissed
        // before its action runs, so it has no view of its own to present from. Both
        // stores are injected explicitly rather than inherited — a sheet is an
        // environment boundary, and a missing `@Environment` observable is a crash.
        .sheet(item: $adding) { selection in
            AddToPlaylistSheet(selection: selection)
                .environment(store)
                .environment(playlists)
        }
    }
}

private struct AlbumContextMenu: ViewModifier {
    let album: JellyfinItem
    @Environment(LibraryStore.self) private var store
    @Environment(LocalPlaylistStore.self) private var playlists
    @State private var adding: TrackSelection?

    func body(content: Content) -> some View {
        content.contextMenu {
            Button("Play", systemImage: "play.fill") {
                Task { await store.playAlbum(album) }
            }
            Button("Shuffle", systemImage: "shuffle") {
                Task { await store.playAlbum(album, shuffled: true) }
            }

            Divider()

            Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
                Task { await store.queueAlbum(album, next: true) }
            }
            Button("Play Last", systemImage: "text.line.last.and.arrowtriangle.forward") {
                Task { await store.queueAlbum(album, next: false) }
            }

            Divider()

            Button("Add to Playlist…", systemImage: "text.badge.plus") {
                // The album's tracks are fetched before the sheet opens rather than
                // inside it: an empty picker that fills in a moment later is a picker
                // somebody taps through before it means anything.
                Task {
                    guard let tracks = try? await store.tracks(inAlbum: album.id), !tracks.isEmpty else { return }
                    adding = TrackSelection(tracks)
                }
            }

            Divider()

            Button(
                album.userData?.isFavorite == true ? "Remove from Favourites" : "Favourite",
                systemImage: album.userData?.isFavorite == true ? "heart.slash" : "heart"
            ) {
                Task { await store.toggleFavorite(album) }
            }

            Button("Start Station", systemImage: "dot.radiowaves.left.and.right") {
                Task { await store.startStation(seededBy: album) }
            }

            Divider()

            Button("Download", systemImage: "arrow.down.circle") {
                Task {
                    guard let tracks = try? await store.tracks(inAlbum: album.id) else { return }
                    let audio = tracks.filter { $0.type == .audio }
                    store.download(audio, in: DownloadedCollection(
                        id: album.id, kind: .album, name: album.name,
                        subtitle: album.albumArtist ?? album.artists.first,
                        trackIds: audio.map(\.id)
                    ))
                }
            }
        }
        .sheet(item: $adding) { selection in
            AddToPlaylistSheet(selection: selection)
                .environment(store)
                .environment(playlists)
        }
    }
}
