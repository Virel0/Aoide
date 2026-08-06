import Foundation
import GRDB

public extension CurationStore {
    /// How many ops are waiting to be pushed.
    ///
    /// Counted rather than fetched: the number is for a screen, and `pendingOps`
    /// would decode every row to answer it.
    func pendingOpCount() throws -> Int {
        try read { db in try Op.filter(Column("synced") == false).fetchCount(db) }
    }

    /// The pending count, now and after every change to the queue.
    ///
    /// Observed rather than announced by the writers, and that is the whole reason it
    /// is here. Every syncable write already goes through `record` or `append`, but
    /// there are a dozen call sites for those and the thirteenth — written months from
    /// now by someone who has not read this file — would be a change that quietly
    /// never syncs, with nothing to notice it by. A table cannot forget to mention
    /// that it grew.
    ///
    /// Bridged to `AsyncStream` rather than handing back GRDB's own sequence so that
    /// the app target never has to import GRDB. It also swallows observation errors:
    /// the caller is a status display, and a failed *count* is not worth a second
    /// error path next to the sync failures it is already showing.
    func pendingOpCounts() -> AsyncStream<Int> {
        let observation = ValueObservation.tracking { db in
            try Op.filter(Column("synced") == false).fetchCount(db)
        }
        let reader = databaseQueue
        return AsyncStream { continuation in
            let task = Task {
                do {
                    for try await count in observation.values(in: reader) {
                        continuation.yield(count)
                    }
                } catch {}
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The Jellyfin user whose library this store holds, if it has been claimed.
    func accountId() throws -> String? {
        try read { db in
            try String.fetchOne(db, sql: "SELECT value FROM syncState WHERE key = 'account'")
        }
    }

    /// Claims the store for `accountId`, erasing it first if it belonged to somebody else.
    ///
    /// Returns whether it erased.
    ///
    /// The pull cursor is the sharp edge. It is a position in *one user's* log, and
    /// the sidecar scopes its sequences per user — so carrying a cursor of 4000 into
    /// a second account skips that account's first four thousand ops permanently, and
    /// nothing ever offers them again. Erasing the rows and keeping the cursor would
    /// be the worst of both.
    ///
    /// Everything else goes with it because it is all one account's: the previous
    /// user's playlists and history would otherwise be visible to whoever signs in
    /// next, and — worse — their unpushed ops would still be pending, so the first
    /// sync would push one person's library into another person's log.
    ///
    /// Deliberately *not* called on sign-out. Signing out and back in as the same
    /// person is the ordinary case (an expired token does it by itself), and the
    /// local store is the only copy of anything not yet pushed. Erasing on the way
    /// out would throw that away every time; erasing on the way in throws it away
    /// only when it has genuinely become somebody else's problem.
    ///
    /// A store with no `account` key is claimed without erasing, and that is a real
    /// trade rather than an oversight. Every store written by a build older than this
    /// one is unclaimed while already holding somebody's library, so "unclaimed means
    /// erase" would wipe the entire local history of anyone who happened to be signed
    /// out when they updated and then signed back in as themselves — which is the
    /// ordinary case, and on those builds nothing had ever been pushed, so the local
    /// copy was the only copy. Keeping is the smaller loss. The residual risk is one
    /// update window wide: signed out across the update, then a *different* user signs
    /// in, and they inherit the previous user's rows.
    @discardableResult
    func adoptAccount(_ accountId: String) throws -> Bool {
        // The claim already stands on every launch after the first, and this is called
        // on the main actor before anything can play — so the common path should not
        // open a write transaction at all. Only a fast path: the decision is made again
        // inside the transaction, where it cannot race.
        guard try self.accountId() != accountId else { return false }

        return try writeLocal { db in
            let previous = try String.fetchOne(db, sql: "SELECT value FROM syncState WHERE key = 'account'")
            let mustErase = previous != nil && previous != accountId

            if mustErase {
                // Children before parents: `PRAGMA foreign_keys` is on, and this
                // ordering is correct whether or not the schema declares the
                // relationships it describes.
                for table in ["playlistItem", "playlist", "folder", "like", "playEvent",
                              "queueState", "op", "quarantinedOp", "track"] {
                    try db.execute(sql: "DELETE FROM \(table)")
                }
                // The whole table, not the cursor row. Every key in here describes the
                // account or the data that just went with it, and naming them
                // individually means the next one added survives an account change by
                // default — which is how `trackIndexCompletedAt` came to outlive the
                // `track` rows it vouches for. That combination is invisible and
                // unrecoverable from inside the app: `indexIfNeeded` reads the mark,
                // concludes the library has been walked, and never runs again, so
                // every smart playlist evaluates against an empty universe and reports
                // that the rules have no hits. Erase-by-default, and `account` is
                // written back immediately below.
                try db.execute(sql: "DELETE FROM syncState")
            }

            guard previous != accountId else { return false }
            try db.execute(
                sql: "INSERT INTO syncState (key, value) VALUES ('account', ?) " +
                     "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                arguments: [accountId]
            )
            return mustErase
        }
    }
}
