import Foundation
import GRDB

public extension CurationStore {
    /// The flags on a track, or nil when nothing has been said about it.
    func flags(for jellyfinId: String) throws -> TrackFlags? {
        try read { db in
            try TrackFlags.filter(Column("jellyfinId") == jellyfinId && Column("deleted") == false).fetchOne(db)
        }
    }

    /// Which of these tracks are marked not interested.
    func notInterested(among jellyfinIds: [String]) throws -> Set<String> {
        guard !jellyfinIds.isEmpty else { return [] }
        return try read { db in
            var found: Set<String> = []
            for chunk in stride(from: 0, to: jellyfinIds.count, by: HistorySQL.maxParameters) {
                let ids = Array(jellyfinIds[chunk..<min(chunk + HistorySQL.maxParameters, jellyfinIds.count)])
                let rows = try String.fetchAll(db, sql: """
                    SELECT jellyfinId FROM trackFlags
                    WHERE deleted = 0 AND notInterested = 1 AND jellyfinId IN (\(Self.placeholders(ids.count)))
                    """, arguments: StatementArguments(ids))
                found.formUnion(rows)
            }
            return found
        }
    }

    /// Every flagged track, with what the track cache knows of it, so a settings
    /// screen can list them and undo one.
    func flaggedTracks() throws -> [(flags: TrackFlags, track: TrackRef?)] {
        try read { db in
            let rows = try TrackFlags
                .filter(Column("deleted") == false)
                .order(Column("updatedAt").desc)
                .fetchAll(db)
            return try rows.map { row in
                (row, try TrackRef.filter(Column("jellyfinId") == row.jellyfinId).fetchOne(db))
            }
        }
    }

    /// Sets one flag, minting the row if needed and deleting it when both flags end
    /// up off — a row that says nothing is not worth syncing.
    @discardableResult
    func setFlag(
        _ keyPath: WritableKeyPath<TrackFlags, Bool>,
        to value: Bool,
        on jellyfinId: String,
        contentKey: String,
        now: Millis = Date().millis
    ) throws -> TrackFlags? {
        var row = try read { db in
            try TrackFlags.filter(Column("jellyfinId") == jellyfinId).fetchOne(db)
        } ?? TrackFlags(jellyfinId: jellyfinId, contentKey: contentKey, updatedAt: now, originDevice: deviceId)
        // A deleted row coming back keeps its id, so the other devices see one row
        // change rather than a delete and a stranger.
        row.deleted = false
        row[keyPath: keyPath] = value
        if row.isEmpty {
            return try record(row, deleted: true, at: now)
        }
        return try record(row, at: now)
    }

    func setNotInterested(_ value: Bool, on jellyfinId: String, contentKey: String, now: Millis = Date().millis) throws {
        try setFlag(\.notInterested, to: value, on: jellyfinId, contentKey: contentKey, now: now)
    }

    func setDontCount(_ value: Bool, on jellyfinId: String, contentKey: String, now: Millis = Date().millis) throws {
        try setFlag(\.dontCount, to: value, on: jellyfinId, contentKey: contentKey, now: now)
    }
}
