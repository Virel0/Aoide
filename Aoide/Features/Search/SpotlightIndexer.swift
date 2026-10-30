import CoreSpotlight
import Foundation
import MeleteKit
import UniformTypeIdentifiers
import os

/// Publishes the library to Spotlight so albums, artists and playlists are findable
/// from the Home Screen.
///
/// Indexes containers, not tracks. A library of a few hundred albums is tens of
/// thousands of songs, and burying "Rumours" under eleven of its own tracks makes
/// Spotlight worse, not better — the album is what you were looking for.
@MainActor
final class SpotlightIndexer {
    static let shared = SpotlightIndexer()

    /// Identifies our entries so `deleteSearchableItems(withDomainIdentifiers:)`
    /// can remove exactly ours on sign-out and nothing else.
    static let domain = AppIdentity.named("library")

    private let log = Logger(subsystem: AppIdentity.bundle, category: "spotlight")
    private let defaults = UserDefaults.standard
    private let lastIndexedKey = "aoide.spotlight.lastIndexed"

    /// Re-index at most daily. The library changes when something is added to the
    /// server, which is rare next to how often the app opens, and indexing on every
    /// launch would spend a burst of requests and battery to usually change nothing.
    private let interval: TimeInterval = 24 * 60 * 60

    private var isIndexing = false

    private init() {}

    func indexIfNeeded(client: MeleteClient, force: Bool = false) async {
        guard CSSearchableIndex.isIndexingAvailable() else { return }
        guard !isIndexing else { return }

        if !force, let last = defaults.object(forKey: lastIndexedKey) as? Date,
           Date().timeIntervalSince(last) < interval {
            return
        }

        isIndexing = true
        defer { isIndexing = false }

        do {
            async let albums = client.albums(sort: .name, direction: .ascending, limit: 500).items
            async let artists = client.albumArtists(limit: 500).items

            let items = try await
                albums.map { searchableItem(for: $0, kind: "Album") }
                + artists.map { searchableItem(for: $0, kind: "Artist") }

            try await CSSearchableIndex.default().indexSearchableItems(items)
            defaults.set(Date(), forKey: lastIndexedKey)
            log.info("Indexed \(items.count, privacy: .public) items for Spotlight.")
        } catch is CancellationError {
            return
        } catch {
            // Never surfaced: Spotlight is a convenience, and a failure here says
            // nothing about whether the app works.
            log.error("Spotlight indexing failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Removes everything we published. Called on sign-out — otherwise one account's
    /// library stays searchable after someone else signs in.
    func clear() async {
        guard CSSearchableIndex.isIndexingAvailable() else { return }
        defaults.removeObject(forKey: lastIndexedKey)
        try? await CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [Self.domain])
    }

    private func searchableItem(for item: MusicItem, kind: String) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: .audio)
        attributes.title = item.name
        attributes.contentDescription = item.subtitle.isEmpty ? kind : "\(kind) · \(item.subtitle)"
        attributes.kind = kind
        // Genres and the artist name become matchable text, so "jazz" finds albums
        // whose titles never say it.
        attributes.keywords = [kind] + item.genres + item.artists
        if let artist = item.albumArtist ?? item.artists.first {
            attributes.artist = artist
        }
        attributes.album = item.album

        let searchable = CSSearchableItem(
            // The kind goes with the id: Melete numbers albums and artists apart,
            // so the same number can be both.
            uniqueIdentifier: "\(kind.lowercased()):\(item.id)",
            domainIdentifier: Self.domain,
            attributeSet: attributes
        )
        // Without an expiry Spotlight keeps entries forever, including for albums
        // since deleted from the server. A month outlives the daily re-index that
        // would refresh a still-present one.
        searchable.expirationDate = Date().addingTimeInterval(30 * 24 * 60 * 60)
        return searchable
    }
}
