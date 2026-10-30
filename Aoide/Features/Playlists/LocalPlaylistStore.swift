import CurationKit
import Foundation
import MeleteKit
import os

/// One row of a local playlist, resolved as far as it can be.
///
/// A playlist entry stores a Melete track id and a fingerprint, nothing else, so every row
/// on screen is assembled from up to three sources: what the server says now, what was
/// downloaded to this device, and what the local cache last saw. They are kept apart
/// rather than merged into one optional item because they mean different things — a row
/// with a cached title and no item can be *shown* but not *played*, and a screen that
/// couldn't tell the difference would either hide songs that exist or offer to play
/// songs that don't.
struct PlaylistTrack: Identifiable {
    /// The playlist entry's own id in a manual playlist; the track id in a smart one,
    /// where there are no entries and a track appears at most once.
    let id: String
    /// `nil` for a smart playlist — there is no stored row to remove or reorder.
    let itemId: String?
    let jellyfinId: String
    /// What can actually be played. `nil` when neither the server nor the downloads
    /// folder could produce it.
    let item: MusicItem?
    /// The last thing the local cache knew, for drawing a row the server can't answer for.
    let cached: TrackRef?
    /// The store's own marker: a relink pass looked for this fingerprint and found
    /// nothing. Distinct from "the server didn't answer just now".
    let isUnresolved: Bool
    let playCount: Int

    var title: String { item?.name ?? cached?.title ?? "Unavailable Song" }

    var subtitle: String {
        if let item, !item.subtitle.isEmpty { return item.subtitle }
        if let cached { return cached.artist }
        return ""
    }

    var duration: Duration? {
        if let duration = item?.duration { return duration }
        return cached?.durationMs.map { .milliseconds($0) }
    }

    var isPlayable: Bool { item != nil }
}

/// A playlist's rows plus how the load went.
struct PlaylistContents {
    var tracks: [PlaylistTrack] = []
    var isLoading = true
    /// Set when the playlist itself couldn't be read — a broken rule set, or no store.
    /// Distinct from a row that couldn't be resolved, which is a per-row fact.
    var errorMessage: String?
    /// Set when the server couldn't be reached. The rows are still drawn from the cache;
    /// this is what lets the screen say so instead of looking half-empty for no reason.
    var offlineMessage: String?
    /// How many the playlist really holds, when that is more than was resolved. Surfaced
    /// rather than silently dropped: a screen showing 500 of 12,000 songs and saying
    /// "500 songs" is lying about the playlist.
    var totalCount: Int?

    /// The queue a tap builds: every row that can actually play, in playlist order.
    var playbackOrder: [MusicItem] { tracks.compactMap(\.item) }

    /// Where a tap on this row lands in `playbackOrder`, or `nil` if it can't play.
    ///
    /// Derived on demand and never stored, which is the whole point. `playbackOrder` is
    /// recomputed from `tracks` on every access, and the detail screen reorders and
    /// deletes rows in place without reloading — so an index baked in at load time
    /// addresses a position in an array that has since moved, and the tap starts a
    /// different song than the one under the finger. Counting here means the two can
    /// never disagree.
    ///
    /// Linear rather than a lookup table because `tracks` is capped at
    /// `LocalPlaylistStore.maxResolvedTracks` and this runs once per tap.
    func playbackIndex(of track: PlaylistTrack) -> Int? {
        guard track.isPlayable else { return nil }
        var index = 0
        for row in tracks {
            // By row id, not track id: a manual playlist may hold the same song twice,
            // and matching on the track id would send both rows to the first one.
            if row.id == track.id { return index }
            if row.isPlayable { index += 1 }
        }
        return nil
    }

    var unplayableCount: Int { tracks.filter { !$0.isPlayable }.count }

    var totalDuration: Duration {
        tracks.compactMap(\.duration).reduce(Duration.zero, +)
    }
}

/// A playlist entry reduced to what crosses the actor boundary.
private struct PlaylistEntry: Sendable {
    let rowId: String
    let itemId: String?
    let jellyfinId: String
    let isUnresolved: Bool
}

/// The app's view of the local curation store's playlists.
///
/// Every screen in this feature goes through here rather than touching `CurationStore`
/// directly, for two reasons. The store is optional — it is `nil` when the database
/// failed to open, and music has to keep playing regardless — so exactly one place
/// should have to remember that. And its calls are synchronous SQLite: cheap, but they
/// block the thread they run on, and this object lives on the main actor where the queue
/// and every frame do. So the work happens in a detached task and the results come back
/// here.
@MainActor
@Observable
final class LocalPlaylistStore {
    /// What the screens say when there is no database. Deliberately not an apology and
    /// not a crash: it names what is lost and what still works.
    static let unavailableMessage = """
        Playlists are kept in a local database that couldn't be opened on this device. \
        Music still plays, but nothing can be saved here.
        """

    private let client: MeleteClient
    private let log = Logger(subsystem: AppIdentity.bundle, category: "curation")

    private(set) var folders: [Folder] = []
    private(set) var playlists: [Playlist] = []
    /// Songs per playlist. A smart playlist's is the number its rules currently match,
    /// which is the only count it has.
    private(set) var trackCounts: [String: Int] = [:]
    private(set) var hasLoaded = false
    /// The last thing that went wrong, for a screen to surface once and move on.
    var lastErrorMessage: String?

    var isAvailable: Bool { CurationDatabase.shared != nil }

    init(client: MeleteClient) {
        self.client = client
    }

    // MARK: - Listing

    var rootFolders: [Folder] { folders.filter { $0.parentId == nil } }

    func folders(in parentId: String?) -> [Folder] {
        folders.filter { $0.parentId == parentId }
    }

    func playlists(in folderId: String?) -> [Playlist] {
        playlists.filter { $0.folderId == folderId }
    }

    /// Re-reads the whole tree.
    ///
    /// The tree, not one folder: `folders()` and `playlists()` are two indexed queries
    /// over tables that hold tens of rows, and reloading only the folder on screen would
    /// leave a stale count behind whenever a song was added from somewhere else.
    func reload() async {
        let snapshot: Snapshot? = await run("load your playlists") { store in
            let folders = try store.folders()
            let playlists = try store.playlists()

            var counts: [String: Int] = [:]
            for list in playlists {
                if list.isSmart {
                    // A smart playlist has no stored rows, so its count is whatever the
                    // rules match right now. Evaluated here with the rest rather than
                    // per row, so the list screen makes one hop off the main actor
                    // instead of one per playlist. A rule set that won't compile leaves
                    // the count absent rather than failing the whole listing — one
                    // broken playlist must not hide the others.
                    //
                    // `matchCount`, not `resolve`: this needs a number, and `resolve`
                    // would build the whole id list to have its `count` taken — a rule
                    // set matching a large library means a five-figure array assembled
                    // and dropped on the floor, every time any playlist changes.
                    counts[list.id] = try? store.matchCount(playlist: list)
                } else {
                    counts[list.id] = try store.itemCount(in: list.id)
                }
            }
            return Snapshot(
                folders: folders,
                playlists: playlists,
                counts: counts,
                // One query for the whole screen. Per tile it would be one per row.
                coverAlbums: try store.coverAlbums(for: playlists.map(\.id))
            )
        }

        if let snapshot {
            folders = snapshot.folders
            playlists = snapshot.playlists
            trackCounts = snapshot.counts
            coverAlbums = snapshot.coverAlbums
        }
        hasLoaded = true
    }

    private struct Snapshot: Sendable {
        let folders: [Folder]
        let playlists: [Playlist]
        let counts: [String: Int]
        let coverAlbums: [String: [String]]
    }

    // MARK: - Playlists

    @discardableResult
    func createPlaylist(name: String, folderId: String? = nil) async -> Playlist? {
        let created: Playlist? = await run("create that playlist") { store in
            try store.createPlaylist(name: name, folderId: folderId)
        }
        await reload()
        return created
    }

    /// Creates a smart playlist. Two writes, because that is what the store's API is:
    /// `createPlaylist` mints the row and `settingSmartRules` deliberately returns a copy
    /// without writing, so the rules reach disk only through `record` — the one path that
    /// also writes the op a rule change has to sync as.
    @discardableResult
    /// Creates the built-in smart playlists this library does not have yet.
    ///
    /// Under fixed ids, so the desk creating the same ones ends in one row each, not
    /// two; and only where no row has ever existed, so one that was deleted stays
    /// deleted everywhere. Safe to call at every launch.
    func ensureBuiltIns() async {
        await run("set up the built-in playlists") { store in
            for built in BuiltInPlaylist.allCases where !(try store.playlistRowExists(built.id)) {
                // Rules first: a playlist row made before its rules failed would
                // stay empty, because a row that exists is never created again.
                let rules = try built.rules
                let list = try store.createPlaylist(name: built.name, notes: built.notes, id: built.id)
                try store.record(list.settingSmartRules(rules))
            }
        }
        await reload()
    }

    func createSmartPlaylist(name: String, rules: SmartRules, folderId: String? = nil) async -> Playlist? {
        let created: Playlist? = await run("create that playlist") { store in
            let list = try store.createPlaylist(name: name, folderId: folderId)
            return try store.record(list.settingSmartRules(rules))
        }
        await reload()
        return created
    }

    func rename(_ playlist: Playlist, to name: String) async {
        await run("rename that playlist") { store in
            try store.rename(playlist: playlist.id, to: name)
        }
        await reload()
    }

    func setNotes(_ notes: String?, on playlist: Playlist) async {
        await run("save those notes") { store in
            // Empty and absent are the same thing to a reader, and storing "" would make
            // an empty caption render as a blank line under the title.
            let trimmed = notes?.trimmingCharacters(in: .whitespacesAndNewlines)
            try store.setNotes(trimmed?.isEmpty == true ? nil : trimmed, on: playlist.id)
        }
        await reload()
    }

    func setRules(_ rules: SmartRules, on playlist: Playlist) async {
        await run("save those rules") { store in
            guard let current = try store.playlist(playlist.id) else { return }
            try store.record(current.settingSmartRules(rules))
        }
        await reload()
    }

    func delete(_ playlist: Playlist) async {
        await run("delete that playlist") { store in
            try store.deletePlaylist(playlist.id)
        }
        await reload()
    }

    func move(_ playlist: Playlist, toFolder folderId: String?) async {
        await run("move that playlist") { store in
            try store.move(playlist: playlist.id, toFolder: folderId)
        }
        await reload()
    }

    // MARK: - Folders

    func createFolder(name: String, parentId: String? = nil) async {
        await run("create that folder") { store in
            try store.createFolder(name: name, parentId: parentId)
        }
        await reload()
    }

    func rename(_ folder: Folder, to name: String) async {
        await run("rename that folder") { store in
            try store.rename(folder: folder.id, to: name)
        }
        await reload()
    }

    /// Deleting a folder keeps what was inside it — the store promotes the contents to
    /// the folder's own parent. A folder is filing, not content, so removing one means
    /// "stop organising this way", never "destroy these playlists".
    func delete(_ folder: Folder) async {
        await run("delete that folder") { store in
            try store.deleteFolder(folder.id)
        }
        await reload()
    }

    // MARK: - Contents

    func contents(of playlist: Playlist) async -> PlaylistContents {
        guard let store = CurationDatabase.shared else {
            return PlaylistContents(isLoading: false, errorMessage: Self.unavailableMessage)
        }

        // 1. What the playlist says it holds. For a smart playlist this is the rule
        //    evaluation, which is a query over the local cache and needs no network at
        //    all — the whole reason smart playlists work on a plane.
        let entries: [PlaylistEntry]
        do {
            entries = try await readEntries(of: playlist, from: store)
        } catch {
            log.error("Couldn't read playlist \(playlist.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return PlaylistContents(
                isLoading: false,
                errorMessage: playlist.isSmart
                    ? "These rules couldn't be evaluated. Try editing them."
                    : "This playlist couldn't be read."
            )
        }

        guard !entries.isEmpty else { return PlaylistContents(isLoading: false) }
        return await resolveContents(of: entries)
    }

    /// Turns the playlist's entries into rows, from the server, downloads, and the
    /// local cache, in that order of preference.
    private func resolveContents(of entries: [PlaylistEntry]) async -> PlaylistContents {
        // A rule set can legitimately match the whole library — "never played" on a fresh
        // install is exactly that — and resolving twenty thousand ids means two hundred
        // round trips before a single row can be drawn. The cap is the same 500 the
        // store's queue persistence keeps, so nothing is lost here that would have
        // survived being played anyway.
        let total = entries.count
        let resolved = Array(entries.prefix(Self.maxResolvedTracks))
        let ids = resolved.map(\.jellyfinId)

        // 2. The server, for everything a row needs that the store doesn't keep — the
        //    artwork and the stream URL above all.
        let (byId, offlineMessage) = await fetchServerItems(ids: ids)

        // 3. Downloads fill the gap. A downloaded track carries its own full metadata on
        //    disk, so it is playable with no signal at all — which is the entire point of
        //    having downloaded it, and the difference between a playlist that works in a
        //    car tunnel and one that doesn't.
        let downloaded = Dictionary(
            DownloadIndex.shared.tracks.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        // 4. The local cache and the play history, in one hop.
        let local = await run("read your listening history") { store in
            LocalDetail(
                cached: try store.cachedTracks(jellyfinIds: ids),
                stats: try store.stats(jellyfinIds: ids)
            )
        }

        return PlaylistContents(
            tracks: Self.rows(for: resolved, server: byId, downloaded: downloaded, local: local),
            isLoading: false,
            errorMessage: nil,
            offlineMessage: offlineMessage,
            totalCount: total > resolved.count ? total : nil
        )
    }

    /// The playlist's own list: rule results for a smart playlist, stored entries
    /// otherwise. Read off the main actor, because the query blocks its thread.
    private func readEntries(of playlist: Playlist, from store: CurationStore) async throws -> [PlaylistEntry] {
        let list = playlist
        return try await Task.detached {
            if list.isSmart {
                return try store.resolve(playlist: list).map {
                    PlaylistEntry(rowId: $0, itemId: nil, jellyfinId: $0, isUnresolved: false)
                }
            }
            return try store.items(in: list.id).map {
                PlaylistEntry(
                    rowId: $0.id,
                    itemId: $0.id,
                    jellyfinId: $0.linkedJellyfinId,
                    isUnresolved: $0.isUnresolved
                )
            }
        }.value
    }

    /// The server's items by id, or nothing and a message to show when the server
    /// can't be reached.
    private func fetchServerItems(ids: [String]) async -> (items: [String: MusicItem], offlineMessage: String?) {
        var byId: [String: MusicItem] = [:]
        do {
            for item in try await client.items(ids: ids) { byId[item.id] = item }
        } catch {
            log.debug("Playlist resolve failed: \(error.localizedDescription, privacy: .public)")
            return ([:], "Couldn't reach your server. Showing what's saved on this device.")
        }
        return (byId, nil)
    }

    /// One row per entry, from whichever source has the track: the server first,
    /// then a download.
    private static func rows(
        for entries: [PlaylistEntry],
        server: [String: MusicItem],
        downloaded: [String: MusicItem],
        local: LocalDetail?
    ) -> [PlaylistTrack] {
        var rows: [PlaylistTrack] = []
        rows.reserveCapacity(entries.count)
        for entry in entries {
            rows.append(PlaylistTrack(
                id: entry.rowId,
                itemId: entry.itemId,
                jellyfinId: entry.jellyfinId,
                item: server[entry.jellyfinId] ?? downloaded[entry.jellyfinId],
                cached: local?.cached[entry.jellyfinId],
                isUnresolved: entry.isUnresolved,
                playCount: local?.stats[entry.jellyfinId]?.playCount ?? 0
            ))
        }
        return rows
    }

    /// See `contents(of:)` for why there is a ceiling at all.
    static let maxResolvedTracks = 500

    private struct LocalDetail: Sendable {
        let cached: [String: TrackRef]
        let stats: [String: TrackStats]
    }

    // MARK: - Editing contents

    /// Adds songs to the end of a playlist, and returns how many landed.
    ///
    /// The tracks are cached on the way past. That is not incidental: the entry stores a
    /// fingerprint so it can be found again after a library rescan, and the fingerprint
    /// is only matchable against cached rows — an entry added without one could never be
    /// relinked, which is exactly the case the fingerprint exists for.
    @discardableResult
    func add(_ items: [MusicItem], to playlist: Playlist) async -> Int {
        let songs = items.filter { $0.type == .audio }
        guard !songs.isEmpty else { return 0 }

        let added: Int? = await run("add those songs") { store in
            let now = Date().millis
            let refs = songs.map { TrackCatalogue.trackRef(for: $0, at: now) }
            try store.cacheTracks(refs)
            return try store.addTracks(refs.map { TrackLink($0) }, to: playlist.id).count
        }
        await reload()
        return added ?? 0
    }

    /// Albums each playlist holds, for drawing a cover from its contents.
    private(set) var coverAlbums: [String: [String]] = [:]

    /// Sets a picked photo as the playlist's cover.
    ///
    /// The bytes are written to disk and registered *before* the playlist row names
    /// them, so the op referencing a hash can never exist without the blob behind it —
    /// which is what lets sync guarantee the same thing to every other device.
    func setPhotoArtwork(_ data: Data, on playlist: Playlist) async -> Bool {
        guard let prepared = await PlaylistImageStore.shared.prepare(data) else {
            lastErrorMessage = "That image couldn't be read."
            return false
        }

        let saved: Bool? = await run("set that cover") { store in
            try store.registerImage(
                hash: prepared.hash,
                mime: prepared.mime,
                bytes: prepared.bytes.count
            )
            guard var row = try store.playlist(playlist.id) else { return false }
            row.imageHash = prepared.hash
            row.imageMime = prepared.mime
            // A photo is a deliberate choice and outranks a cover picked from the
            // library, so the older one is cleared rather than left to shadow it.
            row.artworkItemId = nil
            try store.record(row)
            return true
        }
        await reload()
        SyncCoordinator.shared.syncNow()
        return saved ?? false
    }

    /// Sets the playlist's cover to an album it holds, or clears it back to the mosaic.
    func setArtwork(_ itemId: String?, on playlist: Playlist) async {
        await run("change that cover") { store in
            guard var row = try store.playlist(playlist.id) else { return }
            row.artworkItemId = itemId
            // Cleared together: leaving a hash behind would keep the photo winning
            // and make choosing an album look like it did nothing.
            row.imageHash = nil
            row.imageMime = nil
            try store.record(row)
        }
        // Published straight away rather than left for the sweep, so the cover is on
        // its way to the other devices while the person who chose
        // it is still looking at it.
        if itemId != nil, let refreshed = try? CurationDatabase.shared?.playlist(playlist.id) {
            await publishCover(for: refreshed)
        }
        await reload()
    }

    /// Turns a chosen album cover into a blob, so it reaches other devices rather
    /// than only existing as a reference this app knows how to follow.
    ///
    /// An `artworkItemId` is an instruction — "draw the cover of that album" — which
    /// only something holding this database can carry out. Another device's sync has a
    /// hash and nothing else, so a cover that never becomes bytes is a cover that
    /// exists on this device alone.
    ///
    /// Mosaics are deliberately *not* published. They are derived from what a playlist
    /// currently holds and change whenever it does, so freezing one into an immutable
    /// blob would pin a cover that has stopped being true; each device draws its own
    /// from what the playlist holds.
    private func publishCover(for playlist: Playlist) async {
        guard playlist.imageHash == nil, let itemId = playlist.artworkItemId else { return }
        let url = client.artworkURL(itemId: itemId, tag: nil, maxWidth: 1000)
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let prepared = await PlaylistImageStore.shared.prepare(data)
        else { return }

        await run("publish that cover") { store in
            try store.registerImage(
                hash: prepared.hash,
                mime: prepared.mime,
                bytes: prepared.bytes.count
            )
            guard var row = try store.playlist(playlist.id) else { return }
            // `artworkItemId` is kept alongside the hash rather than replaced. It
            // still describes what the cover *is*, and it is what a later republish
            // would work from if the blob were ever lost.
            row.imageHash = prepared.hash
            row.imageMime = prepared.mime
            try store.record(row)
        }
        SyncCoordinator.shared.syncNow()
    }

    /// Publishes covers for playlists chosen before publishing existed.
    ///
    /// Bounded per run: this downloads and re-uploads an image each time, and a
    /// library of a few hundred playlists should trickle rather than saturate a phone
    /// connection the first time it opens.
    func publishPendingCovers(limit: Int = 5) async {
        let waiting = playlists
            .filter { $0.imageHash == nil && $0.artworkItemId != nil }
            .prefix(limit)
        for playlist in waiting {
            await publishCover(for: playlist)
        }
    }

    func removeItem(_ itemId: String) async {
        await run("remove that song") { store in
            try store.removeItem(itemId)
        }
        await reload()
    }

    /// Drag-to-reorder, straight onto the store's own move.
    ///
    /// `index` is where the row ends up in the list with it already taken out, which is
    /// what `moveItem` documents and *not* what SwiftUI's `onMove` hands over — see the
    /// caller for the one-line correction. One row is written, never a renumbering of the
    /// whole playlist.
    /// Returns whether the write landed, so a caller that moved the row optimistically
    /// knows whether to put it back.
    @discardableResult
    func moveItem(_ itemId: String, in playlistId: String, to index: Int) async -> Bool {
        let moved: Bool? = await run("reorder that playlist") { store in
            try store.moveItem(itemId, in: playlistId, to: index)
            return true
        }
        return moved ?? false
    }

    // MARK: - Smart rules

    /// What a rule set would match right now, for the editor's live preview.
    ///
    /// Titles come from the local cache rather than the server: the preview updates on
    /// every keystroke, and a network round trip per edit would make it lag far behind
    /// the rule being typed.
    func preview(_ rules: SmartRules) async -> SmartPreview {
        guard let store = CurationDatabase.shared else {
            return SmartPreview(count: 0, titles: [], errorMessage: Self.unavailableMessage)
        }
        do {
            return try await Task.detached {
                let ids = try store.evaluate(rules)
                let cached = try store.cachedTracks(jellyfinIds: Array(ids.prefix(6)))
                return SmartPreview(
                    count: ids.count,
                    titles: ids.prefix(6).map { cached[$0]?.title ?? "—" }
                )
            }.value
        } catch {
            return SmartPreview(count: 0, titles: [], errorMessage: Self.describe(error))
        }
    }

    // MARK: - Plumbing

    /// Runs a store call off the main actor, reporting rather than throwing.
    ///
    /// Every screen here has the same two answers to a failed write — say so once, and
    /// carry on showing what is already loaded — so the conversion happens once, here,
    /// instead of in a `do/catch` per button.
    @discardableResult
    private func run<T: Sendable>(
        _ description: String,
        _ body: @escaping @Sendable (CurationStore) throws -> T
    ) async -> T? {
        guard let store = CurationDatabase.shared else {
            lastErrorMessage = Self.unavailableMessage
            return nil
        }
        do {
            return try await Task.detached { try body(store) }.value
        } catch {
            log.error("Couldn't \(description, privacy: .public): \(error.localizedDescription, privacy: .public)")
            lastErrorMessage = "Couldn't \(description). \(Self.describe(error))"
            return nil
        }
    }

    /// CurationKit's errors carry a written explanation where they have one, and
    /// `localizedDescription` on a bare Swift error does not — it produces "The operation
    /// couldn't be completed", which tells a reader nothing at all.
    static func describe(_ error: any Error) -> String {
        if let smart = error as? SmartPlaylistError { return smart.description }
        if let playlistError = error as? PlaylistError {
            switch playlistError {
            case .noSuchPlaylist: return "That playlist no longer exists."
            case .noSuchFolder: return "That folder no longer exists."
            case .noSuchItem, .itemNotInPlaylist: return "That song is no longer in the playlist."
            case .folderCycle: return "A folder can't be moved inside itself."
            case .badNeighbours: return "That position couldn't be worked out. Try again."
            }
        }
        return error.localizedDescription
    }
}

struct SmartPreview {
    var count: Int
    var titles: [String]
    var errorMessage: String?
}
