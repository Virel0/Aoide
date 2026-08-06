import JellyfinKit
import SwiftUI

/// Where the Library tab can be sent from outside itself.
enum LibraryRoute: Hashable {
    /// Opened from Spotlight, which hands back an identifier and nothing else.
    case item(id: String)
}

/// Resolves a bare item id into the right detail screen.
///
/// Spotlight stores only the identifier, so arriving from a search result means
/// starting from an id with no idea whether it names an album, an artist or a
/// playlist. Fetching first and then branching is what lets one route serve all
/// three.
struct SpotlightDestination: View {
    let id: String

    @Environment(LibraryStore.self) private var store
    @State private var item: JellyfinItem?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let item {
                switch item.type {
                case .musicAlbum:
                    AlbumDetailView(album: item)
                case .musicArtist:
                    ArtistDetailView(artist: item)
                case .playlist:
                    TrackListView(title: item.name, artworkItem: item, source: .playlist(item.id))
                default:
                    // Anything else was indexed by a version of the app that knew
                    // more than this one does, or has changed type on the server.
                    ContentUnavailableView("Can't Open This", systemImage: "questionmark.folder")
                }
            } else if let errorMessage {
                ErrorRow(message: errorMessage) { Task { await load() } }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .appBackground()
        .task { await load() }
    }

    private func load() async {
        errorMessage = nil
        do {
            item = try await store.item(id: id)
        } catch is CancellationError {
            return
        } catch {
            // A Spotlight entry outlives the thing it points at: the album may have
            // been removed from the server since it was indexed.
            errorMessage = (error as? JellyfinError)?.errorDescription ?? error.localizedDescription
        }
    }
}
