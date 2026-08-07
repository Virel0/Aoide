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
    /// `upsert` or `delete`. Absent on rows quarantined before v5, which therefore
    /// cannot be put back in the queue.
    public var operation: String?
    /// When the change was originally made, not when it was quarantined.
    public var createdAt: Millis?

    /// Whether this can be handed back to the outbound queue.
    ///
    /// Only a server fault, and only outbound: everything else here is permanent by
    /// definition, and an inbound op has no queue to return to — the pull cursor
    /// moved past it and the server will not offer it again.
    public var isRetryable: Bool {
        syncDirection == .outbound
            && operation != nil
            && createdAt != nil
            && reason.contains("the server failed")
    }

    public init(
        opId: String,
        entity: String,
        entityId: String,
        direction: SyncDirection,
        reason: String,
        payload: String,
        quarantinedAt: Millis,
        operation: String? = nil,
        createdAt: Millis? = nil
    ) {
        self.opId = opId
        self.entity = entity
        self.entityId = entityId
        self.direction = direction.rawValue
        self.reason = reason
        self.operation = operation
        self.createdAt = createdAt
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
                quarantinedAt: now,
                operation: op.operation,
                createdAt: op.createdAt
            ).save(db)
            _ = try Op.deleteOne(db, key: op.opId)
        }
    }

    /// Puts server-faulted ops back in the outbound queue.
    ///
    /// Only for `serverFaulted`, and that restriction is the whole point: every other
    /// reason here is a statement about the op, which no amount of retrying changes.
    /// A 5xx is a statement about the server, and servers get fixed — so this is the
    /// one case where holding the change rather than discarding it was worth the
    /// columns it costs.
    ///
    /// Returns how many actually went back, which is not always how many were asked
    /// for: rows quarantined before those columns existed cannot be rebuilt.
    @discardableResult
    public func requeueQuarantined(_ opIds: [String]? = nil) throws -> Int {
        try writeLocal { db in
            var candidates = try QuarantinedOp.fetchAll(db)
            if let opIds { candidates = candidates.filter { opIds.contains($0.opId) } }

            var moved = 0
            for held in candidates where held.isRetryable {
                guard let operation = held.operation.flatMap(Op.Kind.init(rawValue:)),
                      let createdAt = held.createdAt
                else { continue }

                try Op(
                    opId: held.opId,
                    entity: held.entity,
                    entityId: held.entityId,
                    operation: operation,
                    payload: held.payload,
                    createdAt: createdAt
                ).insert(db)
                _ = try QuarantinedOp.deleteOne(db, key: held.opId)
                moved += 1
            }
            return moved
        }
    }

    /// How many are worth offering a retry for.
    public func retryableQuarantineCount() throws -> Int {
        try read { db in try QuarantinedOp.fetchAll(db).count(where: \.isRetryable) }
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
