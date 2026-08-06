import JellyfinKit
import SwiftUI

/// Apple Music puts the same actions behind a long press on almost everything, and
/// the consistency is most of why the app feels navigable. These two modifiers keep
/// ours identical everywhere rather than each screen inventing its own set.
extension View {
    func trackContextMenu(_ track: JellyfinItem) -> some View {
        modifier(TrackContextMenu(track: track))
    }

    func albumContextMenu(_ album: JellyfinItem) -> some View {
        modifier(AlbumContextMenu(album: album))
    }
}

private struct TrackContextMenu: ViewModifier {
    let track: JellyfinItem
    @Environment(LibraryStore.self) private var store

    func body(content: Content) -> some View {
        content.contextMenu {
            Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
                store.playNext([track])
            }
            Button("Play Last", systemImage: "text.line.last.and.arrowtriangle.forward") {
                store.addToQueue([track])
            }

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
        }
    }
}

private struct AlbumContextMenu: ViewModifier {
    let album: JellyfinItem
    @Environment(LibraryStore.self) private var store

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

            Button(
                album.userData?.isFavorite == true ? "Remove from Favourites" : "Favourite",
                systemImage: album.userData?.isFavorite == true ? "heart.slash" : "heart"
            ) {
                Task { await store.toggleFavorite(album) }
            }

            Button("Start Station", systemImage: "dot.radiowaves.left.and.right") {
                Task { await store.startStation(seededBy: album) }
            }
        }
    }
}
