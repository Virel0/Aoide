import CurationKit
import Foundation
import JellyfinKit
import PlaybackKit
import os

/// Loads and caches the library.
///
/// One store shared across the tabs, so switching from Albums to Artists and back
/// doesn't refetch what's already on screen.
@MainActor
@Observable
final class LibraryStore {
    /// A section's data plus whether it's still loading — enough for a view to show
    /// a spinner, an error, or an empty state without a pile of parallel flags.
    enum Loadable<Value> {
        case idle
        case loading
        case loaded(Value)
        case failed(String)

        var value: Value? {
            if case .loaded(let value) = self { return value }
            return nil
        }

        var isLoading: Bool {
            if case .loading = self { return true }
            return false
        }

        var errorMessage: String? {
            if case .failed(let message) = self { return message }
            return nil
        }
    }

    private(set) var albums: Loadable<[JellyfinItem]> = .idle
    private(set) var artists: Loadable<[JellyfinItem]> = .idle
    private(set) var playlists: Loadable<[JellyfinItem]> = .idle
    private(set) var recentlyAdded: Loadable<[JellyfinItem]> = .idle

    // Home shelves. Each is independent so one failing server query leaves the
    // rest of the page intact rather than blanking it.
    private(set) var recentlyPlayed: Loadable<[JellyfinItem]> = .idle
    private(set) var mostPlayed: Loadable<[JellyfinItem]> = .idle
    private(set) var favorites: Loadable<[JellyfinItem]> = .idle
    private(set) var rediscover: Loadable<[JellyfinItem]> = .idle

    /// Album tracks, keyed by album id, so reopening an album is instant.
    private var trackCache: [String: [JellyfinItem]] = [:]

    private let client: JellyfinClient
    private let log = Logger(subsystem: "com.example.aoide", category: "library")

    /// Ids of the user's music libraries, resolved once. `nil` until then.
    private var musicLibraryIds: [String]?

    init(client: JellyfinClient) {
        self.client = client
    }

    // MARK: - Library scope

    /// Which libraries to search.
    ///
    /// Without this every query ran `recursive: true` with no parent, i.e. across
    /// the entire server. That matters beyond wasted work: a Jellyfin audiobook
    /// library stores its chapters as `Audio` items, so an unscoped track query
    /// returns audiobook chapters alongside music.
    private func libraryScope() async -> [String] {
        if let musicLibraryIds { return musicLibraryIds }
        do {
            let ids = try await client.musicLibraries().map(\.id)
            musicLibraryIds = ids
            log.info("Scoped to \(ids.count, privacy: .public) music librar\(ids.count == 1 ? "y" : "ies", privacy: .public)")
            return ids
        } catch {
            // Deliberately NOT caching the failure. Assigning `[]` here looks
            // harmless but is the same non-nil sentinel a successful empty result
            // produces, so the fast path above would return it forever — silently
            // un-scoping every query for the rest of the session and letting
            // audiobook chapters back into Songs and Search.
            log.error("Could not resolve music libraries, querying unscoped once: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    /// Runs a query once per music library and merges the results, because
    /// Jellyfin's `parentId` accepts a single id. With one music library — the
    /// common case — this is exactly one request.
    private func acrossLibraries<T: Sendable>(
        _ body: @Sendable @escaping (String?) async throws -> [T]
    ) async throws -> [T] {
        let ids = await libraryScope()
        guard !ids.isEmpty else { return try await body(nil) }
        guard ids.count > 1 else { return try await body(ids[0]) }

        return try await withThrowingTaskGroup(of: [T].self) { group in
            for id in ids {
                group.addTask { try await body(id) }
            }
            var merged: [T] = []
            for try await chunk in group { merged.append(contentsOf: chunk) }
            return merged
        }
    }

    // MARK: - Loading

    func loadAlbumsIfNeeded() async { await fill(\.albums, with: fetchAlbums) }
    func loadArtistsIfNeeded() async { await fill(\.artists, with: fetchArtists) }
    func loadPlaylistsIfNeeded() async { await fill(\.playlists, with: fetchPlaylists) }
    func loadRecentlyAddedIfNeeded() async { await fill(\.recentlyAdded, with: fetchRecentlyAdded) }
    func loadRecentlyPlayedIfNeeded() async { await fill(\.recentlyPlayed, with: fetchRecentlyPlayed) }
    func loadMostPlayedIfNeeded() async { await fill(\.mostPlayed, with: fetchMostPlayed) }
    func loadFavoritesIfNeeded() async { await fill(\.favorites, with: fetchFavorites) }
    func loadRediscoverIfNeeded() async { await fill(\.rediscover, with: fetchRediscover) }

    /// Forces a retry from a `.failed` state, which `loadPlaylistsIfNeeded` will
    /// not do — its `.idle` guard is what made the Try Again button a no-op.
    func reloadPlaylists() async {
        playlists = .idle
        await loadPlaylistsIfNeeded()
    }

    /// Loads the Home shelves concurrently.
    ///
    /// Each shelf owns its own state, so a query that fails or comes back empty
    /// hides that one row instead of taking the page down with it — which matters
    /// on a personal library where several of these are legitimately empty until
    /// there's listening history.
    func loadHomeIfNeeded() async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.loadRecentlyAddedIfNeeded() }
            group.addTask { await self.loadRecentlyPlayedIfNeeded() }
            group.addTask { await self.loadMostPlayedIfNeeded() }
            group.addTask { await self.loadFavoritesIfNeeded() }
            group.addTask { await self.loadRediscoverIfNeeded() }
        }
    }

    /// Fills a section that has never been asked for; leaves any other state alone.
    private func fill<Value>(
        _ section: ReferenceWritableKeyPath<LibraryStore, Loadable<Value>>,
        with fetch: @escaping () async throws -> Value
    ) async {
        guard case .idle = self[keyPath: section] else { return }
        self[keyPath: section] = .loading
        self[keyPath: section] = await load(fetch)
    }

    // MARK: - Coming back

    /// How long the caches may sit before coming back to the app fetches them again.
    ///
    /// Five minutes is long enough that switching apps to answer a message costs
    /// nothing, and short enough that an album added from the desk over lunch is
    /// on the phone's Home by the walk home.
    private static let staleAfter: TimeInterval = 5 * 60
    private var lastRefresh = Date()

    /// Refreshes whatever is on screen if it has been a while, keeping the old data
    /// up until the new arrives.
    ///
    /// Not `refresh()`: that drops every section to `.idle` first, which is right
    /// under a pull-to-refresh spinner and wrong on return from the background,
    /// where it would blank the screen somebody has just come back to. A section
    /// that was never loaded is left alone — its screen loads it on appearance —
    /// and one whose fetch fails keeps what it had rather than showing an error
    /// nobody asked for.
    func refreshIfStale() async {
        guard Date().timeIntervalSince(lastRefresh) >= Self.staleAfter else { return }
        lastRefresh = Date()
        trackCache.removeAll()
        // Formed here, on the main actor, because a key path to an isolated
        // property cannot be written inside a child task.
        let refreshers: [@MainActor () async -> Void] = [
            { await self.replace(\.albums, with: self.fetchAlbums) },
            { await self.replace(\.artists, with: self.fetchArtists) },
            { await self.replace(\.playlists, with: self.fetchPlaylists) },
            { await self.replace(\.recentlyAdded, with: self.fetchRecentlyAdded) },
            { await self.replace(\.recentlyPlayed, with: self.fetchRecentlyPlayed) },
            { await self.replace(\.mostPlayed, with: self.fetchMostPlayed) },
            { await self.replace(\.favorites, with: self.fetchFavorites) },
            { await self.replace(\.rediscover, with: self.fetchRediscover) },
        ]
        await withTaskGroup(of: Void.self) { group in
            for refresh in refreshers {
                group.addTask { await refresh() }
            }
        }
    }

    private func replace<Value>(
        _ section: ReferenceWritableKeyPath<LibraryStore, Loadable<Value>>,
        with fetch: @escaping () async throws -> Value
    ) async {
        guard case .loaded = self[keyPath: section] else { return }
        guard let fresh = try? await fetch() else { return }
        self[keyPath: section] = .loaded(fresh)
    }

    // MARK: - Queries behind the sections

    private func fetchAlbums() async throws -> [JellyfinItem] {
        try await acrossLibraries { parentId in
            try await self.client.albums(parentId: parentId, sort: .name).items
        }
    }

    private func fetchArtists() async throws -> [JellyfinItem] {
        try await acrossLibraries { parentId in
            try await self.client.albumArtists(parentId: parentId).items
        }
    }

    private func fetchPlaylists() async throws -> [JellyfinItem] {
        try await client.playlists()
    }

    private func fetchRecentlyAdded() async throws -> [JellyfinItem] {
        try await acrossLibraries { parentId in
            try await self.client.recentlyAdded(parentId: parentId, limit: 20)
        }
    }

    private func fetchRecentlyPlayed() async throws -> [JellyfinItem] {
        try await acrossLibraries { parentId in
            try await self.client.recentlyPlayedAlbums(parentId: parentId, limit: 20)
        }
    }

    private func fetchMostPlayed() async throws -> [JellyfinItem] {
        try await acrossLibraries { parentId in
            try await self.client.mostPlayedAlbums(parentId: parentId, limit: 20)
        }
    }

    private func fetchFavorites() async throws -> [JellyfinItem] {
        try await acrossLibraries { parentId in
            try await self.client.favoriteAlbums(parentId: parentId, limit: 20)
        }
    }

    private func fetchRediscover() async throws -> [JellyfinItem] {
        try await acrossLibraries { parentId in
            try await self.client.notPlayedRecently(parentId: parentId, limit: 20)
        }
    }

    /// Pull to refresh — drops every cache and reloads what's on screen.
    func refresh() async {
        lastRefresh = Date()
        trackCache.removeAll()
        musicLibraryIds = nil
        albums = .idle
        artists = .idle
        playlists = .idle
        recentlyAdded = .idle
        recentlyPlayed = .idle
        mostPlayed = .idle
        favorites = .idle
        rediscover = .idle
        await loadHomeIfNeeded()
        await loadAlbumsIfNeeded()
    }

    func tracks(inAlbum albumId: String) async throws -> [JellyfinItem] {
        if let cached = trackCache[albumId] { return cached }
        let tracks = try await client.tracks(inAlbum: albumId)
        trackCache[albumId] = tracks
        return tracks
    }

    func tracks(inPlaylist playlistId: String) async throws -> [JellyfinItem] {
        if let cached = trackCache[playlistId] { return cached }
        let tracks = try await client.tracks(inPlaylist: playlistId)
        trackCache[playlistId] = tracks
        return tracks
    }

    func albums(byArtist artistId: String) async throws -> [JellyfinItem] {
        try await client.albums(byArtist: artistId)
    }

    // MARK: - Paged lists

    /// A fresh paged list is built per sort order rather than re-sorting in memory,
    /// because only the first page is loaded and the rest of the ordering lives on
    /// the server.
    func albumsPage(sort: ItemSort) -> PagedItems {
        PagedItems { [weak self] startIndex, limit in
            guard let self else { return ItemsResponse.empty }
            return try await self.acrossLibrariesPaged(startIndex: startIndex, limit: limit) { parentId, start, count in
                try await self.client.albums(
                    parentId: parentId,
                    sort: sort,
                    direction: sort.naturalDirection,
                    startIndex: start,
                    limit: count
                )
            }
        }
    }

    func artistsPage() -> PagedItems {
        PagedItems { [weak self] startIndex, limit in
            guard let self else { return ItemsResponse.empty }
            return try await self.acrossLibrariesPaged(startIndex: startIndex, limit: limit) { parentId, start, count in
                try await self.client.albumArtists(parentId: parentId, startIndex: start, limit: count)
            }
        }
    }

    func songsPage(sort: ItemSort) -> PagedItems {
        PagedItems { [weak self] startIndex, limit in
            guard let self else { return ItemsResponse.empty }
            return try await self.acrossLibrariesPaged(startIndex: startIndex, limit: limit) { parentId, start, count in
                try await self.client.songs(
                    parentId: parentId,
                    sort: sort,
                    direction: sort.naturalDirection,
                    startIndex: start,
                    limit: count
                )
            }
        }
    }

    /// The music libraries, for callers that have to walk them one at a time.
    ///
    /// Exposed only for the song index, which is the one pass that genuinely must cover
    /// every library: `acrossLibrariesPaged` below pages the first and accepts it, which
    /// is right for a browsable list and would silently index only part of the music on
    /// a server with two.
    func musicLibraryScope() async -> [String] {
        await libraryScope()
    }

    /// One page of songs from one library, for the index. Sorted by name only so the
    /// paging is stable from the first page to the last — `.random` would return a
    /// different permutation per request and index some tracks twice and others never.
    func songsBatch(parentId: String?, startIndex: Int, limit: Int) async throws -> ItemsResponse {
        try await client.songs(
            parentId: parentId,
            sort: .name,
            direction: .ascending,
            startIndex: startIndex,
            limit: limit
        )
    }

    /// Paging across several music libraries can't be merged correctly — two
    /// independently-paged sorted lists don't interleave — so with more than one
    /// library we page the first and accept it. In practice a music server has one.
    private func acrossLibrariesPaged(
        startIndex: Int,
        limit: Int,
        _ body: @escaping (String?, Int, Int) async throws -> ItemsResponse
    ) async throws -> ItemsResponse {
        let ids = await libraryScope()
        return try await body(ids.first, startIndex, limit)
    }

    // MARK: - Downloads

    /// The store needs a client to build stream URLs, and the client lives here.
    func download(_ items: [JellyfinItem], in collection: DownloadedCollection? = nil) {
        // Written before the transfer starts, not after: offline, the server cannot
        // be asked what a downloaded file contains, so the metadata must already be
        // on disk or the Downloaded screen is a list of identifiers.
        DownloadIndex.shared.record(items)
        if let collection { DownloadIndex.shared.record(collection) }
        DownloadStore.shared.download(items, client: client)
    }

    // MARK: - Playback shortcuts

    func playAlbum(_ album: JellyfinItem, shuffled: Bool = false) async {
        guard let tracks = try? await tracks(inAlbum: album.id) else { return }
        // `.album` whether or not it was shuffled. Shuffle is how the album is being
        // played, not where it came from, and `.shuffle` is reserved for a queue the
        // app assembled with no collection behind it at all.
        play(tracks, shuffled: shuffled, from: .album)
    }

    func queueAlbum(_ album: JellyfinItem, next: Bool) async {
        guard let tracks = try? await tracks(inAlbum: album.id) else { return }
        if next { playNext(tracks, from: .album) } else { addToQueue(tracks, from: .album) }
    }

    /// Shuffle the whole library.
    ///
    /// Asks the server for a random page rather than fetching everything and
    /// shuffling locally — on a large library that would be a very long wait for
    /// what is meant to be an instant action.
    func shuffleEverything(limit: Int = 300) async {
        do {
            let tracks = try await acrossLibraries { parentId in
                try await self.client.songs(
                    parentId: parentId,
                    sort: .random,
                    startIndex: 0,
                    limit: limit
                ).items
            }
            guard !tracks.isEmpty else { return }
            // The one true `.shuffle`: a queue with no album, playlist or search behind
            // it, assembled because the listener asked for anything at all.
            play(tracks, from: .shuffle)
        } catch {
            log.error("Could not shuffle library: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Jellyfin's Instant Mix — a station seeded from any track, album or artist.
    /// The closest thing a personal library has to Apple Music's radio.
    func startStation(seededBy item: JellyfinItem) async {
        do {
            let mix = try await client.instantMix(seededBy: item.id)
            // Left `.unknown`: a station is none of the sources the schema has a word
            // for, and filing it under the nearest one would put songs nobody chose
            // into the recap's "you played this album a lot".
            play(mix)
        } catch {
            log.error("Could not start station: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Flips the favourite flag on the server. Favourites are the one piece of
    /// album-level user data Jellyfin genuinely keeps, because the user sets it
    /// rather than it being derived from playback.
    /// `desired` is the intent, not a derivation. Deriving it from `item.userData`
    /// read a snapshot captured when the list was fetched, so a second tap sent the
    /// same value again and un-favouriting was impossible.
    @discardableResult
    func toggleFavorite(
        _ item: JellyfinItem,
        to desired: Bool? = nil
    ) async -> Bool {
        let target = desired ?? !(item.userData?.isFavorite ?? false)
        do {
            let updated = try await client.setFavorite(target, itemId: item.id)
            // The shelf is now stale; let it reload rather than patching it.
            favorites = .idle
            return updated.isFavorite
        } catch {
            log.error("Could not set favourite: \(error.localizedDescription, privacy: .public)")
            // Report the unchanged value so the glyph snaps back rather than lying.
            return !target
        }
    }

    func search(_ term: String) async throws -> [JellyfinItem] {
        try await acrossLibraries { parentId in
            try await self.client.search(term, parentId: parentId)
        }
    }

    func musicGenres() async throws -> [JellyfinItem] {
        try await acrossLibraries { parentId in
            try await self.client.musicGenres(parentId: parentId)
        }
    }

    func albums(inGenre genreId: String) async throws -> [JellyfinItem] {
        try await acrossLibraries { parentId in
            try await self.client.albums(inGenre: genreId, parentId: parentId)
        }
    }

    /// The signed-in user and server, for Settings.
    var accountSummary: (username: String, server: String) {
        (client.credentials?.username ?? "—", client.serverURL.host() ?? client.serverURL.absoluteString)
    }

    /// One item by id. Spotlight hands back an identifier and nothing else.
    func item(id: String) async throws -> JellyfinItem {
        try await client.item(id: id)
    }

    /// Songs matching a structured query, as built by smart search.
    func songs(matching query: MusicQuery) async throws -> [JellyfinItem] {
        try await client.songs(matching: query)
    }

    /// Artwork for an item we hold only the id of — a playlist cover chosen from the
    /// curation store, where nothing but ids are kept.
    func artworkURL(itemId: String, maxWidth: Int) -> URL? {
        client.artworkURL(itemId: itemId, tag: nil, maxWidth: maxWidth)
    }

    func artworkURL(for item: JellyfinItem, width: Int) -> URL? {
        client.artworkURL(for: item, maxWidth: width)
    }

    // MARK: - Playback

    /// Turns Jellyfin items into tracks and hands them to the engine.
    ///
    /// `source` names where the listener started this from, and is written onto every
    /// play event the queue produces. It defaults to `.unknown` rather than to a
    /// plausible value: a recap built on a guess is wrong in a way nobody can spot.
    func play(
        _ items: [JellyfinItem],
        startingAt index: Int = 0,
        shuffled: Bool = false,
        from source: PlaySource = .unknown
    ) {
        // `index` addresses `items`, but the bridge drops anything that isn't
        // playable — a Jellyfin playlist can hold non-audio entries. Clamping the
        // old index was not enough: one dropped row above the tap made every
        // subsequent tap start the wrong song. The bridge now reports which source
        // rows survived so the position can be translated exactly.
        let mapped = JellyfinPlaybackBridge.playableTracks(from: items, client: client)
        guard !mapped.tracks.isEmpty else { return }
        let start = mapped.sourceIndices.firstIndex { $0 >= index } ?? (mapped.tracks.count - 1)
        PlaybackContext.attributing(source) {
            PlaybackEngine.shared.play(mapped.tracks, startingAt: start, shuffled: shuffled)
        }
    }

    func playNext(_ items: [JellyfinItem], from source: PlaySource = .unknown) {
        let tracks = JellyfinPlaybackBridge.tracks(from: items, client: client)
        PlaybackContext.attributing(source) {
            PlaybackEngine.shared.playNext(tracks)
        }
    }

    func addToQueue(_ items: [JellyfinItem], from source: PlaySource = .unknown) {
        let tracks = JellyfinPlaybackBridge.tracks(from: items, client: client)
        PlaybackContext.attributing(source) {
            PlaybackEngine.shared.addToQueue(tracks)
        }
    }

    // MARK: - Helpers

    private func load<Value>(_ body: @escaping () async throws -> Value) async -> Loadable<Value> {
        do {
            return .loaded(try await body())
        } catch is CancellationError {
            // Back to idle, not failed. SwiftUI cancels `.task` on every disappear,
            // so caching this as an error left whole screens permanently dead after
            // an ordinary tab switch during launch.
            return .idle
        } catch {
            if Task.isCancelled { return .idle }
            if case JellyfinError.unauthorized = error {
                AppSession.shared.invalidateSession()
                return .idle
            }
            let message = (error as? JellyfinError)?.errorDescription ?? error.localizedDescription
            log.error("Library load failed: \(message, privacy: .public)")
            return .failed(message)
        }
    }
}
