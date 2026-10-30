import Foundation
import GRDB

/// Reading and filling the local mirror of the library.
///
/// The `track` table is not a convenience. Two things are built entirely on top of it:
/// a locally stored playlist renders its rows from it when the server can't be
/// reached, and a smart playlist's whole universe *is* it — every rule set compiles to
/// `SELECT t.jellyfinId FROM track t ...`, so a track this table has never heard of
/// cannot match any rule ever written.
///
/// These live here rather than in the app because reaching them needs GRDB, and the
/// app target deliberately does not link it — the packages own the database and the app
/// owns the screens.
public extension CurationStore {
    /// Writes library rows into the cache, in one transaction.
    ///
    /// `writeLocal` rather than `record`, for the same reason the recorder uses it: this
    /// table is a mirror of what the server already holds, rebuilt by each device from
    /// its own connection. Syncing it would dominate the payload and tell the other
    /// devices nothing they couldn't ask the server themselves.
    ///
    /// One transaction for the whole batch rather than one per row. An index pass over a
    /// large library is thousands of rows, and a transaction each turns a single fsync
    /// into thousands of them — the difference between a pass that finishes while the
    /// screen is open and one that doesn't.
    func cacheTracks(_ tracks: [TrackRef]) throws {
        guard !tracks.isEmpty else { return }
        try writeLocal { db in
            for track in tracks { try track.save(db) }
        }
    }

    /// Cached rows for these ids, keyed by id. Ids with nothing cached are simply
    /// absent — the caller has to render *something* for them either way, and an empty
    /// placeholder row is more honest than a fabricated one.
    func cachedTracks(jellyfinIds: [String]) throws -> [String: TrackRef] {
        guard !jellyfinIds.isEmpty else { return [:] }
        return try read { db in
            var found: [String: TrackRef] = [:]
            // Chunked for the reason spelled out on `HistorySQL.maxParameters`: a
            // playlist's id list goes straight into an `IN (...)`, and SQLite on the
            // iOS versions in play caps host parameters at 999.
            for chunk in stride(from: 0, to: jellyfinIds.count, by: HistorySQL.maxParameters) {
                let ids = Array(jellyfinIds[chunk..<min(chunk + HistorySQL.maxParameters, jellyfinIds.count)])
                for row in try TrackRef.filter(keys: ids).fetchAll(db) {
                    found[row.jellyfinId] = row
                }
            }
            return found
        }
    }

    /// How many tracks the cache knows about — the size of every smart playlist's
    /// universe, and nothing more than that.
    ///
    /// Not the way to ask whether the index has run, however much it looks like it.
    /// Playback and adding to a playlist both write rows here, so this is non-zero long
    /// before any pass has walked the library; `libraryIndexedAt` is the question that
    /// tells an unbuilt index from rules that genuinely have no hits.
    func cachedTrackCount() throws -> Int {
        try read { db in try TrackRef.fetchCount(db) }
    }

    /// Drops cached rows a completed index pass didn't see, and says how many went.
    ///
    /// The counterpart to `cacheTracks`, and the only reader `lastSeenAt` has ever had.
    /// Without it this table is append-only, and two things break the first time a
    /// rescan mints new ids for files that moved — the case the whole
    /// content-key apparatus exists for. `relinkItemsAgainstTrackCache` still finds the
    /// retired id sitting in the cache, concludes it is `live`, and repairs nothing. And
    /// every smart playlist, whose universe *is* this table, then evaluates against a
    /// doubled library: half the ids resolve to nothing on the server, so "Most Played"
    /// fills with rows that say "Unavailable right now", and the plays that would have
    /// disqualified a track from "Never Played" are filed under the id nobody selects
    /// any more.
    ///
    /// A hard `DELETE`, which is only correct because this table is local — the mirror
    /// each device rebuilds from its own connection, never synced, carrying no op. The
    /// caller owes it a cutoff from *before* the pass began and a pass that actually
    /// finished; pruning after a half-walked library would delete songs that are still
    /// there. See `SongIndexer`.
    @discardableResult
    func pruneTracks(notSeenSince cutoff: Millis) throws -> Int {
        try writeLocal { db in
            try TrackRef.filter(Column("lastSeenAt") < cutoff).deleteAll(db)
        }
    }

    /// When a full library index last finished on this device, if one ever has.
    ///
    /// Stored rather than inferred from the cache being non-empty, which is the question
    /// this used to be asked as and is not the same question. The recorder writes a
    /// `track` row for every song *started* and adding to a playlist writes one per song,
    /// so three plays on a fresh install make the cache non-empty — and an automatic
    /// index that skips on that leaves every smart playlist matching against a universe
    /// of three songs while saying "nothing fits these rules". Telling "the index hasn't
    /// run" from "the rules genuinely have no hits" is the entire reason the index pass
    /// exists, and only a mark left by the pass itself can do it.
    ///
    /// The instant rather than a flag because it lives in the database it describes:
    /// anybody opening the file can see when this cache was last known to be whole.
    func libraryIndexedAt() throws -> Millis? {
        // Read back as text and parsed here: `syncState.value` is a TEXT column shared
        // with the sync cursor, and GRDB will not silently reinterpret a string as an
        // integer — which is the behaviour worth keeping.
        let stored = try read { db in
            try String.fetchOne(db, sql: "SELECT value FROM syncState WHERE key = ?", arguments: [Self.indexKey])
        }
        return stored.flatMap(Millis.init)
    }

    /// Records that a full pass completed. Written only by a pass that walked every
    /// library without erroring out — see `libraryIndexedAt`.
    func recordLibraryIndex(at now: Millis = Date().millis) throws {
        try writeLocal { db in
            try db.execute(
                sql: "INSERT INTO syncState (key, value) VALUES (?, ?) " +
                     "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                arguments: [Self.indexKey, String(now)]
            )
        }
    }

    private static let indexKey = "trackIndexCompletedAt"
}
