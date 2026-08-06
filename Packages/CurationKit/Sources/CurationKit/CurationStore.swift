import Foundation
import GRDB

/// The local source of truth for playlists, likes, history and queue state.
///
/// Every read and write hits SQLite, never the network. Offline is not a degraded
/// mode here; it is the normal one that sometimes also syncs.
public final class CurationStore: Sendable {
    private let dbQueue: DatabaseQueue
    /// Stamped onto every row this device writes, and the tiebreak when two devices
    /// change the same field within the same millisecond.
    public let deviceId: String

    /// Opens the store at `url`, creating and migrating it as needed.
    public init(url: URL, deviceId: String) throws {
        var configuration = Configuration()
        // Better concurrency and crash-durability than the rollback journal, and the
        // difference matters here: playback writes history while the UI reads it.
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            // Off by default in SQLite, and this schema leans on them: a playlist
            // item pointing at a deleted playlist is not a state worth being able
            // to represent.
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        dbQueue = try DatabaseQueue(path: url.path, configuration: configuration)
        self.deviceId = deviceId
        try Schema.migrator.migrate(dbQueue)
    }

    /// An in-memory store, for tests.
    public static func inMemory(deviceId: String = "test-device") throws -> CurationStore {
        try CurationStore(memory: (), deviceId: deviceId)
    }

    private init(memory: Void, deviceId: String) throws {
        dbQueue = try DatabaseQueue()
        self.deviceId = deviceId
        try Schema.migrator.migrate(dbQueue)
    }

    // MARK: - Access

    public func read<T>(_ body: @Sendable (Database) throws -> T) throws -> T {
        try dbQueue.read(body)
    }

    /// A write that does **not** record an op. Only correct for the track cache and
    /// other purely local state; anything syncable must go through `record`.
    public func writeLocal<T>(_ body: @Sendable (Database) throws -> T) throws -> T {
        try dbQueue.write(body)
    }

    /// The queue itself. Internal, and only for the one thing a closure over
    /// `Database` cannot express: GRDB's own change observation, which has to be
    /// handed a reader so it can watch commits rather than answer one question.
    var databaseQueue: DatabaseQueue { dbQueue }

    // MARK: - Recording changes

    /// Saves a syncable row and its op in one transaction.
    ///
    /// The single entry point for every syncable mutation, and the reason it exists
    /// is atomicity: a row saved without its op is a change that silently never
    /// leaves this device, and there is nothing later that can detect it happened.
    /// Making the two inseparable is cheaper than any reconciliation would be.
    @discardableResult
    public func record<Record>(
        _ record: Record,
        deleted: Bool = false,
        at now: Millis = Date().millis
    ) throws -> Record where Record: PersistableRecord & Encodable & Syncable {
        var row = record
        row.updatedAt = now
        row.deleted = deleted
        row.originDevice = deviceId

        let payload = try Self.json(row)
        let op = Op(
            entity: Record.databaseTableName,
            entityId: row.id,
            operation: deleted ? .delete : .upsert,
            payload: payload,
            createdAt: now
        )

        try dbQueue.write { db in
            try row.save(db)
            try op.insert(db)
        }
        return row
    }

    /// Appends a play event and its op.
    ///
    /// Separate from `record` because history is append-only: events are never
    /// edited, so they carry no `updatedAt`, `deleted` or conflict resolution. That
    /// also makes them the one thing here that cannot conflict during sync.
    @discardableResult
    public func append(_ event: PlayEvent) throws -> PlayEvent {
        let op = Op(
            entity: PlayEvent.databaseTableName,
            entityId: event.id,
            operation: .upsert,
            payload: try Self.json(event),
            createdAt: event.startedAt
        )
        try dbQueue.write { db in
            try event.insert(db)
            try op.insert(db)
        }
        return event
    }

    // MARK: - Sync plumbing

    /// Ops waiting to be pushed, oldest first.
    public func pendingOps(limit: Int = 500) throws -> [Op] {
        try dbQueue.read { db in
            try Op.filter(Column("synced") == false)
                .order(Column("createdAt"))
                .limit(limit)
                .fetchAll(db)
        }
    }

    /// Marks ops the server acknowledged.
    ///
    /// Acknowledgement is by `opId`, which the client generated, so re-pushing after
    /// a timeout is safe — and a client *will* re-push after a timeout.
    public func markSynced(_ opIds: [String]) throws {
        guard !opIds.isEmpty else { return }
        try dbQueue.write { db in
            try Op.filter(keys: opIds).updateAll(db, Column("synced").set(to: true))
        }
    }

    public func syncCursor() throws -> String? {
        try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM syncState WHERE key = 'cursor'")
        }
    }

    /// Stored only after a whole pulled batch has been applied, so an interrupted
    /// sync replays rather than skips.
    public func setSyncCursor(_ cursor: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO syncState (key, value) VALUES ('cursor', ?) " +
                     "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                arguments: [cursor]
            )
        }
    }

    /// The encoding for every op payload in this package.
    ///
    /// Internal rather than private because the tables that cannot go through `record`
    /// — `playEvent` amendments and `queueState` — build their own ops and must encode
    /// them identically. Three private copies of "remember `.sortedKeys`" is three
    /// places for one of them to forget.
    static func json(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        // Stable key order: payloads are compared and logged, and a dictionary's
        // iteration order would make identical rows look different.
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}
