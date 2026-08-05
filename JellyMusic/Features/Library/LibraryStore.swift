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

    /// Album tracks, keyed by album id, so reopening an album is instant.
    private var trackCache: [String: [JellyfinItem]] = [:]

    private let client: JellyfinClient
    private let log = Logger(subsystem: "com.example.jellymusic", category: "library")

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
            // Falling back to unscoped is worse but still functional — better than
            // an empty library because one request failed.
            log.error("Could not resolve music libraries, querying unscoped: \(error.localizedDescription, privacy: .public)")
            musicLibraryIds = []
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

    func loadAlbumsIfNeeded() async {
        guard case .idle = albums else { return }
        albums = .loading
        albums = await load {
            try await self.acrossLibraries { parentId in
                try await self.client.albums(parentId: parentId, sort: .name).items
            }
        }
    }

    func loadArtistsIfNeeded() async {
        guard case .idle = artists else { return }
        artists = .loading
        artists = await load {
            try await self.acrossLibraries { parentId in
                try await self.client.albumArtists(parentId: parentId).items
            }
        }
    }

    func loadPlaylistsIfNeeded() async {
        guard case .idle = playlists else { return }
        playlists = .loading
        playlists = await load { try await self.client.playlists() }
    }

    func loadRecentlyAddedIfNeeded() async {
        guard case .idle = recentlyAdded else { return }
        recentlyAdded = .loading
        recentlyAdded = await load {
            try await self.acrossLibraries { parentId in
                try await self.client.recentlyAdded(parentId: parentId, limit: 20)
            }
        }
    }

    /// Pull to refresh — drops every cache and reloads what's on screen.
    func refresh() async {
        trackCache.removeAll()
        albums = .idle
        artists = .idle
        playlists = .idle
        recentlyAdded = .idle
        await loadRecentlyAddedIfNeeded()
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

    func search(_ term: String) async throws -> [JellyfinItem] {
        try await acrossLibraries { parentId in
            try await self.client.search(term, parentId: parentId)
        }
    }

    func artworkURL(for item: JellyfinItem, width: Int) -> URL? {
        client.artworkURL(for: item, maxWidth: width)
    }

    // MARK: - Playback

    /// Turns Jellyfin items into tracks and hands them to the engine.
    func play(_ items: [JellyfinItem], startingAt index: Int = 0, shuffled: Bool = false) {
        let tracks = JellyfinPlaybackBridge.tracks(from: items, client: client)
        guard !tracks.isEmpty else { return }
        // The index refers to `items`; if anything was filtered out (a non-audio
        // entry in a playlist) the positions would no longer line up.
        let adjusted = min(index, tracks.count - 1)
        PlaybackEngine.shared.play(tracks, startingAt: adjusted, shuffled: shuffled)
    }

    func playNext(_ items: [JellyfinItem]) {
        PlaybackEngine.shared.playNext(JellyfinPlaybackBridge.tracks(from: items, client: client))
    }

    func addToQueue(_ items: [JellyfinItem]) {
        PlaybackEngine.shared.addToQueue(JellyfinPlaybackBridge.tracks(from: items, client: client))
    }

    // MARK: - Helpers

    private func load<Value>(_ body: @escaping () async throws -> Value) async -> Loadable<Value> {
        do {
            return .loaded(try await body())
        } catch {
            let message = (error as? JellyfinError)?.errorDescription ?? error.localizedDescription
            log.error("Library load failed: \(message, privacy: .public)")
            return .failed(message)
        }
    }
}
