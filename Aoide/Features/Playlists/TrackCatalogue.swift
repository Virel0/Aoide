import CurationKit
import Foundation
import JellyfinKit
import os

/// Turns Jellyfin items into local track-cache rows, and fills that cache from the
/// library.
///
/// Until this existed the cache filled itself from playback alone — the recorder writes
/// one row per track *started*. That is enough for history, and quietly wrong for smart
/// playlists: their universe is this table, so "songs I have never played" would have
/// matched nothing at all, and a playlist that is empty because the index is empty looks
/// exactly like one whose rules genuinely have no hits. Indexing the library up front is
/// what makes the difference between the two visible.
enum TrackCatalogue {
    /// Shared with `SongIndexer`'s detached tidy-up, which cannot reach that class's own
    /// logger — it is isolated to the main actor and the tidy-up deliberately is not.
    static let log = Logger(subsystem: AppIdentity.bundle, category: "curation")

    /// The single definition of what a `TrackRef` for a Jellyfin item looks like.
    ///
    /// Shared with `PlaybackContext` rather than written twice, because the field that
    /// matters most here is the content key: it is what a playlist entry survives a
    /// library rescan by, and two derivations that disagree by one character mean an
    /// entry that can never be relinked.
    static func trackRef(for item: JellyfinItem, at now: Millis) -> TrackRef {
        // The *track* artist first, not the album artist. Recaps group plays by this
        // column, and crediting every song on a compilation to "Various Artists" would
        // make it the loudest entry of the year while saying nothing about anyone's
        // listening. `albumArtist` keeps its own column, which is what album grouping
        // reads.
        let artist = item.artists.first ?? item.albumArtist ?? "Unknown Artist"
        let album = item.album ?? ""
        // Jellyfin measures in 100-nanosecond ticks, so this divides exactly rather than
        // round-tripping through `Duration` and its floating-point seconds.
        let durationMs = item.runTimeTicks.map { Int($0 / 10_000) }

        return TrackRef(
            jellyfinId: item.id,
            contentKey: ContentKey.make(
                artist: artist,
                album: album,
                title: item.name,
                durationMs: durationMs
            ),
            title: item.name,
            artist: artist,
            album: album,
            albumArtist: item.albumArtist,
            albumId: item.albumId,
            durationMs: durationMs,
            year: item.productionYear,
            genres: item.genres,
            lastSeenAt: now
        )
    }

    /// Files these items in the local cache. Non-audio items are skipped — an album or
    /// an artist row in the track table would be matched by every rule about a song.
    ///
    /// `nonisolated` and taking the store as a parameter so it can be called from a
    /// detached task: this writes to SQLite, which blocks the thread it runs on, and the
    /// main actor is where the queue and every screen live.
    static func remember(_ items: [JellyfinItem], in store: CurationStore) {
        let now = Date().millis
        let rows = items.filter { $0.type == .audio }.map { trackRef(for: $0, at: now) }
        guard !rows.isEmpty else { return }
        do {
            try store.cacheTracks(rows)
        } catch {
            // Never fatal. A missing cache row costs a smart playlist one candidate and a
            // playlist row its offline title; it is not worth failing whatever the
            // listener was actually doing.
            log.error("Couldn't cache \(rows.count, privacy: .public) tracks: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// Walks the whole library once and files every song in the local cache.
///
/// Shared rather than per-view: the pass has to survive the listener navigating away
/// from the screen that started it, or an index of a large library could never finish.
@MainActor
@Observable
final class SongIndexer {
    static let shared = SongIndexer()

    enum State: Equatable {
        case idle
        /// `indexed` counts songs written so far. There is no total: Jellyfin reports one
        /// per library and the pass spans all of them, so a percentage would jump
        /// backwards at each library boundary. A rising count never lies.
        case running(indexed: Int)
        case finished(indexed: Int)
        case failed(String)
    }

    private(set) var state: State = .idle

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    private let log = Logger(subsystem: AppIdentity.bundle, category: "curation")
    /// Jellyfin pages happily at this size, and it keeps each write transaction to
    /// something that finishes between two frames of the progress row.
    private let pageSize = 500

    private init() {}

    /// Runs the pass only if one has never finished on this device.
    ///
    /// The condition is "never indexed", not "stale" and emphatically not "the cache is
    /// empty". A full re-index is the listener's decision — it is a lot of requests — but
    /// an index that has never run is not a state worth showing anybody, because every
    /// smart playlist built on top of it is empty too and gives no hint why.
    ///
    /// Asking whether the cache was empty was the same question phrased wrongly, and it
    /// meant this never fired for anybody who had played a song first: the recorder
    /// writes a `track` row per song started, so one play is enough to make the cache
    /// non-empty and leave every rule matching against a universe of one.
    func indexIfNeeded(library: LibraryStore) async {
        guard !isRunning, let store = CurationDatabase.shared else { return }
        let alreadyIndexed = await Task.detached {
            ((try? store.libraryIndexedAt()) ?? nil) != nil
        }.value
        guard !alreadyIndexed else { return }
        await index(library: library)
    }

    /// A week: long enough that the pass is rare, short enough that an album added
    /// on the server is in the smart playlists' universe by the weekend.
    static let staleAfter: Millis = 7 * 24 * 60 * 60 * 1000

    /// Runs the pass if it has never run, or not for a week.
    ///
    /// The mix screen, the smart playlists and Home's Rediscover shelf all match
    /// against this cache, and a cache that stopped a month ago silently shrinks
    /// every one of them to the library as it was. Called at launch, in the
    /// background, where its requests cost nobody a wait.
    func indexIfStale(library: LibraryStore, now: Millis = Date().millis) async {
        guard !isRunning, let store = CurationDatabase.shared else { return }
        let indexedAt: Millis? = await Task.detached { (try? store.libraryIndexedAt()) ?? nil }.value
        if let indexedAt, now - indexedAt < Self.staleAfter { return }
        await index(library: library)
    }

    func index(library: LibraryStore) async {
        guard !isRunning else { return }
        guard let store = CurationDatabase.shared else {
            state = .failed("The local library index isn't available on this device.")
            return
        }

        state = .running(indexed: 0)
        var indexed = 0
        // Taken before the first request, so every row this pass touches ends up with a
        // `lastSeenAt` at or after it and only rows the server stopped returning fall
        // below. Reading the clock afterwards would leave the whole pass on the wrong
        // side of its own cutoff.
        let startedAt = Date().millis
        // An empty scope means the libraries couldn't be resolved; the unscoped query is
        // what every other screen falls back to, so this matches rather than giving up.
        let ids = await library.musicLibraryScope()
        let scope: [String?] = ids.isEmpty ? [nil] : ids.map { $0 }

        for parentId in scope {
            guard await indexLibrary(parentId, from: library, into: store, indexed: &indexed) else { return }
        }

        log.info("Indexed \(indexed, privacy: .public) songs for smart playlists")
        state = .finished(indexed: indexed)

        // Only a pass that walked every library to the end gets to say what the cache
        // should contain, which is why neither of these runs on the cancelled or failed
        // paths above — they return before here.
        //
        // The `indexed > 0` guard is the one case a completed pass still can't be
        // trusted: a server that answers every page with nothing looks identical to a
        // library that really is empty, and pruning on that would wipe the cache and
        // strand every playlist entry as "not in your library any more".
        guard indexed > 0 else { return }

        await Task.detached { SongIndexer.finishIndex(in: store, startedAt: startedAt) }.value
    }

    /// Indexes every song in one library, page by page, adding to `indexed` as it
    /// goes. Returns false when the pass has to stop — cancelled or failed — with
    /// `state` already saying which.
    private func indexLibrary(
        _ parentId: String?,
        from library: LibraryStore,
        into store: CurationStore,
        indexed: inout Int
    ) async -> Bool {
        var startIndex = 0
        while true {
            do {
                let page = try await library.songsBatch(
                    parentId: parentId,
                    startIndex: startIndex,
                    limit: pageSize
                )
                guard !page.items.isEmpty else { break }

                // Detached: the write blocks its thread, and this loop is running on
                // the main actor because the client and the library store are.
                let items = page.items
                await Task.detached { TrackCatalogue.remember(items, in: store) }.value

                indexed += page.items.count
                state = .running(indexed: indexed)
                startIndex += page.items.count

                // The server said that was the last of them. Trusting the count
                // rather than waiting for an empty page saves one round trip per
                // library, and an over-reported total would still terminate on the
                // empty page above.
                if page.totalRecordCount > 0, startIndex >= page.totalRecordCount { break }
            } catch is CancellationError {
                // Half an index is still better than none, and the rows already
                // written are correct. Report where it got to rather than an error
                // the listener can do nothing about.
                state = .finished(indexed: indexed)
                return false
            } catch {
                log.error("Song index failed at \(startIndex, privacy: .public): \(error.localizedDescription, privacy: .public)")
                state = .failed(
                    (error as? JellyfinError)?.errorDescription ?? error.localizedDescription
                )
                return false
            }
        }
        return true
    }

    /// Prunes the tracks the pass did not see, relinks playlist entries, and marks
    /// the index done — in that order. Runs off the main actor: every step is a
    /// blocking write.
    nonisolated private static func finishIndex(in store: CurationStore, startedAt: Millis) {
        do {
            // Before the relink, always. Relinking asks the cache "is this id still
            // live", and until the retired ids are gone the answer is yes for every
            // one of them — which is how the repair below came to be inert in
            // exactly the situation it was written for.
            let removed = try store.pruneTracks(notSeenSince: startedAt)
            if removed > 0 { TrackCatalogue.log.info("Pruned \(removed, privacy: .public) tracks the server no longer lists") }

            // The documented moment to run this. A Jellyfin rescan mints new item
            // ids for files that moved, which leaves every playlist entry pointing
            // at nothing; the cache has just been rebuilt from the ids that exist
            // *now*, so this is when those entries can be matched back by
            // fingerprint. Nothing is said about it unless something changed — a
            // silent repair is the point.
            let report = try store.relinkItemsAgainstTrackCache()
            if report.changed > 0 {
                TrackCatalogue.log.info("""
                    Relinked playlist entries: \(report.relinked, privacy: .public) moved, \
                    \(report.recovered, privacy: .public) recovered, \
                    \(report.unresolved, privacy: .public) still missing
                    """)
            }

            // Last, and only if the two above survived: this is the mark that stops
            // `indexIfNeeded` running again, so writing it after a failed tidy-up
            // would leave a half-repaired cache nothing would ever come back to.
            try store.recordLibraryIndex(at: startedAt)
        } catch {
            TrackCatalogue.log.error("Couldn't finish the song index: \(error.localizedDescription, privacy: .public)")
        }
    }
}
