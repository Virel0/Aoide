import JellyfinKit
import SwiftUI

/// The Library tab: Apple Music's list of categories, then a grid of albums.
struct LibraryView: View {
    @Environment(LibraryStore.self) private var store

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        PlaylistsView()
                    } label: {
                        Label("Playlists", systemImage: "music.note.list")
                    }
                    NavigationLink {
                        ArtistsView()
                    } label: {
                        Label("Artists", systemImage: "music.microphone")
                    }
                }

                if let recent = store.recentlyAdded.value, !recent.isEmpty {
                    Section("Recently Added") {
                        AlbumGrid(albums: recent)
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    }
                }

                Section("Albums") {
                    switch store.albums {
                    case .idle, .loading:
                        LoadingRow()
                    case .failed(let message):
                        ErrorRow(message: message) {
                            Task { await store.refresh() }
                        }
                    case .loaded(let albums):
                        if albums.isEmpty {
                            Text("No albums in your library.")
                                .foregroundStyle(.secondary)
                        } else {
                            AlbumGrid(albums: albums)
                                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        }
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Library")
            .refreshable { await store.refresh() }
            .task {
                await store.loadRecentlyAddedIfNeeded()
                await store.loadAlbumsIfNeeded()
            }
        }
    }
}

/// Two columns of square covers, the way Apple Music lays out a library.
struct AlbumGrid: View {
    let albums: [JellyfinItem]

    @Environment(LibraryStore.self) private var store

    private let columns = [
        GridItem(.adaptive(minimum: 140), spacing: 16)
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 20) {
            ForEach(albums) { album in
                NavigationLink {
                    AlbumDetailView(album: album)
                } label: {
                    AlbumCell(album: album)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct AlbumCell: View {
    let album: JellyfinItem

    @Environment(LibraryStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ArtworkView(url: store.artworkURL(for: album, width: 400))

            Text(album.name)
                .font(.subheadline)
                .lineLimit(1)

            if !album.subtitle.isEmpty {
                Text(album.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
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
                    Text("No playlists yet.")
                        .foregroundStyle(.secondary)
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
                                ArtworkView(url: store.artworkURL(for: playlist, width: 160))
                                    .frame(width: 52, height: 52)
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
        .navigationTitle("Playlists")
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.loadPlaylistsIfNeeded() }
    }
}

// MARK: - Artists

struct ArtistsView: View {
    @Environment(LibraryStore.self) private var store

    var body: some View {
        List {
            switch store.artists {
            case .idle, .loading:
                LoadingRow()
            case .failed(let message):
                ErrorRow(message: message) {
                    Task { await store.loadArtistsIfNeeded() }
                }
            case .loaded(let artists):
                ForEach(artists) { artist in
                    NavigationLink {
                        ArtistDetailView(artist: artist)
                    } label: {
                        HStack(spacing: 12) {
                            ArtworkView(url: store.artworkURL(for: artist, width: 160), cornerRadius: 26)
                                .frame(width: 52, height: 52)
                            Text(artist.name)
                        }
                    }
                }
            }
        }
        .navigationTitle("Artists")
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.loadArtistsIfNeeded() }
    }
}

struct ArtistDetailView: View {
    let artist: JellyfinItem

    @Environment(LibraryStore.self) private var store
    @State private var albums: [JellyfinItem] = []
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            if let errorMessage {
                ErrorRow(message: errorMessage) { Task { await load() } }
                    .padding()
            } else if albums.isEmpty {
                ProgressView().padding(.top, 40)
            } else {
                AlbumGrid(albums: albums)
                    .padding(.horizontal)
                    .padding(.top, 8)
            }
        }
        .navigationTitle(artist.name)
        .navigationBarTitleDisplayMode(.large)
        .task { await load() }
    }

    private func load() async {
        do {
            errorMessage = nil
            albums = try await store.albums(byArtist: artist.id)
        } catch {
            errorMessage = (error as? JellyfinError)?.errorDescription ?? error.localizedDescription
        }
    }
}

// MARK: - Small shared rows

struct LoadingRow: View {
    var body: some View {
        HStack {
            Spacer()
            ProgressView()
            Spacer()
        }
        .padding(.vertical, 24)
        .listRowSeparator(.hidden)
    }
}

struct ErrorRow: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Try Again", action: retry)
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .listRowSeparator(.hidden)
    }
}
