import Foundation
import MeleteKit
import os

/// Downloads from before Aoide moved to Melete, brought across.
///
/// Each file is named after its track's Jellyfin id, and the list that names them
/// was written in Jellyfin's item format, which today's build can't read: the
/// files were on the phone and the Downloads screen was empty. Melete's own
/// matching (`/aoide/match`, the rules playlist import uses) finds each song by
/// the old list's title, artists, album and length; a match is renamed to its
/// Melete id and listed again, so nothing is downloaded twice.
///
/// Converted downloads carry no tags of their own, so a file the old list doesn't
/// name can't be matched; it is counted in ``unmatched`` for the Downloads screen
/// to offer removing. Runs at each sign-in while old files remain, so a song the
/// server didn't have yet is found once it does.
@MainActor
@Observable
final class LegacyDownloads {
    static let shared = LegacyDownloads()

    /// Old downloads Melete has no song for, by their Jellyfin ids.
    private(set) var unmatched: [String] = []

    @ObservationIgnored private let log = Logger(subsystem: AppIdentity.bundle, category: "downloads")

    /// A track as the Jellyfin builds saved it. Only what matching needs.
    private struct OldTrack: Decodable {
        let id: String
        let name: String
        let album: String?
        let albumArtist: String?
        let artists: [String]?
        /// Jellyfin's 100-nanosecond ticks.
        let runTimeTicks: Int64?

        var row: ImportedTrack {
            let credited = (artists ?? []).filter { !$0.isEmpty }
            return ImportedTrack(
                title: name,
                artists: credited.isEmpty ? [albumArtist].compactMap { $0 } : credited,
                album: album,
                durationMs: runTimeTicks.map { Int($0 / 10_000) }
            )
        }
    }

    func bringAcross(client: MeleteClient) async {
        let downloads = DownloadStore.shared
        await downloads.launchChecked()
        let old = downloads.legacyIds
        guard !old.isEmpty else {
            unmatched = []
            try? FileManager.default.removeItem(at: DownloadIndex.legacyURL)
            return
        }
        let listed = Self.oldList()
        let named = old.compactMap { listed[$0] }
        var newIds: [String: String] = [:]
        if !named.isEmpty {
            do {
                let answers = try await client.match(named.map(\.row))
                for (track, answer) in zip(named, answers) {
                    if let answer { newIds[track.id] = answer.jellyfinId }
                }
            } catch {
                // Asked again at the next sign-in; the files stay as they are.
                log.error("Couldn't match old downloads: \(error.localizedDescription, privacy: .public)")
                return
            }
        }
        let items = await Self.items(Array(Set(newIds.values)), client: client)
        for (oldId, newId) in newIds { downloads.adopt(oldId, as: newId) }
        let index = DownloadIndex.shared
        index.record(items)
        let albumOf = Dictionary(items.compactMap { item in item.albumId.map { (item.id, $0) } }, uniquingKeysWith: { a, _ in a })
        if index.collections.isEmpty {
            Self.regroupAlbums(items, into: index)
        } else {
            index.relink(newIds, albumOf: albumOf)
        }
        unmatched = downloads.legacyIds
        log.info("Brought \(newIds.count, privacy: .public) old downloads across; \(self.unmatched.count, privacy: .public) unmatched")
    }

    /// Deletes the old downloads Melete has no song for.
    func removeUnmatched() {
        for id in unmatched { DownloadStore.shared.remove(id) }
        unmatched = []
        try? FileManager.default.removeItem(at: DownloadIndex.legacyURL)
    }

    /// The old list by Jellyfin id: set aside by `DownloadIndex`, or still where it
    /// was if this build hasn't opened it yet.
    private static func oldList() -> [String: OldTrack] {
        let current = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("downloaded-tracks.json")
        for url in [DownloadIndex.legacyURL, current] {
            guard let data = try? Data(contentsOf: url),
                  let tracks = try? JSONDecoder().decode([OldTrack].self, from: data)
            else { continue }
            return Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
        return [:]
    }

    /// The matched songs from Melete, a hundred at a time.
    private static func items(_ ids: [String], client: MeleteClient) async -> [MusicItem] {
        var found: [MusicItem] = []
        for start in stride(from: 0, to: ids.count, by: 100) {
            let slice = Array(ids[start..<min(start + 100, ids.count)])
            if let items = try? await client.items(ids: slice) { found += items }
        }
        return found
    }

    /// When the old albums and playlists weren't kept, an album with two or more
    /// songs here is shown as an album again; the rest are songs on their own.
    private static func regroupAlbums(_ items: [MusicItem], into index: DownloadIndex) {
        let byAlbum = Dictionary(grouping: items.filter { $0.albumId != nil }, by: { $0.albumId ?? "" })
        for (albumId, songs) in byAlbum where songs.count >= 2 {
            let ordered = songs.sorted {
                ($0.discNumber ?? 1, $0.trackNumber ?? 0) < ($1.discNumber ?? 1, $1.trackNumber ?? 0)
            }
            index.record(DownloadedCollection(
                id: albumId, kind: .album, name: ordered[0].album ?? ordered[0].name,
                subtitle: ordered[0].albumArtist, trackIds: ordered.map(\.id)
            ))
        }
    }
}
