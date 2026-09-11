import CurationKit
import JellyfinKit
import SwiftUI

struct SearchView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(SmartSearch.self) private var smart

    @State private var query = ""
    @State private var results: [JellyfinItem] = []
    @State private var isSearching = false
    @State private var errorMessage: String?
    @State private var recents: [String] = RecentSearches.load()
    /// Incremented per keystroke so a slow earlier request can tell it has been
    /// superseded and discard its results rather than overwriting newer ones.
    @State private var generation = 0

    /// Results from interpreting the phrase, kept apart from the name-matched ones.
    /// Merging them would hide which is which, and these are a guess where the
    /// others are exact.
    @State private var smartResults: [JellyfinItem] = []
    @State private var smartQuery: MusicQuery?
    @State private var isInterpreting = false

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
                } else if results.isEmpty && smartResults.isEmpty && !isInterpreting {
                    ContentUnavailableView.search(text: trimmed)
                } else {
                    resultsList
                }
            }
            .miniPlayerInset()
            .appBackground()
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
                smartResults = []
                smartQuery = nil
                isSearching = false
                isInterpreting = false
                errorMessage = nil
                return
            }
            // Debounce: without this every keystroke fires a request and the server
            // answers them out of order.
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await search(trimmed)
            await interpret(trimmed)
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
            if isInterpreting {
                Section {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Working out what you mean…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            } else if !smartResults.isEmpty, let smartQuery {
                Section {
                    ForEach(Array(smartResults.enumerated()), id: \.element.id) { index, song in
                        SongRow(song: song)
                            .contentShape(.rect)
                            .onTapGesture {
                                recents = RecentSearches.add(trimmed)
                                store.play(smartResults, startingAt: index, from: .search)
                            }
                            .trackContextMenu(song, from: .search)
                    }
                } header: {
                    // The interpretation is shown, not hidden: it is the only way to
                    // tell a bad parse from a thin library, and it tells you what to
                    // rephrase.
                    Label(smartQuery.summary, systemImage: "sparkles")
                        .font(.footnote)
                        .textCase(nil)
                }
            }

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
                    // A song found by name plays alone. The rows around it are
                    // the other songs whose names match the words typed, which
                    // says nothing about whether they belong after it — and
                    // queued, they looked like Infinity's choices. Infinity fills
                    // in from here when it is on; when it is off, the song ends.
                    ForEach(songs, id: \.id) { song in
                        SongRow(song: song)
                            .contentShape(.rect)
                            .onTapGesture {
                                recents = RecentSearches.add(trimmed)
                                store.play([song], from: .search)
                            }
                            .trackContextMenu(song, from: .search)
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
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

    /// Runs the phrase through Apple Intelligence, then asks the server.
    ///
    /// Deliberately after the plain search rather than alongside it: this takes a
    /// second or so on device, and the exact matches should never wait behind a
    /// guess. Skipped entirely for short queries and on devices without Apple
    /// Intelligence, where the plain search is the whole feature.
    private func interpret(_ term: String) async {
        guard SmartSearch.looksLikeAPhrase(term), smart.readiness == .ready else {
            smartResults = []
            smartQuery = nil
            return
        }

        let mine = generation
        isInterpreting = true
        defer { if mine == generation { isInterpreting = false } }

        guard let parsed = await smart.interpret(term), mine == generation else {
            if mine == generation {
                smartResults = []
                smartQuery = nil
            }
            return
        }

        guard let found = try? await store.songs(matching: parsed), mine == generation else { return }
        smartQuery = parsed
        smartResults = found
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
        } catch is CancellationError {
            // Every keystroke cancels the previous request; that is the design, not
            // a failure to report.
            return
        } catch {
            guard !Task.isCancelled, mine == generation else { return }
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
    private static let key = "aoide.recentSearches"
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
