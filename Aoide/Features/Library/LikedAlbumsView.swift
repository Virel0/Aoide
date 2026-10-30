import MeleteKit
import SwiftUI

/// The albums the listener likes, newest like first, as Melete's likes have them.
/// Liking an album likes none of its songs, so this is not the albums of liked songs.
struct LikedAlbumsView: View {
    @Environment(LibraryStore.self) private var store
    @State private var albums: [MusicItem] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            if isLoading {
                ProgressView().padding(.top, 60)
            } else if let errorMessage {
                ErrorRow(message: errorMessage) { Task { await load() } }
            } else if albums.isEmpty {
                ContentUnavailableView(
                    "No Liked Albums",
                    systemImage: "heart",
                    description: Text("Albums you like show here. Open an album and tap the heart.")
                )
                .padding(.top, 60)
            } else {
                AlbumGrid(albums: albums)
                    .pageMargin()
                    .padding(.vertical, 12)
            }
        }
        .miniPlayerInset()
        .appBackground()
        .navigationTitle("Liked Albums")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        isLoading = albums.isEmpty
        errorMessage = nil
        do {
            albums = try await store.likedAlbums()
        } catch {
            errorMessage = (error as? MeleteError)?.errorDescription ?? error.localizedDescription
        }
        isLoading = false
    }
}
