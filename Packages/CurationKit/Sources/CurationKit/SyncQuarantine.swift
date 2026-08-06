import Foundation
import GRDB

/// Which way an op was travelling when it died.
public enum SyncDirection: String, Codable, Hashable, Sendable {
    /// Ours, and either invalid before it left or refused by the server.
    case outbound
    /// Somebody else's, and unapplicable here.
    case inbound
}

/// An op that can never succeed, kept out of the way but not thrown away.
public struct QuarantinedOp: Codable, FetchableRecord, PersistableRecord, Hashable, Sendable {
    public static let databaseTableName = "quarantinedOp"

    public var opId: String
    /// Spelled as it arrived — the local table name for an outbound op, the wire
    /// name for an inbound one. Not normalised, because for the case this table
    /// exists to explain the unrecognised spelling *is* the finding.
    public var entity: String
    public var entityId: String
    public var direction: String
    public var reason: String
    /// Kept whole. Deleting the payload would make the failure undiagnosable from
    /// the device it happened on, and it is the only copy an inbound op has once the
    /// cursor has moved past it.
    public var payload: String
    public var quarantinedAt: Millis

    public init(
        opId: String,
        entity: String,
        entityId: String,
        direction: SyncDirection,
        reason: String,
        payload: String,
        quarantinedAt: Millis
    ) {
        self.opId = opId
        self.entity = entity
        self.entityId = entityId
        self.direction = direction.rawValue
        self.reason = reason
        self.payload = payload
        self.quarantinedAt = quarantinedAt
    }

    public var syncDirection: SyncDirection? { SyncDirection(rawValue: direction) }
}

// MARK: - Store

public extension CurationStore {
    /// Everything quarantined, newest first, so a diagnostics screen can be honest
    /// about what is not syncing.
    func quarantinedOps(limit: Int = 200) throws -> [QuarantinedOp] {
        try read { db in
            try QuarantinedOp
                .order(Column("quarantinedAt").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    func quarantineCount() throws -> Int {
        try read { db in try QuarantinedOp.fetchCount(db) }
    }

    /// Forgets quarantined ops. Nothing re-queues them: an op reaches this table
    /// only when retrying it is known to be pointless, so the only thing left to
    /// decide is whether the record of it is still worth keeping.
    func discardQuarantined(_ opIds: [String]) throws {
        guard !opIds.isEmpty else { return }
        try writeLocal { db in
            _ = try QuarantinedOp.deleteAll(db, keys: opIds)
        }
    }

    func discardAllQuarantined() throws {
        try writeLocal { db in
            _ = try QuarantinedOp.deleteAll(db)
        }
    }

    /// The pull cursor, typed.
    ///
    /// Reads the same `syncState` row the untyped accessor does; the type is the
    /// point, since it is the only thing standing between this row and a push
    /// cursor being written into it.
    func pullCursor() throws -> PullCursor? {
        guard let stored = try syncCursor(), let value = Int64(stored) else { return nil }
        return PullCursor(value)
    }
}

extension CurationStore {
    /// Moves an op out of the outbound queue and into quarantine, in one transaction.
    ///
    /// Moved, not flagged. An op that can never be accepted has to stop being
    /// pending or every push retries it forever and nothing queued behind it ever
    /// goes out — the queue is ordered, and one dead row at the head stops the lot.
    /// Marking it `synced` was the cheaper option and is a lie: it claims the server
    /// has a row the server refused, and the next person to read the table believes
    /// it.
    func quarantine(_ op: Op, reason: SyncFault, at now: Millis) throws {
        try writeLocal { db in
            try QuarantinedOp(
                opId: op.opId,
                entity: op.entity,
                entityId: op.entityId,
                direction: .outbound,
                reason: reason.reason,
                payload: op.payload,
                quarantinedAt: now
            ).save(db)
            _ = try Op.deleteOne(db, key: op.opId)
        }
    }

    /// Overwrites the pull cursor. Internal on purpose: the only correct place to
    /// advance it is inside the transaction that applied the batch it describes,
    /// which is `apply(_:advancingTo:policy:now:)`.
    static func writePullCursor(_ cursor: PullCursor, to db: Database) throws {
        try db.execute(
            sql: "INSERT INTO syncState (key, value) VALUES ('cursor', ?) " +
                 "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            arguments: [String(cursor.value)]
        )
    }
}
