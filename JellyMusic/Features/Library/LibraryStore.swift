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

    init(client: JellyfinClient) {
        self.client = client
    }

    // MARK: - Loading

    func loadAlbumsIfNeeded() async {
        guard case .idle = albums else { return }
        albums = .loading
        albums = await load { try await self.client.albums(sort: .name).items }
    }

    func loadArtistsIfNeeded() async {
        guard case .idle = artists else { return }
        artists = .loading
        artists = await load { try await self.client.albumArtists().items }
    }

    func loadPlaylistsIfNeeded() async {
        guard case .idle = playlists else { return }
        playlists = .loading
        playlists = await load { try await self.client.playlists() }
    }

    func loadRecentlyAddedIfNeeded() async {
        guard case .idle = recentlyAdded else { return }
        recentlyAdded = .loading
        recentlyAdded = await load { try await self.client.recentlyAdded(limit: 20) }
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
        try await client.search(term)
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
