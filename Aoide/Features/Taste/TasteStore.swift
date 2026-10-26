import CurationKit
import Foundation
import JellyfinKit
import os

/// The two things a listener can say about a track beyond liking it.
///
/// Reads are cached so a context menu can show the current state without a
/// database hop per row; writes go through the store so they sync. Anything that
/// assembles a queue *for* the listener — stations, shuffle, mixes — asks
/// `withoutNotInterested` first; smart playlists exclude the flag inside their SQL.
@MainActor
@Observable
final class TasteStore {
    static let shared = TasteStore()

    private(set) var byTrack: [String: TrackFlags] = [:]
    private(set) var flagged: [(flags: TrackFlags, track: TrackRef?)] = []
    private let log = Logger(subsystem: AppIdentity.bundle, category: "taste")

    private init() {}

    func flags(for jellyfinId: String) -> TrackFlags? {
        if let cached = byTrack[jellyfinId] { return cached }
        guard let store = CurationDatabase.shared, let found = try? store.flags(for: jellyfinId) else { return nil }
        byTrack[jellyfinId] = found
        return found
    }

    func isNotInterested(_ jellyfinId: String) -> Bool { flags(for: jellyfinId)?.notInterested == true }
    func isDontCount(_ jellyfinId: String) -> Bool { flags(for: jellyfinId)?.dontCount == true }

    func setNotInterested(_ value: Bool, on item: JellyfinItem) async {
        await write(item) { store, key in try store.setNotInterested(value, on: item.id, contentKey: key) }
    }

    func setDontCount(_ value: Bool, on item: JellyfinItem) async {
        await write(item) { store, key in try store.setDontCount(value, on: item.id, contentKey: key) }
    }

    func clear(_ flags: TrackFlags) async {
        guard let store = CurationDatabase.shared else { return }
        let id = flags.jellyfinId, key = flags.contentKey
        _ = try? await Task.detached {
            try store.setNotInterested(false, on: id, contentKey: key)
            try store.setDontCount(false, on: id, contentKey: key)
        }.value
        byTrack[id] = nil
        await reloadFlagged()
    }

    /// The tracks not marked "not interested", in the order given.
    func withoutNotInterested(_ items: [JellyfinItem]) async -> [JellyfinItem] {
        guard let store = CurationDatabase.shared, !items.isEmpty else { return items }
        let ids = items.map(\.id)
        let hidden = (try? await Task.detached { try store.notInterested(among: ids) }.value) ?? []
        guard !hidden.isEmpty else { return items }
        return items.filter { !hidden.contains($0.id) }
    }

    func reloadFlagged() async {
        guard let store = CurationDatabase.shared else { flagged = []; return }
        flagged = (try? await Task.detached { try store.flaggedTracks() }.value) ?? []
    }

    private func write(_ item: JellyfinItem, _ body: @escaping @Sendable (CurationStore, String) throws -> Void) async {
        guard let store = CurationDatabase.shared else { return }
        let key = TrackCatalogue.trackRef(for: item, at: Date().millis).contentKey
        do {
            try await Task.detached { try body(store, key) }.value
        } catch {
            log.error("Couldn't save a taste flag: \(error.localizedDescription, privacy: .public)")
        }
        byTrack[item.id] = try? store.flags(for: item.id)
        SyncCoordinator.shared.syncSoon(.localChanges)
    }
}
