import CarPlay
import JellyfinKit
import PlaybackKit
import UIKit
import os

/// Builds the car's browse hierarchy from the Jellyfin library.
///
/// Deliberately separate from `LibraryStore`: that one belongs to the phone's view
/// hierarchy, and CarPlay is a different scene that can connect before the phone UI
/// has ever been created. This reads the shared session directly and drives the
/// shared ``PlaybackEngine``, so the two screens can never disagree about what is
/// playing.
@MainActor
final class CarPlayBrowser: NSObject {
    private let log = Logger(subsystem: "com.example.jellymusic", category: "carplay")

    /// Artwork small enough to be cheap over a phone's connection while the car is
    /// moving, and larger than any row CarPlay draws.
    private let artworkWidth = 200

    private var client: JellyfinClient? { AppSession.shared.client }

    /// Music library ids, resolved once per connection.
    private var scope: [String]?

    override init() { super.init() }

    // MARK: - Root

    func makeRootTemplate() -> CPTemplate {
        guard AppSession.shared.client != nil else { return signedOutTemplate() }

        // Only browsable templates may be tabs. `CPSearchTemplate` is not one —
        // `validateTemplates:` throws an Objective-C exception that Swift cannot
        // catch, so this has to be right rather than guarded. Search is reached
        // from a bar button on the Library tab instead, which is the intended
        // pattern anyway.
        var tabs: [CPTemplate] = [
            libraryTemplate(),
            recentlyPlayedTemplate(),
        ]

        // The car decides how many tabs it will show, and exceeding it throws
        // rather than truncating. The granted entitlement can change this number,
        // so it is read at runtime rather than assumed.
        let limit = CPTabBarTemplate.maximumTabCount
        if tabs.count > limit { tabs = Array(tabs.prefix(limit)) }

        return CPTabBarTemplate(templates: tabs)
    }

    private func signedOutTemplate() -> CPTemplate {
        // CarPlay forbids text entry while driving and there is no way to sign in
        // from here, so say plainly what has to happen rather than showing an
        // empty list.
        let template = CPInformationTemplate(
            title: "JellyMusic",
            layout: .leading,
            items: [
                CPInformationItem(
                    title: "Not signed in",
                    detail: "Open JellyMusic on your iPhone to connect to your Jellyfin server."
                )
            ],
            actions: []
        )
        template.tabTitle = "JellyMusic"
        return template
    }

    // MARK: - Library tab

    private func libraryTemplate() -> CPListTemplate {
        let rows: [(String, String, () -> Void)] = [
            ("Playlists", "music.note.list", { [weak self] in self?.pushPlaylists() }),
            ("Artists", "music.microphone", { [weak self] in self?.pushArtists() }),
            ("Albums", "square.stack", { [weak self] in self?.pushAlbums() }),
            ("Songs", "music.note", { [weak self] in self?.pushSongs() }),
        ]

        let items = rows.map { title, symbol, action -> CPListItem in
            let item = CPListItem(text: title, detailText: nil, image: UIImage(systemName: symbol))
            item.handler = { _, completion in
                action()
                completion()
            }
            return item
        }

        let template = CPListTemplate(title: "Library", sections: [CPListSection(items: items)])
        template.tabTitle = "Library"
        template.tabImage = UIImage(systemName: "music.note.list")

        // Search lives here rather than in a tab. The car disables the keyboard
        // while moving on its own, so this is only usable parked — which is the
        // behaviour we want and don't have to implement.
        let search = CPBarButton(image: UIImage(systemName: "magnifyingglass") ?? UIImage()) { [weak self] _ in
            guard let self else { return }
            CarPlayNowPlaying.shared.push(self.searchTemplate())
        }
        template.trailingNavigationBarButtons = [search]
        return template
    }

    private func recentlyPlayedTemplate() -> CPListTemplate {
        let template = CPListTemplate(title: "Recently Played", sections: [])
        template.tabTitle = "Recent"
        template.tabImage = UIImage(systemName: "clock")
        template.emptyViewSubtitleVariants = ["Music you play will show up here."]

        // Filled asynchronously — the tab must exist before its contents do, or the
        // tab bar can't be built at connection time.
        Task { [weak self, weak template] in
            guard let self, let template else { return }
            let albums = await self.fetch { client, parent in
                try await client.recentlyPlayedAlbums(parentId: parent, limit: 40)
            }
            template.updateSections([CPListSection(items: self.albumItems(albums))])
        }
        return template
    }

    private func searchTemplate() -> CPSearchTemplate {
        let template = CPSearchTemplate()
        template.delegate = self
        return template
    }

    // MARK: - Pushed lists

    private func pushAlbums() {
        pushList(title: "Albums", empty: "No albums in your library.") { [weak self] in
            guard let self else { return [] }
            let albums = await self.fetch { client, parent in
                try await client.albums(parentId: parent, sort: .name, limit: Self.pageLimit).items
            }
            return self.albumItems(albums)
        }
    }

    private func pushArtists() {
        pushList(title: "Artists", empty: "No artists in your library.") { [weak self] in
            guard let self else { return [] }
            let artists = await self.fetch { client, parent in
                try await client.albumArtists(parentId: parent, limit: Self.pageLimit).items
            }
            return artists.map { artist in
                let item = CPListItem(text: artist.name, detailText: nil)
                self.loadArtwork(for: artist, into: item)
                item.handler = { [weak self] _, completion in
                    self?.pushArtistAlbums(artist)
                    completion()
                }
                return item
            }
        }
    }

    private func pushArtistAlbums(_ artist: JellyfinItem) {
        pushList(title: artist.name, empty: "No albums by this artist.") { [weak self] in
            guard let self, let client = self.client else { return [] }
            let albums = (try? await client.albums(byArtist: artist.id)) ?? []
            return self.albumItems(albums)
        }
    }

    private func pushSongs() {
        pushList(title: "Songs", empty: "No songs in your library.") { [weak self] in
            guard let self else { return [] }
            let songs = await self.fetch { client, parent in
                try await client.songs(parentId: parent, sort: .name, limit: Self.pageLimit).items
            }
            return self.trackItems(songs)
        }
    }

    private func pushPlaylists() {
        pushList(title: "Playlists", empty: "No playlists on your server.") { [weak self] in
            guard let self, let client = self.client else { return [] }
            let playlists = (try? await client.playlists()) ?? []
            return playlists.map { playlist in
                let item = CPListItem(text: playlist.name, detailText: playlist.subtitle)
                self.loadArtwork(for: playlist, into: item)
                item.handler = { [weak self] _, completion in
                    self?.pushPlaylistTracks(playlist)
                    completion()
                }
                return item
            }
        }
    }

    private func pushPlaylistTracks(_ playlist: JellyfinItem) {
        pushList(title: playlist.name, empty: "This playlist is empty.") { [weak self] in
            guard let self, let client = self.client else { return [] }
            let tracks = (try? await client.tracks(inPlaylist: playlist.id)) ?? []
            return self.trackItems(tracks)
        }
    }

    private func pushAlbumTracks(_ album: JellyfinItem) {
        pushList(title: album.name, empty: "This album is empty.") { [weak self] in
            guard let self, let client = self.client else { return [] }
            let tracks = (try? await client.tracks(inAlbum: album.id)) ?? []
            return self.trackItems(tracks)
        }
    }

    // MARK: - Items

    private func albumItems(_ albums: [JellyfinItem]) -> [CPListItem] {
        albums.map { album in
            let item = CPListItem(text: album.name, detailText: album.subtitle)
            loadArtwork(for: album, into: item)
            item.handler = { [weak self] _, completion in
                self?.pushAlbumTracks(album)
                completion()
            }
            return item
        }
    }

    /// Tapping a song plays from there through the rest of the list, which is what
    /// it means everywhere else in the app.
    private func trackItems(_ tracks: [JellyfinItem]) -> [CPListItem] {
        tracks.enumerated().map { index, track in
            let item = CPListItem(text: track.name, detailText: track.subtitle)
            loadArtwork(for: track, into: item)
            item.handler = { [weak self] _, completion in
                self?.play(tracks, startingAt: index)
                completion()
            }
            return item
        }
    }

    private func play(_ items: [JellyfinItem], startingAt index: Int) {
        guard let client else { return }
        let mapped = JellyfinPlaybackBridge.playableTracks(from: items, client: client)
        guard !mapped.tracks.isEmpty else { return }
        let start = mapped.sourceIndices.firstIndex { $0 >= index } ?? (mapped.tracks.count - 1)
        PlaybackEngine.shared.play(mapped.tracks, startingAt: start)
        CarPlayNowPlaying.shared.present()
    }

    private func loadArtwork(for item: JellyfinItem, into row: CPListItem) {
        guard let client, let url = client.artworkURL(for: item, maxWidth: artworkWidth) else { return }
        Task { [weak row] in
            guard let image = await ArtworkCache.shared.image(for: url) else { return }
            row?.setImage(image)
        }
    }

    // MARK: - Plumbing

    /// CarPlay refuses more than this many rows and shows only the first ones, so
    /// there is no point fetching more. Read at runtime — it varies by head unit.
    private static var pageLimit: Int { CPListTemplate.maximumItemCount }

    /// Pushes a list immediately, then fills it.
    ///
    /// Fetching first would leave the car showing the previous screen for however
    /// long the request takes, which on a phone connection in a moving vehicle can
    /// be seconds — it reads as a dead tap.
    private func pushList(
        title: String,
        empty: String,
        load: @escaping @MainActor () async -> [CPListItem]
    ) {
        let template = CPListTemplate(title: title, sections: [])
        template.emptyViewSubtitleVariants = [empty]

        CarPlayNowPlaying.shared.push(template)

        Task { [weak template] in
            let items = await load()
            guard let template else { return }
            let clamped = Array(items.prefix(CPListTemplate.maximumItemCount))
            if clamped.count < items.count {
                log.notice("Trimmed \(items.count - clamped.count, privacy: .public) rows to CarPlay's limit")
            }
            template.updateSections([CPListSection(items: clamped)])
        }
    }

    /// Runs a query scoped to the music libraries, resolving them once per session.
    private func fetch(
        _ body: @escaping (JellyfinClient, String?) async throws -> [JellyfinItem]
    ) async -> [JellyfinItem] {
        guard let client else { return [] }
        do {
            if scope == nil {
                scope = try? await client.musicLibraries().map(\.id)
            }
            return try await body(client, scope?.first)
        } catch {
            log.error("CarPlay query failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }
}

// MARK: - Search

extension CarPlayBrowser: @preconcurrency CPSearchTemplateDelegate {
    func searchTemplate(
        _ searchTemplate: CPSearchTemplate,
        updatedSearchText searchText: String,
        completionHandler: @escaping ([CPListItem]) -> Void
    ) {
        Task { [weak self] in
            guard let self, let client = self.client else {
                completionHandler([])
                return
            }
            let trimmed = searchText.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else {
                completionHandler([])
                return
            }

            if scope == nil { scope = try? await client.musicLibraries().map(\.id) }
            let results = (try? await client.search(trimmed, parentId: scope?.first, limit: 40)) ?? []

            // Songs first: on a car screen the thing you searched for is almost
            // always something to play right now, not something to browse into.
            let songs = results.filter { $0.type == .audio }
            let albums = results.filter { $0.type == .musicAlbum }
            completionHandler(self.trackItems(songs) + self.albumItems(albums))
        }
    }

    func searchTemplate(
        _ searchTemplate: CPSearchTemplate,
        selectedResult item: CPListItem,
        completionHandler: @escaping () -> Void
    ) {
        // The row's own handler already did the work.
        item.handler?(item) { completionHandler() }
    }
}
