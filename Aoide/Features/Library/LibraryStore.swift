import CurationKit
import Foundation
import MeleteKit
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

    private(set) var albums: Loadable<[MusicItem]> = .idle
    private(set) var artists: Loadable<[MusicItem]> = .idle
    private(set) var recentlyAdded: Loadable<[MusicItem]> = .idle

    // Home shelves. Each is independent so one failing server query leaves the
    // rest of the page intact rather than blanking it.
    private(set) var recentlyPlayed: Loadable<[MusicItem]> = .idle
    private(set) var mostPlayed: Loadable<[MusicItem]> = .idle
    /// The albums of the songs the listener likes: Melete keeps likes on songs.
    private(set) var favorites: Loadable<[MusicItem]> = .idle

    /// Album tracks, keyed by album id, so reopening an album is instant.
    private var trackCache: [String: [MusicItem]] = [:]

    private let client: MeleteClient
    private let log = Logger(subsystem: AppIdentity.bundle, category: "library")

    /// Melete's Home view while it is being fetched, so the three shelves it fills
    /// ask for it once.
    private var homeFetch: Task<MusicHome, any Error>?

    init(client: MeleteClient) {
        self.client = client
    }

    // MARK: - Loading

    func loadAlbumsIfNeeded() async { await fill(\.albums, with: fetchAlbums) }
    func loadArtistsIfNeeded() async { await fill(\.artists, with: fetchArtists) }
    func loadRecentlyAddedIfNeeded() async { await fill(\.recentlyAdded, with: fetchRecentlyAdded) }
    func loadRecentlyPlayedIfNeeded() async { await fill(\.recentlyPlayed, with: fetchRecentlyPlayed) }
    func loadMostPlayedIfNeeded() async { await fill(\.mostPlayed, with: fetchMostPlayed) }
    func loadFavoritesIfNeeded() async { await fill(\.favorites, with: fetchFavorites) }

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
            { await self.replace(\.recentlyAdded, with: self.fetchRecentlyAdded) },
            { await self.replace(\.recentlyPlayed, with: self.fetchRecentlyPlayed) },
            { await self.replace(\.mostPlayed, with: self.fetchMostPlayed) },
            { await self.replace(\.favorites, with: self.fetchFavorites) },
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

    private func fetchAlbums() async throws -> [MusicItem] {
        try await client.albums(sort: .name).items
    }

    private func fetchArtists() async throws -> [MusicItem] {
        try await client.albumArtists().items
    }

    /// Melete's Home view, asked for once however many shelves want it.
    private func home() async throws -> MusicHome {
        if let homeFetch { return try await homeFetch.value }
        let fetch = Task { [client] in try await client.home() }
        homeFetch = fetch
        defer { homeFetch = nil }
        return try await fetch.value
    }

    private func fetchRecentlyAdded() async throws -> [MusicItem] {
        try await home().recentlyAdded
    }

    private func fetchRecentlyPlayed() async throws -> [MusicItem] {
        try await home().recentlyPlayed
    }

    /// The albums of the songs played most in the last 30 days, on every device.
    private func fetchMostPlayed() async throws -> [MusicItem] {
        Self.albums(of: try await home().mostPlayed.map(\.track), limit: 20)
    }

    private func fetchFavorites() async throws -> [MusicItem] {
        Self.albums(of: try await client.likedTracks(), limit: 20)
    }

    /// The albums `tracks` are on, each once, in the order first met.
    static func albums(of tracks: [MusicItem], limit: Int) -> [MusicItem] {
        var seen = Set<String>()
        return tracks.compactMap { track -> MusicItem? in
            guard let albumId = track.albumId, seen.insert(albumId).inserted else { return nil }
            return MusicItem(
                id: albumId, name: track.album ?? track.name, type: .musicAlbum,
                albumId: albumId, albumArtist: track.albumArtist, hasCover: track.hasCover
            )
        }
        .prefix(limit)
        .map { $0 }
    }

    /// Pull to refresh — drops every cache and reloads what's on screen.
    func refresh() async {
        lastRefresh = Date()
        trackCache.removeAll()
        albums = .idle
        artists = .idle
        recentlyAdded = .idle
        recentlyPlayed = .idle
        mostPlayed = .idle
        favorites = .idle
        await loadHomeIfNeeded()
        await loadAlbumsIfNeeded()
    }

    func tracks(inAlbum albumId: String) async throws -> [MusicItem] {
        if let cached = trackCache[albumId] { return cached }
        let tracks = try await client.tracks(inAlbum: albumId)
        trackCache[albumId] = tracks
        return tracks
    }

    func albums(byArtist artistId: String) async throws -> [MusicItem] {
        try await client.albums(byArtist: artistId)
    }

    // MARK: - Paged lists

    /// A fresh paged list is built per sort order rather than re-sorting in memory,
    /// because only the first page is loaded and the rest of the ordering lives on
    /// the server.
    func albumsPage(sort: ItemSort) -> PagedItems {
        PagedItems { [weak self] startIndex, limit in
            guard let self else { return ItemsResponse.empty }
            return try await self.client.albums(
                sort: sort,
                direction: sort.naturalDirection,
                startIndex: startIndex,
                limit: limit
            )
        }
    }

    func artistsPage() -> PagedItems {
        PagedItems { [weak self] startIndex, limit in
            guard let self else { return ItemsResponse.empty }
            return try await self.client.albumArtists(startIndex: startIndex, limit: limit)
        }
    }

    func songsPage(sort: ItemSort) -> PagedItems {
        PagedItems { [weak self] startIndex, limit in
            guard let self else { return ItemsResponse.empty }
            return try await self.client.songs(
                sort: sort,
                direction: sort.naturalDirection,
                startIndex: startIndex,
                limit: limit
            )
        }
    }

    /// One page of songs for the index, by title, so the paging is stable from the
    /// first page to the last.
    func songsBatch(startIndex: Int, limit: Int) async throws -> ItemsResponse {
        try await client.songs(sort: .name, direction: .ascending, startIndex: startIndex, limit: limit)
    }

    // MARK: - Downloads

    /// The store needs a client to build stream URLs, and the client lives here.
    /// Files superseded by a converted copy are deleted once no queue names them.
    /// Every queue change passes through here, so this is where that is checked.
    private func queueDidChange() {
        DownloadStore.shared.sweepRetired()
        // Bounds for what is queued, so a streamed track is trimmed like a
        // downloaded one. Answers land before the engine makes the item, most of
        // the time; the first track of a fresh queue may play whole once.
        let queued = PlaybackEngine.shared.queue.entries.map(\.track.id)
        SoundBoundsSync.shared.prefetch(ids: queued)
        AudioAnalysisSync.shared.prefetch(ids: queued)
        BeatGridSync.shared.prefetch(ids: queued)
        ArrangementSync.shared.prefetch(ids: queued)
        let engineQueue = PlaybackEngine.shared.queue
        TransientTracks.shared.prepare(([engineQueue.current].compactMap { $0 } + engineQueue.upNext).map(\.track))
    }

    func download(_ items: [MusicItem], in collection: DownloadedCollection? = nil) {
        // Written before the transfer starts, not after: offline, the server cannot
        // be asked what a downloaded file contains, so the metadata must already be
        // on disk or the Downloaded screen is a list of identifiers.
        DownloadIndex.shared.record(items)
        if let collection { DownloadIndex.shared.record(collection) }
        DownloadStore.shared.download(items, client: client)
    }

    // MARK: - Playback shortcuts

    func playAlbum(_ album: MusicItem, shuffled: Bool = false) async {
        guard let tracks = try? await tracks(inAlbum: album.id) else { return }
        // `.album` whether or not it was shuffled. Shuffle is how the album is being
        // played, not where it came from, and `.shuffle` is reserved for a queue the
        // app assembled with no collection behind it at all.
        play(tracks, shuffled: shuffled, from: .album)
        remember(RecentContext(
            kind: .album, id: album.id, name: album.name,
            subtitle: album.albumArtist ?? album.artists.first, artworkItemId: album.id,
            lastOpened: Date().millis
        ))
    }

    func queueAlbum(_ album: MusicItem, next: Bool) async {
        guard let tracks = try? await tracks(inAlbum: album.id) else { return }
        if next { playNext(tracks, from: .album) } else { addToQueue(tracks, from: .album) }
    }

    /// Shuffle the whole library.
    ///
    /// Samples the library at random places rather than fetching everything and
    /// shuffling locally — on a large library that would be a very long wait for
    /// what is meant to be an instant action.
    func shuffleEverything(limit: Int = 300) async {
        do {
            let tracks = try await client.randomSongs(count: limit)
            let wanted = await TasteStore.shared.withoutNotInterested(tracks)
            guard !wanted.isEmpty else { return }
            // The one true `.shuffle`: a queue with no album, playlist or search behind
            // it, assembled because the listener asked for anything at all.
            play(wanted, from: .shuffle)
        } catch {
            log.error("Could not shuffle library: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// A station seeded from any track, album or artist (see ``Station``). The
    /// closest thing a personal library has to Apple Music's radio.
    func startStation(seededBy item: MusicItem) async {
        await startStation(seededById: Station.seed(for: item), named: item.name, artworkItemId: item.coverAlbumId)
    }

    /// `id` is a station's seed as ``Station/seed(for:)`` writes it.
    func startStation(seededById id: String, named name: String, artworkItemId: String?) async {
        do {
            let mix = try await Station.tracks(seed: id, client: client)
            // Left `.unknown`: a station is none of the sources the schema has a word
            // for, and filing it under the nearest one would put songs nobody chose
            // into the recap's "you played this album a lot".
            play(mix)
            remember(RecentContext(kind: .station, id: id, name: "\(name) Station", artworkItemId: artworkItemId, lastOpened: Date().millis))
        } catch {
            log.error("Could not start station: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Notes something the listener started a session from, for Home to offer again.
    func remember(_ context: RecentContext) {
        RecentContextStore.shared.remember(context)
    }

    func items(ids: [String]) async throws -> [MusicItem] {
        try await client.items(ids: ids)
    }

    /// Likes or unlikes a song in Melete, which writes it into the sync log as a
    /// device of this listener's would; the local store sees it on its next pull.
    /// `desired` is the intent, not a derivation. Deriving it from `item.liked`
    /// read a snapshot captured when the list was fetched, so a second tap sent the
    /// same value again and un-liking was impossible.
    @discardableResult
    func toggleFavorite(
        _ item: MusicItem,
        to desired: Bool? = nil
    ) async -> Bool {
        let target = desired ?? !item.liked
        do {
            try await client.setLiked(target, trackId: item.id)
            // The shelf is now stale; let it reload rather than patching it.
            favorites = .idle
            return target
        } catch {
            log.error("Could not set favourite: \(error.localizedDescription, privacy: .public)")
            // Report the unchanged value so the glyph snaps back rather than lying.
            return !target
        }
    }

    func search(_ term: String) async throws -> [MusicItem] {
        try await client.search(term)
    }

    func musicGenres() async throws -> [MusicItem] {
        try await client.musicGenres()
    }

    func albums(inGenre genre: String) async throws -> [MusicItem] {
        try await client.albums(inGenre: genre)
    }

    /// The signed-in user and server, for Settings.
    var accountSummary: (username: String, server: String) {
        (client.credentials?.username ?? "—", client.serverURL.host() ?? client.serverURL.absoluteString)
    }

    /// What a Spotlight entry names: `album:…` or `artist:…`, as the indexer
    /// writes them. An entry from before Melete names neither, and opens nothing.
    func spotlightItem(id: String) async throws -> MusicItem? {
        let parts = id.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        switch parts[0] {
        case "album": return try await client.album(id: parts[1]).album
        case "artist": return try await client.artist(id: parts[1])
        default: return nil
        }
    }

    /// Songs matching a structured query, as built by smart search.
    func songs(matching query: MusicQuery) async throws -> [MusicItem] {
        try await client.songs(matching: query)
    }

    /// The cover of an album we hold only the id of — a playlist's or a resume
    /// tile's, where nothing but ids are kept.
    func artworkURL(itemId albumId: String, maxWidth: Int) -> URL? {
        client.artworkURL(itemId: albumId)
    }

    func artworkURL(for item: MusicItem, width: Int) -> URL? {
        client.artworkURL(for: item, maxWidth: width)
    }

    // MARK: - Playback

    /// Turns Melete's tracks into the player's and hands them to the engine.
    ///
    /// `source` names where the listener started this from, and is written onto every
    /// play event the queue produces. It defaults to `.unknown` rather than to a
    /// plausible value: a recap built on a guess is wrong in a way nobody can spot.
    func play(
        _ items: [MusicItem],
        startingAt index: Int = 0,
        shuffled: Bool = false,
        from source: PlaySource = .unknown
    ) {
        // `index` addresses `items`, but the bridge drops anything that isn't
        // playable — a list can hold non-audio entries. Clamping the
        // old index was not enough: one dropped row above the tap made every
        // subsequent tap start the wrong song. The bridge now reports which source
        // rows survived so the position can be translated exactly.
        let mapped = MeletePlaybackBridge.playableTracks(from: items, client: client)
        guard !mapped.tracks.isEmpty else { return }
        let start = mapped.sourceIndices.firstIndex { $0 >= index } ?? (mapped.tracks.count - 1)
        PlaybackContext.attributing(source) {
            PlaybackEngine.shared.play(mapped.tracks, startingAt: start, shuffled: shuffled)
            queueDidChange()
        }
    }

    func playNext(_ items: [MusicItem], from source: PlaySource = .unknown) {
        let tracks = MeletePlaybackBridge.tracks(from: items, client: client)
        PlaybackContext.attributing(source) {
            PlaybackEngine.shared.playNext(tracks)
        }
        queueDidChange()
    }

    func addToQueue(_ items: [MusicItem], from source: PlaySource = .unknown) {
        let tracks = MeletePlaybackBridge.tracks(from: items, client: client)
        PlaybackContext.attributing(source) {
            PlaybackEngine.shared.addToQueue(tracks)
        }
        queueDidChange()
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
            if case MeleteError.unauthorized = error {
                AppSession.shared.invalidateSession()
                return .idle
            }
            let message = (error as? MeleteError)?.errorDescription ?? error.localizedDescription
            log.error("Library load failed: \(message, privacy: .public)")
            return .failed(message)
        }
    }
}
