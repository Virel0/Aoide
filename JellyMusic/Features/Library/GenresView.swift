import JellyfinKit
import SwiftUI

struct GenresListView: View {
    @Environment(LibraryStore.self) private var store
    @State private var genres: [JellyfinItem] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    private let columns = [GridItem(.adaptive(minimum: 160), spacing: Design.Spacing.card)]

    var body: some View {
        ScrollView {
            if isLoading {
                ProgressView().padding(.top, 60)
            } else if let errorMessage {
                ErrorRow(message: errorMessage) { Task { await load() } }
            } else if genres.isEmpty {
                ContentUnavailableView(
                    "No Genres",
                    systemImage: "guitars",
                    description: Text("Your library's tracks don't have genre tags.")
                )
                .padding(.top, 60)
            } else {
                LazyVGrid(columns: columns, spacing: Design.Spacing.card) {
                    ForEach(genres) { genre in
                        NavigationLink {
                            GenreDetailView(genre: genre)
                        } label: {
                            GenreTile(name: genre.name)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .pageMargin()
                .padding(.vertical, 12)
            }
        }
        .miniPlayerInset()
        .appBackground()
        .navigationTitle("Genres")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            genres = try await store.musicGenres()
        } catch {
            errorMessage = (error as? JellyfinError)?.errorDescription ?? error.localizedDescription
        }
        isLoading = false
    }
}

/// Genres have no artwork on a personal server, so the tile is typographic — and
/// its colour is derived from the name so the same genre always looks the same.
struct GenreTile: View {
    let name: String

    private var hue: Double {
        // Stable hash so "Jazz" is the same colour on every launch. Swift's own
        // hashValue is seeded per process and would change between runs.
        let sum = name.unicodeScalars.reduce(UInt32(7)) { ($0 &* 31) &+ $1.value }
        return Double(sum % 360) / 360
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(
                colors: [
                    Color(hue: hue, saturation: 0.5, brightness: 0.55),
                    Color(hue: (hue + 0.08).truncatingRemainder(dividingBy: 1), saturation: 0.62, brightness: 0.34),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Text(name)
                .font(.headline)
                .foregroundStyle(.white)
                .lineLimit(2)
                .padding(12)
        }
        .aspectRatio(1.6, contentMode: .fit)
        .clipShape(.rect(cornerRadius: Design.Radius.card))
    }
}

struct GenreDetailView: View {
    let genre: JellyfinItem

    @Environment(LibraryStore.self) private var store
    @State private var albums: [JellyfinItem] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            if isLoading {
                ProgressView().padding(.top, 60)
            } else if let errorMessage {
                ErrorRow(message: errorMessage) { Task { await load() } }
            } else if albums.isEmpty {
                ContentUnavailableView("Nothing in \(genre.name)", systemImage: "guitars")
                    .padding(.top, 60)
            } else {
                AlbumGrid(albums: albums)
                    .pageMargin()
                    .padding(.vertical, 12)
            }
        }
        .miniPlayerInset()
        .appBackground()
        .navigationTitle(genre.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            albums = try await store.albums(inGenre: genre.id)
        } catch {
            errorMessage = (error as? JellyfinError)?.errorDescription ?? error.localizedDescription
        }
        isLoading = false
    }
}

// MARK: - Playlists

struct PlaylistsView: View {
    @Environment(LibraryStore.self) private var store

    var body: some View {
        List {
            switch store.playlists {
            case .idle, .loading:
                LoadingRow()
            case .failed(let message):
                ErrorRow(message: message) {
                    Task { await store.loadPlaylistsIfNeeded() }
                }
            case .loaded(let playlists):
                if playlists.isEmpty {
                    ContentUnavailableView(
                        "No Playlists",
                        systemImage: "music.note.list",
                        description: Text("Playlists you create on your Jellyfin server show up here.")
                    )
                    .listRowSeparator(.hidden)
                } else {
                    ForEach(playlists) { playlist in
                        NavigationLink {
                            TrackListView(
                                title: playlist.name,
                                artworkItem: playlist,
                                source: .playlist(playlist.id)
                            )
                        } label: {
                            HStack(spacing: 12) {
                                ArtworkView(
                                    url: store.artworkURL(for: playlist, width: Design.ArtworkWidth.thumbnail),
                                    cornerRadius: Design.Radius.thumbnail
                                )
                                .frame(width: Design.Size.listThumbnail, height: Design.Size.listThumbnail)
                                VStack(alignment: .leading) {
                                    Text(playlist.name)
                                    if !playlist.subtitle.isEmpty {
                                        Text(playlist.subtitle)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .miniPlayerInset()
        .appBackground()
        .navigationTitle("Playlists")
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.loadPlaylistsIfNeeded() }
    }
}
