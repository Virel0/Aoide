import CryptoKit
import Foundation
import MeleteKit
import UIKit

/// Cover art and lyrics kept on disk for downloaded tracks.
///
/// Audio alone is not enough to be genuinely offline: without these, a downloaded
/// album on a plane plays fine but shows grey squares and an empty lyrics sheet,
/// which reads as broken rather than as "no signal". Both are small next to the
/// audio — a cover is tens of kilobytes against tens of megabytes — so they are
/// fetched eagerly when a download starts rather than hopefully later.
@MainActor
final class OfflineAssets {
    static let shared = OfflineAssets()

    /// Covers currently being fetched, so an album's tracks don't each request the
    /// one image they share.
    private var artworkInFlight: Set<URL> = []

    private init() {
        for directory in [Self.artworkDirectory, Self.lyricsDirectory] {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        // Excluded from backup for the same reason the audio is: the server already
        // has all of it, and Application Support is backed up by default. iCloud
        // would otherwise carry a copy of every cover in the library.
        var root = Self.root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? root.setResourceValues(values)
    }

    // MARK: - Locations

    nonisolated private static let root: URL = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Offline", isDirectory: true)
    }()

    nonisolated private static var artworkDirectory: URL { root.appendingPathComponent("Artwork", isDirectory: true) }
    nonisolated private static var lyricsDirectory: URL { root.appendingPathComponent("Lyrics", isDirectory: true) }

    /// Artwork is keyed by a hash of its URL rather than by track, because a
    /// Melete cover URL names the album — so the same key means the same bytes, and an album's twelve tracks share one
    /// file instead of storing the cover twelve times.
    nonisolated private static func artworkFile(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let name = digest.compactMap { String(format: "%02x", $0) }.joined()
        return artworkDirectory.appendingPathComponent(name, isDirectory: false)
    }

    nonisolated private static func lyricsFile(for trackId: String) -> URL {
        lyricsDirectory.appendingPathComponent(trackId, isDirectory: false).appendingPathExtension("json")
    }

    // MARK: - Reading

    /// Bytes for a cover we already hold, whatever the network is doing.
    nonisolated static func artworkData(for url: URL) -> Data? {
        try? Data(contentsOf: artworkFile(for: url))
    }

    nonisolated static func hasLyrics(for trackId: String) -> Bool {
        FileManager.default.fileExists(atPath: lyricsFile(for: trackId).path)
    }

    static func lyrics(for trackId: String) -> LyricsTrack? {
        guard let data = try? Data(contentsOf: lyricsFile(for: trackId)) else { return nil }
        return try? JSONDecoder().decode(LyricsTrack.self, from: data)
    }

    // MARK: - Writing

    /// Fetches everything a track needs to be usable with no connection.
    ///
    /// Melete serves a cover at its own size, so one file serves every size the
    /// app draws it at.
    func cache(_ items: [MusicItem], client: MeleteClient) async {
        for item in items where item.type == .audio {
            if let url = client.artworkURL(for: item, maxWidth: Design.ArtworkWidth.player) {
                await storeArtwork(from: url, authorization: client.authorization)
            }
            await storeLyrics(for: item.id, client: client)
        }
    }

    private func storeArtwork(from url: URL, authorization: String?) async {
        let destination = Self.artworkFile(for: url)
        guard !FileManager.default.fileExists(atPath: destination.path) else { return }

        // Downloading an album calls this once per track, and every track on it
        // resolves to the same cover — so without this, a sixteen-track album fires
        // thirty-two simultaneous requests for two images. The existence check above
        // can't catch it: none of them has finished writing yet. Bailing is right
        // rather than waiting, because whoever got here first is already storing it.
        guard !artworkInFlight.contains(url) else { return }
        artworkInFlight.insert(url)
        defer { artworkInFlight.remove(url) }

        var request = URLRequest(url: url)
        if let authorization { request.setValue(authorization, forHTTPHeaderField: "Authorization") }
        guard
            let (data, response) = try? await URLSession.shared.data(for: request),
            (response as? HTTPURLResponse)?.statusCode == 200,
            UIImage(data: data) != nil
        else { return }
        try? data.write(to: destination, options: .atomic)
    }

    private func storeLyrics(for trackId: String, client: MeleteClient) async {
        guard !Self.hasLyrics(for: trackId) else { return }
        guard let lyrics = try? await client.lyrics(forItem: trackId) else { return }
        guard let data = try? JSONEncoder().encode(lyrics) else { return }
        try? data.write(to: Self.lyricsFile(for: trackId), options: .atomic)
    }

    // MARK: - Removing

    func remove(trackId: String) {
        try? FileManager.default.removeItem(at: Self.lyricsFile(for: trackId))
        // Artwork is shared between tracks and keyed by URL, so it is not removed
        // per track — a sibling may still need it. Clearing everything is handled
        // by removeAll, which is what "Remove All Downloads" calls.
    }

    func removeAll() {
        for directory in [Self.artworkDirectory, Self.lyricsDirectory] {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    func diskUsage() -> Int64 {
        [Self.artworkDirectory, Self.lyricsDirectory].reduce(Int64(0)) { total, directory in
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.fileSizeKey]
            )) ?? []
            return total + contents.reduce(Int64(0)) { sum, url in
                sum + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
    }
}
