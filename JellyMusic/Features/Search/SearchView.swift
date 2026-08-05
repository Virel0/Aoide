import JellyfinKit
import SwiftUI

struct SearchView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(AppSession.self) private var session

    @State private var query = ""
    @State private var results: [JellyfinItem] = []
    @State private var isSearching = false
    @State private var errorMessage: String?
    /// Incremented on every keystroke so a slow earlier request can tell it's been
    /// superseded and discard its results instead of overwriting newer ones.
    @State private var searchGeneration = 0

    private var songs: [JellyfinItem] { results.filter { $0.type == .audio } }
    private var albums: [JellyfinItem] { results.filter { $0.type == .musicAlbum } }
    private var artists: [JellyfinItem] { results.filter { $0.type == .musicArtist } }

    var body: some View {
        NavigationStack {
            List {
                if let errorMessage {
                    ErrorRow(message: errorMessage) { Task { await search(query) } }
                } else if isSearching && results.isEmpty {
                    LoadingRow()
                } else if !query.isEmpty && results.isEmpty && !isSearching {
                    ContentUnavailableView.search(text: query)
                        .listRowSeparator(.hidden)
                } else {
                    if !artists.isEmpty {
                        Section("Artists") {
                            ForEach(artists) { artist in
                                NavigationLink {
                                    ArtistDetailView(artist: artist)
                                } label: {
                                    HStack(spacing: 12) {
                                        ArtworkView(url: store.artworkURL(for: artist, width: 160), cornerRadius: 22)
                                            .frame(width: 44, height: 44)
                                        Text(artist.name)
                                    }
                                }
                            }
                        }
                    }

                    if !albums.isEmpty {
                        Section("Albums") {
                            ForEach(albums) { album in
                                NavigationLink {
                                    AlbumDetailView(album: album)
                                } label: {
                                    HStack(spacing: 12) {
                                        ArtworkView(url: store.artworkURL(for: album, width: 160))
                                            .frame(width: 44, height: 44)
                                        VStack(alignment: .leading) {
                                            Text(album.name).lineLimit(1)
                                            if !album.subtitle.isEmpty {
                                                Text(album.subtitle)
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                                    .lineLimit(1)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    if !songs.isEmpty {
                        Section("Songs") {
                            ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                                TrackRow(track: song, position: nil, showsArtist: true)
                                    .contentShape(.rect)
                                    .onTapGesture {
                                        store.play(songs, startingAt: index)
                                    }
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Search")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if case .signedIn(let user) = session.state {
                            Text("Signed in as \(user.name)")
                        }
                        Button("Sign Out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                            Task { await session.signOut() }
                        }
                    } label: {
                        Image(systemName: "person.crop.circle")
                    }
                }
            }
        }
        .searchable(text: $query, prompt: "Artists, Songs, Albums")
        .task(id: query) {
            // Debounce: without this every keystroke fires a request and the server
            // answers them out of order.
            guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
                results = []
                isSearching = false
                return
            }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await search(query)
        }
    }

    private func search(_ term: String) async {
        searchGeneration += 1
        let generation = searchGeneration
        isSearching = true
        errorMessage = nil

        do {
            let found = try await store.search(term)
            guard generation == searchGeneration else { return }
            results = found
        } catch {
            guard generation == searchGeneration else { return }
            errorMessage = (error as? JellyfinError)?.errorDescription ?? error.localizedDescription
        }
        isSearching = false
    }
}
