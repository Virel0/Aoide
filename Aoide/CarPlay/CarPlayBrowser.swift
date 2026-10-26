import CarPlay
import CurationKit
import JellyfinKit
import PlaybackKit
import UIKit
import os

/// Builds the car's screens.
///
/// Deliberately separate from `LibraryStore`: that one belongs to the phone's view
/// hierarchy, and CarPlay is a different scene that can connect before the phone UI
/// has ever been created. This reads the shared session directly and drives the
/// shared ``PlaybackEngine``, so the two screens can never disagree about what is
/// playing.
///
/// The shape follows one rule: **the car is a playback and resume surface, not a
/// discovery surface.** Home is the last things you were in, a queue another
/// device put down, and the named mixes — every row one tap from sound. Library
/// keeps the browse lists for a parked moment, with the playlists kept on this
/// phone first and tapping one playing it whole, because three levels of list in
/// a moving car is the thing the platform is worst at.
@MainActor
final class CarPlayBrowser: NSObject {
    private let log = Logger(subsystem: AppIdentity.bundle, category: "carplay")

    /// Artwork small enough to be cheap over a phone's connection while the car is
    /// moving, and larger than any row CarPlay draws.
    private let artworkWidth = 200

    private var client: JellyfinClient? { AppSession.shared.client }

    /// Music library ids, resolved once per connection.
    private var scope: [String]?

    /// The phone's own playlists, read from the same store the phone screen reads.
    private lazy var playlists: LocalPlaylistStore? = client.map { LocalPlaylistStore(client: $0) }

    private weak var homeTemplate: CPListTemplate?

    override init() { super.init() }

    // MARK: - Root

    func makeRootTemplate() -> CPTemplate {
        guard AppSession.shared.client != nil else { return signedOutTemplate() }

        // Only browsable templates may be tabs. `CPSearchTemplate` is not one —
        // `validateTemplates:` throws an Objective-C exception that Swift cannot
        // catch, so this has to be right rather than guarded. Search is reached
        // from a bar button on the Library tab instead.
        var tabs: [CPTemplate] = [
            makeHomeTemplate(),
            libraryTemplate(),
        ]
        let limit = CPTabBarTemplate.maximumTabCount
        if tabs.count > limit { tabs = Array(tabs.prefix(limit)) }
        return CPTabBarTemplate(templates: tabs)
    }

    private func signedOutTemplate() -> CPTemplate {
        // CarPlay forbids text entry while driving and there is no way to sign in
        // from here, so say plainly what has to happen rather than showing an
        // empty list.
        let template = CPInformationTemplate(
            title: "Aoide",
            layout: .leading,
            items: [
                CPInformationItem(
                    title: "Not signed in",
                    detail: "Open Aoide on your iPhone to connect to your Jellyfin server."
                )
            ],
            actions: []
        )
        template.tabTitle = "Aoide"
        return template
    }

    // MARK: - Home

    private func makeHomeTemplate() -> CPListTemplate {
        let template = CPListTemplate(title: "Home", sections: [])
        template.tabTitle = "Home"
        template.tabImage = UIImage(systemName: "house")
        template.emptyViewSubtitleVariants = ["Play something on your iPhone and it'll be here, one tap away."]
        homeTemplate = template
        Task { await self.fillHome() }
        return template
    }

    /// Rebuilt after anything starts playing, so the row order follows the drive.
    func refreshHome() {
        Task { await self.fillHome() }
    }

    private func fillHome() async {
        guard let template = homeTemplate else { return }
        var sections: [CPListSection] = []

        // A queue another device put down more recently than anything here: the
        // thing most likely wanted on getting into the car.
        if let handoff = await resumableQueue() {
            let item = CPListItem(
                text: "Pick up from \(handoff.deviceName)",
                detailText: "\(handoff.trackIdList.count) tracks",
                image: UIImage(systemName: "arrow.down.left.circle.fill")
            )
            item.handler = { [weak self] _, completion in
                Task { await self?.pickUp(handoff); completion() }
            }
            sections.append(CPListSection(items: [item], header: "Continue", sectionIndexTitle: nil))
        }

        // The last things you were in, each one tap from playing. These are the
        // car's pins: the platform's own answer to lists that were never enough.
        let recents = RecentContextStore.shared.list.latest(6)
        if !recents.isEmpty {
            let items = recents.map { context -> CPListItem in
                let item = CPListItem(text: context.name, detailText: context.subtitle ?? kindLabel(context.kind))
                if let artworkId = context.artworkItemId { loadArtwork(itemId: artworkId, into: item) }
                item.handler = { [weak self] _, completion in
                    Task { await self?.resume(context); completion() }
                }
                return item
            }
            sections.append(CPListSection(items: items, header: "Recent", sectionIndexTitle: nil))
        }

        // The named mixes, and the one true shuffle. Each plays on the tap.
        var quick: [CPListItem] = []
        if let playlists {
            await playlists.reload()
            for built in BuiltInPlaylist.allCases {
                guard let list = playlists.playlists.first(where: { $0.id == built.id }) else { continue }
                let item = CPListItem(text: list.name, detailText: "Mix", image: UIImage(systemName: "wand.and.stars"))
                item.handler = { [weak self] _, completion in
                    Task { await self?.play(localPlaylist: list); completion() }
                }
                quick.append(item)
            }
        }
        let shuffle = CPListItem(text: "Shuffle Everything", detailText: nil, image: UIImage(systemName: "shuffle"))
        shuffle.handler = { [weak self] _, completion in
            Task { await self?.shuffleEverything(); completion() }
        }
        quick.append(shuffle)
        sections.append(CPListSection(items: quick, header: "Mixes", sectionIndexTitle: nil))

        template.updateSections(sections)
    }

    private func kindLabel(_ kind: RecentContext.Kind) -> String {
        switch kind {
        case .album: "Album"
        case .jellyfinPlaylist, .localPlaylist: "Playlist"
        case .station: "Station"
        }
    }

    // MARK: - Library tab

    private func libraryTemplate() -> CPListTemplate {
        let rows: [(String, String, () -> Void)] = [
            ("Playlists", "music.note.list", { [weak self] in self?.pushPlaylists() }),
            ("Downloads", "arrow.down.circle", { [weak self] in self?.pushDownloads() }),
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
        // behaviour we want and don't have to implement. Siri is the search while
        // driving.
        let search = CPBarButton(image: UIImage(systemName: "magnifyingglass") ?? UIImage()) { [weak self] _ in
            guard let self else { return }
            CarPlayNowPlaying.shared.push(self.searchTemplate())
        }
        template.trailingNavigationBarButtons = [search]
        return template
    }

    private func searchTemplate() -> CPSearchTemplate {
        let template = CPSearchTemplate()
        template.delegate = self
        return template
    }

    // MARK: - Pushed lists

    /// The phone's own playlists first, each playing on the tap; the server's
    /// after, browsed into, because a server playlist can hold things the car
    /// cannot play and deserves a look before it starts.
    private func pushPlaylists() {
        pushList(title: "Playlists", empty: "No playlists yet.") { [weak self] in
            guard let self else { return [] }
            var sections: [CPListSection] = []

            if let playlists = self.playlists {
                await playlists.reload()
                let mine = playlists.playlists(in: nil)
                if !mine.isEmpty {
                    let items = mine.map { list -> CPListItem in
                        let item = CPListItem(
                            text: list.name,
                            detailText: list.isSmart ? "Smart playlist" : nil,
                            image: UIImage(systemName: list.isSmart ? "wand.and.stars" : "music.note.list")
                        )
                        if let artworkId = list.artworkItemId { self.loadArtwork(itemId: artworkId, into: item) }
                        item.handler = { [weak self] _, completion in
                            Task { await self?.play(localPlaylist: list); completion() }
                        }
                        return item
                    }
                    sections.append(CPListSection(items: items, header: "My Playlists", sectionIndexTitle: nil))
                }
            }

            if let client = self.client, let server = try? await client.playlists(), !server.isEmpty {
                let items = server.map { playlist -> CPListItem in
                    let item = CPListItem(text: playlist.name, detailText: playlist.subtitle)
                    self.loadArtwork(for: playlist, into: item)
                    item.handler = { [weak self] _, completion in
                        self?.pushPlaylistTracks(playlist)
                        completion()
                    }
                    return item
                }
                sections.append(CPListSection(items: items, header: "On Your Server", sectionIndexTitle: nil))
            }
            return sections
        }
    }

    /// What is on the phone, which is what plays with no signal at all. Albums and
    /// playlists as one row each, songs below, exactly as the phone files them.
    private func pushDownloads() {
        pushList(title: "Downloads", empty: "Nothing downloaded. Download an album on your iPhone and it plays here without a signal.") { [weak self] in
            guard let self else { return [] }
            let downloads = DownloadStore.shared
            let index = DownloadIndex.shared
            let present = index.tracks.filter { downloads.state(for: $0.id).isPresent }
            let byId = Dictionary(present.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

            var sections: [CPListSection] = []
            let collections = index.collections
                .filter { $0.trackIds.contains(where: { byId[$0] != nil }) }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            if !collections.isEmpty {
                let items = collections.map { collection -> CPListItem in
                    let tracks = collection.trackIds.compactMap { byId[$0] }
                    let item = CPListItem(
                        text: collection.name,
                        detailText: collection.subtitle ?? "\(tracks.count) songs",
                        image: UIImage(systemName: collection.kind == .album ? "square.stack" : "music.note.list")
                    )
                    if let first = tracks.first { self.loadArtwork(for: first, into: item) }
                    item.handler = { [weak self] _, completion in
                        self?.play(tracks, startingAt: 0)
                        completion()
                    }
                    return item
                }
                sections.append(CPListSection(items: items, header: "Albums and Playlists", sectionIndexTitle: nil))
            }
            let filed = Set(index.collections.flatMap(\.trackIds))
            let loose = present.filter { !filed.contains($0.id) }
            if !loose.isEmpty {
                sections.append(CPListSection(items: self.trackItems(loose), header: "Songs", sectionIndexTitle: nil))
            }
            return sections
        }
    }

    private func pushAlbums() {
        pushList(title: "Albums", empty: "No albums in your library.") { [weak self] in
            guard let self else { return [] }
            let albums = await self.fetch { client, parent in
                try await client.albums(parentId: parent, sort: .name, limit: Self.pageLimit).items
            }
            return [CPListSection(items: self.albumItems(albums))]
        }
    }

    private func pushArtists() {
        pushList(title: "Artists", empty: "No artists in your library.") { [weak self] in
            guard let self else { return [] }
            let artists = await self.fetch { client, parent in
                try await client.albumArtists(parentId: parent, limit: Self.pageLimit).items
            }
            let items = artists.map { artist -> CPListItem in
                let item = CPListItem(text: artist.name, detailText: nil)
                self.loadArtwork(for: artist, into: item)
                item.handler = { [weak self] _, completion in
                    self?.pushArtistAlbums(artist)
                    completion()
                }
                return item
            }
            return [CPListSection(items: items)]
        }
    }

    func pushArtistAlbums(_ artist: JellyfinItem) {
        pushList(title: artist.name, empty: "No albums by this artist.") { [weak self] in
            guard let self, let client = self.client else { return [] }
            let albums = (try? await client.albums(byArtist: artist.id)) ?? []
            return [CPListSection(items: self.albumItems(albums))]
        }
    }

    private func pushSongs() {
        pushList(title: "Songs", empty: "No songs in your library.") { [weak self] in
            guard let self else { return [] }
            let songs = await self.fetch { client, parent in
                try await client.songs(parentId: parent, sort: .name, limit: Self.pageLimit).items
            }
            return [CPListSection(items: self.trackItems(songs))]
        }
    }

    private func pushPlaylistTracks(_ playlist: JellyfinItem) {
        pushList(title: playlist.name, empty: "This playlist is empty.") { [weak self] in
            guard let self, let client = self.client else { return [] }
            let tracks = (try? await client.tracks(inPlaylist: playlist.id)) ?? []
            return [CPListSection(items: self.trackItems(tracks, remembering: RecentContext(
                kind: .jellyfinPlaylist, id: playlist.id, name: playlist.name, artworkItemId: playlist.id, lastOpened: 0
            )))]
        }
    }

    private func pushAlbumTracks(_ album: JellyfinItem) {
        pushList(title: album.name, empty: "This album is empty.") { [weak self] in
            guard let self, let client = self.client else { return [] }
            let tracks = (try? await client.tracks(inAlbum: album.id)) ?? []
            return [CPListSection(items: self.trackItems(tracks, remembering: RecentContext(
                kind: .album, id: album.id, name: album.name,
                subtitle: album.albumArtist ?? album.artists.first, artworkItemId: album.id, lastOpened: 0
            )))]
        }
    }

    // MARK: - Items

    /// An album row plays the album on the tap. The brief's point about pins is
    /// that a row you have to open is a row you will not use while driving;
    /// the track list is a tap away on the trailing button for the parked moment.
    private func albumItems(_ albums: [JellyfinItem]) -> [CPListItem] {
        albums.map { album in
            let item = CPListItem(text: album.name, detailText: album.subtitle)
            loadArtwork(for: album, into: item)
            item.accessoryType = .disclosureIndicator
            item.handler = { [weak self] _, completion in
                self?.pushAlbumTracks(album)
                completion()
            }
            return item
        }
    }

    /// Tapping a song plays from there through the rest of the list, which is what
    /// it means everywhere else in the app.
    private func trackItems(_ tracks: [JellyfinItem], remembering context: RecentContext? = nil) -> [CPListItem] {
        tracks.enumerated().map { index, track in
            let item = CPListItem(text: track.name, detailText: track.subtitle)
            loadArtwork(for: track, into: item)
            item.handler = { [weak self] _, completion in
                self?.play(tracks, startingAt: index)
                if let context { self?.remember(context) }
                completion()
            }
            return item
        }
    }

    // MARK: - Playing

    private func play(_ items: [JellyfinItem], startingAt index: Int, shuffled: Bool = false) {
        guard let client else { return }
        let mapped = JellyfinPlaybackBridge.playableTracks(from: items, client: client)
        guard !mapped.tracks.isEmpty else { return }
        let start = mapped.sourceIndices.firstIndex { $0 >= index } ?? (mapped.tracks.count - 1)
        // `.carplay` covers everything reached through the car's own screens,
        // whatever kind of list it was. The phone knows it was an album; the car
        // knows the listener was driving, and that is the more interesting fact.
        PlaybackContext.attributing(.carplay) {
            PlaybackEngine.shared.play(mapped.tracks, startingAt: start, shuffled: shuffled)
        }
        SoundBoundsSync.shared.prefetch(ids: PlaybackEngine.shared.queue.entries.map(\.track.id))
        CarPlayNowPlaying.shared.present()
        refreshHome()
    }

    private func play(localPlaylist list: Playlist) async {
        guard let playlists else { return }
        let contents = await playlists.contents(of: list)
        guard !contents.playbackOrder.isEmpty else { return }
        play(contents.playbackOrder, startingAt: 0)
        remember(RecentContext(
            kind: .localPlaylist, id: list.id, name: list.name,
            subtitle: list.isSmart ? "Smart playlist" : nil,
            artworkItemId: list.artworkItemId ?? contents.playbackOrder.first?.albumId, lastOpened: 0
        ))
    }

    private func shuffleEverything() async {
        let songs = await fetch { client, parent in
            try await client.songs(parentId: parent, sort: .random, startIndex: 0, limit: 300).items
        }
        let wanted = await TasteStore.shared.withoutNotInterested(songs)
        guard !wanted.isEmpty else { return }
        play(wanted, startingAt: 0)
    }

    /// The same resume the phone's Home does.
    private func resume(_ context: RecentContext) async {
        guard let client else { return }
        switch context.kind {
        case .album:
            if let tracks = try? await client.tracks(inAlbum: context.id) { play(tracks, startingAt: 0) }
        case .jellyfinPlaylist:
            if let tracks = try? await client.tracks(inPlaylist: context.id) { play(tracks, startingAt: 0) }
        case .localPlaylist:
            if let playlists {
                await playlists.reload()
                if let list = playlists.playlists.first(where: { $0.id == context.id }) {
                    await play(localPlaylist: list)
                    return
                }
            }
            RecentContextStore.shared.forget(context)
            return
        case .station:
            let mix = await TasteStore.shared.withoutNotInterested((try? await client.instantMix(seededBy: context.id)) ?? [])
            guard !mix.isEmpty else { return }
            play(mix, startingAt: 0)
        }
        remember(context)
    }

    private func remember(_ context: RecentContext) {
        var fresh = context
        fresh.lastOpened = Date().millis
        RecentContextStore.shared.remember(fresh)
    }

    // MARK: - Picking up another device's queue

    private func resumableQueue() async -> QueueState? {
        guard let db = CurationDatabase.shared else { return nil }
        let found = try? await Task.detached { try db.resumableQueues().first }.value
        // Only when it is newer than anything this phone was in; otherwise the
        // phone's own last album is the better first row.
        if let found, found.updatedAt > (RecentContextStore.shared.list.contexts.first?.lastOpened ?? 0) {
            return found
        }
        return nil
    }

    private func pickUp(_ queue: QueueState) async {
        guard let client else { return }
        let ids = queue.trackIdList
        guard let items = try? await client.items(ids: ids) else { return }
        let byId = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let ordered = ids.compactMap { byId[$0] }
        guard !ordered.isEmpty else { return }
        let startId = ids.indices.contains(queue.position) ? ids[queue.position] : ids[0]
        let start = ordered.firstIndex { $0.id == startId } ?? 0
        play(ordered, startingAt: start)
        PlaybackEngine.shared.seek(to: .milliseconds(queue.elapsedMs))
    }

    // MARK: - Artwork

    private func loadArtwork(for item: JellyfinItem, into row: CPListItem) {
        guard let client, let url = client.artworkURL(for: item, maxWidth: artworkWidth) else { return }
        load(url, into: row)
    }

    private func loadArtwork(itemId: String, into row: CPListItem) {
        guard let client else { return }
        load(client.artworkURL(itemId: itemId, tag: nil, maxWidth: artworkWidth), into: row)
    }

    private func load(_ url: URL, into row: CPListItem) {
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
        load: @escaping @MainActor () async -> [CPListSection]
    ) {
        let template = CPListTemplate(title: title, sections: [])
        template.emptyViewSubtitleVariants = [empty]
        CarPlayNowPlaying.shared.push(template)

        Task { [weak template] in
            let sections = await load()
            guard let template else { return }
            // The car's row limit applies across the whole template.
            var budget = CPListTemplate.maximumItemCount
            var clamped: [CPListSection] = []
            for section in sections where budget > 0 {
                let items = Array(section.items.prefix(budget))
                budget -= items.count
                clamped.append(CPListSection(items: items, header: section.header, sectionIndexTitle: nil))
            }
            template.updateSections(clamped)
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
