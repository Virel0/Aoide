import JellyfinKit
import SwiftUI

struct SearchView: View {
    @Environment(LibraryStore.self) private var store

    @State private var query = ""
    @State private var results: [JellyfinItem] = []
    @State private var isSearching = false
    @State private var errorMessage: String?
    @State private var recents: [String] = RecentSearches.load()
    /// Incremented per keystroke so a slow earlier request can tell it has been
    /// superseded and discard its results rather than overwriting newer ones.
    @State private var generation = 0

    private var trimmed: String { query.trimmingCharacters(in: .whitespaces) }
    private var songs: [JellyfinItem] { results.filter { $0.type == .audio } }
    private var albums: [JellyfinItem] { results.filter { $0.type == .musicAlbum } }
    private var artists: [JellyfinItem] { results.filter { $0.type == .musicArtist } }
    private var playlists: [JellyfinItem] { results.filter { $0.type == .playlist } }

    var body: some View {
        NavigationStack {
            Group {
                if trimmed.isEmpty {
                    idleState
                } else if let errorMessage {
                    ErrorRow(message: errorMessage) { Task { await search(trimmed) } }
                } else if isSearching && results.isEmpty {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if results.isEmpty {
                    ContentUnavailableView.search(text: trimmed)
                } else {
                    resultsList
                }
            }
            .navigationTitle("Search")
        }
        .searchable(text: $query, prompt: "Artists, Songs, Albums")
        .onSubmit(of: .search) {
            guard !trimmed.isEmpty else { return }
            recents = RecentSearches.add(trimmed)
        }
        .task(id: query) {
            guard !trimmed.isEmpty else {
                results = []
                isSearching = false
                errorMessage = nil
                return
            }
            // Debounce: without this every keystroke fires a request and the server
            // answers them out of order.
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await search(trimmed)
        }
    }

    // MARK: - Idle

    private var idleState: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if !recents.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            PlainShelfHeader(title: "Recent")
                            Button("Clear") {
                                recents = RecentSearches.clear()
                            }
                            .font(.subheadline)
                        }
                        ForEach(recents, id: \.self) { term in
                            Button {
                                query = term
                            } label: {
                                HStack {
                                    Image(systemName: "clock.arrow.circlepath")
                                        .foregroundStyle(.secondary)
                                    Text(term).foregroundStyle(.primary)
                                    Spacer()
                                }
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            Divider()
                        }
                    }
                    .pageMargin()
                }

                BrowseGenresSection()
            }
            .padding(.vertical, 12)
        }
    }

    // MARK: - Results

    private var resultsList: some View {
        List {
            if !artists.isEmpty {
                Section("Artists") {
                    ForEach(artists) { artist in
                        NavigationLink {
                            ArtistDetailView(artist: artist)
                        } label: {
                            HStack(spacing: 12) {
                                ArtworkView(
                                    url: store.artworkURL(for: artist, width: Design.ArtworkWidth.thumbnail),
                                    cornerRadius: Design.Radius.round
                                )
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
                            resultRow(album, radius: Design.Radius.thumbnail)
                        }
                        .albumContextMenu(album)
                    }
                }
            }

            if !playlists.isEmpty {
                Section("Playlists") {
                    ForEach(playlists) { playlist in
                        NavigationLink {
                            TrackListView(title: playlist.name, artworkItem: playlist, source: .playlist(playlist.id))
                        } label: {
                            resultRow(playlist, radius: Design.Radius.thumbnail)
                        }
                    }
                }
            }

            if !songs.isEmpty {
                Section("Songs") {
                    ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                        SongRow(song: song)
                            .contentShape(.rect)
                            .onTapGesture {
                                recents = RecentSearches.add(trimmed)
                                store.play(songs, startingAt: index)
                            }
                            .trackContextMenu(song)
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    private func resultRow(_ item: JellyfinItem, radius: CGFloat) -> some View {
        HStack(spacing: 12) {
            ArtworkView(url: store.artworkURL(for: item, width: Design.ArtworkWidth.thumbnail), cornerRadius: radius)
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).lineLimit(1)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    private func search(_ term: String) async {
        generation += 1
        let mine = generation
        isSearching = true
        errorMessage = nil

        do {
            let found = try await store.search(term)
            guard mine == generation else { return }
            results = found
        } catch {
            guard mine == generation else { return }
            errorMessage = (error as? JellyfinError)?.errorDescription ?? error.localizedDescription
        }
        isSearching = false
    }
}

/// Genre tiles under the search field, so an empty search box is somewhere to
/// start rather than a dead end.
private struct BrowseGenresSection: View {
    @Environment(LibraryStore.self) private var store
    @State private var genres: [JellyfinItem] = []

    private let columns = [GridItem(.adaptive(minimum: 160), spacing: Design.Spacing.card)]

    var body: some View {
        Group {
            if !genres.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    PlainShelfHeader(title: "Browse by Genre")
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
                }
                .pageMargin()
            }
        }
        .task {
            genres = (try? await store.musicGenres()) ?? []
        }
    }
}

/// Recent searches, persisted. Small enough that `UserDefaults` is the right home
/// — it isn't a secret and it isn't large.
enum RecentSearches {
    private static let key = "jellymusic.recentSearches"
    private static let limit = 8

    static func load() -> [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    @discardableResult
    static func add(_ term: String) -> [String] {
        var terms = load()
        terms.removeAll { $0.caseInsensitiveCompare(term) == .orderedSame }
        terms.insert(term, at: 0)
        terms = Array(terms.prefix(limit))
        UserDefaults.standard.set(terms, forKey: key)
        return terms
    }

    @discardableResult
    static func clear() -> [String] {
        UserDefaults.standard.removeObject(forKey: key)
        return []
    }
}
