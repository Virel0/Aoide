import Foundation

/// Why an op can never be synced.
///
/// Every case here is permanent. Nothing that might succeed on the next attempt —
/// a timeout, a 500, no network — belongs in this type; those are ordinary errors
/// and the op stays pending. A fault means the op is dead, and the only useful
/// things left to do with it are to stop retrying it and to say why.
public enum SyncFault: Error, Hashable, Sendable {
    case emptyOpId
    case opIdTooLong(Int)
    case emptyEntityId
    case entityIdTooLong(Int)
    case nonPositiveTimestamp(Millis)
    /// Includes `track`, which has no wire name because it is never synced.
    case unknownEntity(String)
    case unknownOperation(String)
    case payloadTooLarge(bytes: Int)
    case payloadNotAnObject
    /// The op and its payload disagree about which row this is.
    case identityMismatch(entityId: String, payloadId: String?)
    case deleteWithoutFlag
    case undecodablePayload(String)
    case appendOnlyDelete
    /// The server said no. It will say no again, forever.
    case serverRejected(String)

    /// The server *threw* on this op — a 5xx, not a refusal.
    ///
    /// Alone among these cases this is a fault in the server rather than in the op,
    /// so it is the one thing here that may stop being true and the one worth
    /// offering to try again. It is still quarantined rather than left queued: a
    /// batch that 500s takes every op in it down with it, so leaving the offender in
    /// the queue blocks every innocent change behind it indefinitely.
    case serverFaulted(status: Int)

    /// Stored in the quarantine table and shown to whoever has to work out what
    /// happened, so it names the value that was wrong rather than only the rule.
    public var reason: String {
        switch self {
        case .emptyOpId:
            "op id is empty"
        case .opIdTooLong(let length):
            "op id is \(length) characters; the server accepts \(SyncPolicy.maxOpIdLength)"
        case .emptyEntityId:
            "entity id is empty"
        case .entityIdTooLong(let length):
            "entity id is \(length) characters; the server accepts \(SyncPolicy.maxEntityIdLength)"
        case .nonPositiveTimestamp(let value):
            "createdAt is \(value); the server requires a positive millisecond timestamp"
        case .unknownEntity(let name):
            "'\(name)' is not an entity this build can sync"
        case .unknownOperation(let name):
            "'\(name)' is not an operation; the server accepts lowercase upsert or delete"
        case .payloadTooLarge(let bytes):
            "payload is \(bytes) bytes; the server accepts \(SyncPolicy.maxPayloadBytes)"
        case .payloadNotAnObject:
            "payload is not a JSON object"
        case .identityMismatch(let entityId, let payloadId):
            "entity id '\(entityId)' does not match the payload's '\(payloadId ?? "<missing>")'"
        case .deleteWithoutFlag:
            "a delete op must carry a payload with deleted set"
        case .undecodablePayload(let detail):
            "payload does not decode into the local row: \(detail)"
        case .appendOnlyDelete:
            "play events are append-only and cannot be deleted"
        case .serverRejected(let detail):
            "rejected by the server: \(detail)"
        case .serverFaulted(let status):
            "the server failed while storing this change (HTTP \(status))"
        }
    }
}

/// A sync that failed as a whole, rather than one op that will never work.
public enum SyncError: Error, Hashable, Sendable {
    /// Another sync is in flight. See `SyncEngine.sync()` for why this is an error
    /// rather than a wait.
    case alreadyRunning
    /// A push round trip changed nothing: the same ops came back pending, none were
    /// accepted, none were rejected. Continuing would spin forever.
    case pushStalled(pending: Int)
}

/// The numbers the engine works to, and why each one is what it is.
///
/// A value type rather than a set of constants so tests can shrink the batch sizes
/// and exercise the loops without manufacturing thousands of rows.
public struct SyncPolicy: Hashable, Sendable {
    /// Ops per push request.
    ///
    /// The server's ceiling is 1000 and a batch over it is a 400 for the *whole*
    /// push, so the ceiling is not the number to choose. 250 is, for two reasons.
    /// Size: a queue_state payload carries up to 500 track ids, so a batch of these
    /// is roughly 20 KB each — 1000 of them is a 20 MB request from a phone, and one
    /// timeout re-sends all of it. And durability is per batch — one fsync, `accepted`
    /// means on disk — so a dropped connection loses a quarter as much work at 250 as
    /// it would at the limit. The cost is more round trips, which only matters for a
    /// first sync on a device with a long history, and that one is slow anyway.
    public var pushBatchSize: Int = 250

    /// Ops per pull request. The server's own default, clamped there to 1000.
    ///
    /// Bigger than the push batch because an inbound batch is applied in one local
    /// transaction and never re-uploaded, so the failure cost is a replay of work
    /// already done rather than a retransmission.
    public var pullLimit: Int = 500

    /// How far ahead of *both* the server's receipt time and this device's own clock a
    /// timestamp may sit before it is treated as a broken clock rather than a genuinely
    /// newer write. Both, because one reference alone cannot tell a fast client from a
    /// slow server — see `InboundApplier.isCredible`.
    ///
    /// Only the future direction is suspicious. An op written offline and pushed
    /// days later is *normal* and its `createdAt` is legitimately far in the past;
    /// correcting that would throw away the ordering the whole design depends on.
    /// Five minutes is orders of magnitude beyond the drift of a device that talks to
    /// any time server, and orders of magnitude below the hours-to-years a device
    /// with a genuinely wrong clock is out by — so nothing legitimate is caught and
    /// nothing broken escapes.
    public var clockSkewToleranceMs: Millis = 5 * 60 * 1000

    public init(
        pushBatchSize: Int = 250,
        pullLimit: Int = 500,
        clockSkewToleranceMs: Millis = 5 * 60 * 1000
    ) {
        // Clamped rather than trusted: a caller passing 2000 would turn every push
        // into a 400 that rejects valid ops along with everything else.
        self.pushBatchSize = min(max(1, pushBatchSize), Self.maxBatch)
        self.pullLimit = min(max(1, pullLimit), Self.maxPullLimit)
        self.clockSkewToleranceMs = max(0, clockSkewToleranceMs)
    }

    public static let `default` = SyncPolicy()

    // The server's limits. Not configurable, because they are not ours.
    public static let maxBatch = 1000
    public static let maxPullLimit = 1000
    public static let maxPayloadBytes = 256 * 1024
    public static let maxOpIdLength = 128
    public static let maxEntityIdLength = 256
}
