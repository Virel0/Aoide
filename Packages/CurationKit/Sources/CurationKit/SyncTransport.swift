import Foundation

// MARK: - Cursors

/// How far this device has *read* the server's log. The one that gets persisted.
public struct PullCursor: Hashable, Sendable, Codable, CustomStringConvertible {
    public let value: Int64

    public init(_ value: Int64) { self.value = value }

    public init(from decoder: any Decoder) throws {
        value = try decoder.singleValueContainer().decode(Int64.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }

    public var description: String { String(value) }
}

/// The server's head sequence, handed back by a push. Informational.
///
/// A separate type from `PullCursor`, and the separation is the point. Both are
/// integers, the protocol calls both of them `cursor`, and storing this one as the
/// pull cursor skips ops *permanently* — it is the head of the whole log, and ops
/// pushed by this user's other devices can sit below it that this device has never
/// read. Past that head, they are never offered again.
///
/// A comment saying "don't do that" would not survive the next person in a hurry.
/// Distinct types mean the assignment does not compile, and there is deliberately no
/// API anywhere in this package that persists a `PushCursor` — `CurationStore` has no
/// method that accepts one. Converting through `.value` is still possible, but it can
/// no longer happen by accident.
public struct PushCursor: Hashable, Sendable, Codable, CustomStringConvertible {
    public let value: Int64

    public init(_ value: Int64) { self.value = value }

    public init(from decoder: any Decoder) throws {
        value = try decoder.singleValueContainer().decode(Int64.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }

    public var description: String { String(value) }
}

// MARK: - Push

/// One op as the server wants it: wire entity name, lowercase operation, payload as
/// a JSON object rather than the string it is stored as.
public struct WireOp: Codable, Hashable, Sendable {
    public let opId: String
    public let entity: String
    public let entityId: String
    public let operation: String
    public let payload: JSONValue
    public let createdAt: Millis

    public init(
        opId: String,
        entity: String,
        entityId: String,
        operation: String,
        payload: JSONValue,
        createdAt: Millis
    ) {
        self.opId = opId
        self.entity = entity
        self.entityId = entityId
        self.operation = operation
        self.payload = payload
        self.createdAt = createdAt
    }
}

public extension WireOp {
    /// Converts a stored op for the wire, or explains why it can never be sent.
    ///
    /// Every rule the server enforces is checked here first. Not defensiveness:
    /// an op that is certain to bounce costs a round trip to learn nothing, and
    /// while it sits at the head of the queue being retried, everything behind it
    /// waits. Failing locally quarantines it with a reason the device can actually
    /// display, and the queue keeps moving.
    ///
    /// The two rules the server *cannot* check are the ones worth having here at
    /// all: `entityId` agreeing with the id inside the payload, and a delete
    /// carrying its flag. Payload contents are stored verbatim and never inspected,
    /// so an op that disagrees with itself syncs perfectly and confuses every reader
    /// from then on.
    static func make(from op: Op) -> Result<WireOp, SyncFault> {
        guard !op.opId.isEmpty else { return .failure(.emptyOpId) }
        guard op.opId.count <= SyncPolicy.maxOpIdLength else {
            return .failure(.opIdTooLong(op.opId.count))
        }
        guard !op.entityId.isEmpty else { return .failure(.emptyEntityId) }
        guard op.entityId.count <= SyncPolicy.maxEntityIdLength else {
            return .failure(.entityIdTooLong(op.entityId.count))
        }
        guard op.createdAt > 0 else { return .failure(.nonPositiveTimestamp(op.createdAt)) }
        guard let entity = SyncEntity(localTable: op.entity) else {
            return .failure(.unknownEntity(op.entity))
        }
        guard let operation = Op.Kind(rawValue: op.operation) else {
            return .failure(.unknownOperation(op.operation))
        }

        // Measured on the stored text, which is the same compact JSON the transport
        // re-encodes onto the wire — `CurationStore.json` writes no whitespace and
        // neither may the transport.
        let bytes = op.payload.utf8.count
        guard bytes <= SyncPolicy.maxPayloadBytes else {
            return .failure(.payloadTooLarge(bytes: bytes))
        }

        guard
            let parsed = try? JSONDecoder().decode(JSONValue.self, from: Data(op.payload.utf8)),
            let fields = parsed.objectValue
        else {
            return .failure(.payloadNotAnObject)
        }

        guard let identity = fields[entity.identityKey]?.stringValue else {
            return .failure(.identityMismatch(entityId: op.entityId, payloadId: nil))
        }
        guard identity == op.entityId else {
            return .failure(.identityMismatch(entityId: op.entityId, payloadId: identity))
        }

        // A delete whose payload does not say so is a row that travels as alive and
        // resurrects itself on every other device. The converse — an upsert whose
        // payload says deleted — is left alone: nothing in the contract forbids it,
        // and the merge reads the flag either way.
        if operation == .delete, fields["deleted"]?.isFlagSet != true {
            return .failure(.deleteWithoutFlag)
        }

        return .success(WireOp(
            opId: op.opId,
            entity: entity.wireName,
            entityId: op.entityId,
            operation: operation.rawValue,
            payload: parsed,
            createdAt: op.createdAt
        ))
    }
}

public struct PushRequest: Codable, Hashable, Sendable {
    public let deviceId: String
    public let ops: [WireOp]

    public init(deviceId: String, ops: [WireOp]) {
        self.deviceId = deviceId
        self.ops = ops
    }
}

/// One op the server refused. It will refuse it again; there is no retry that helps.
public struct RejectedOp: Hashable, Sendable {
    public let opId: String
    public let reason: String

    public init(opId: String, reason: String) {
        self.opId = opId
        self.reason = reason
    }
}

extension RejectedOp: Codable {
    private enum CodingKeys: String, CodingKey { case opId, reason }

    /// Decodes either `{"opId": …, "reason": …}` or a bare id string.
    ///
    /// The contract describes this field in prose rather than as a schema, and the
    /// original design document does not have the field at all. Guessing wrong the
    /// strict way would fail the whole push response — including the `accepted` list
    /// that was right there — so a rejection whose shape is a surprise degrades to
    /// "rejected, reason unknown" instead.
    public init(from decoder: any Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let id = try? single.decode(String.self) {
            opId = id
            reason = "no reason given"
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        opId = try container.decode(String.self, forKey: .opId)
        reason = try container.decodeIfPresent(String.self, forKey: .reason) ?? "no reason given"
    }
}

public struct PushResponse: Hashable, Sendable {
    /// Includes ops the server had already seen. Re-pushing is accepted and ignored,
    /// which is what makes retrying a timed-out push safe.
    public let accepted: [String]
    public let rejected: [RejectedOp]
    /// The server's head sequence, when it said. Not a pull cursor — see `PushCursor`.
    ///
    /// Optional because nothing reads it. Requiring it would mean a reply missing one
    /// field — a proxy that trimmed it, a server built slightly differently — throws
    /// away the `accepted` list sitting next to it, so every op in that batch is
    /// pushed again forever, over a value this client has already decided it does not
    /// want.
    public let cursor: PushCursor?

    public init(accepted: [String], rejected: [RejectedOp] = [], cursor: PushCursor? = nil) {
        self.accepted = accepted
        self.rejected = rejected
        self.cursor = cursor
    }
}

extension PushResponse: Codable {
    private enum CodingKeys: String, CodingKey { case accepted, rejected, cursor }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accepted = try container.decodeIfPresent([String].self, forKey: .accepted) ?? []
        rejected = try container.decodeIfPresent([RejectedOp].self, forKey: .rejected) ?? []
        cursor = try container.decodeIfPresent(PushCursor.self, forKey: .cursor)
    }
}

// MARK: - Pull

/// An op coming back down, carrying the three fields the server adds.
public struct PulledOp: Codable, Hashable, Sendable {
    public let opId: String
    public let entity: String
    public let entityId: String
    public let operation: String
    public let payload: JSONValue
    /// The writing device's clock. Sanity-checked against `receivedAt` before it is
    /// allowed to decide a conflict.
    public let createdAt: Millis
    /// Commit-ordered. Seeing this means everything below it has been seen too;
    /// gaps are normal, because a rolled-back transaction burns a sequence.
    public let seq: Int64
    /// Which device pushed it. Recorded, never used to decide whether to apply —
    /// see `InboundApplier`.
    public let deviceId: String
    /// Server receipt time. The only clock in the system that every device shares.
    public let receivedAt: Millis

    public init(
        opId: String,
        entity: String,
        entityId: String,
        operation: String,
        payload: JSONValue,
        createdAt: Millis,
        seq: Int64,
        deviceId: String,
        receivedAt: Millis
    ) {
        self.opId = opId
        self.entity = entity
        self.entityId = entityId
        self.operation = operation
        self.payload = payload
        self.createdAt = createdAt
        self.seq = seq
        self.deviceId = deviceId
        self.receivedAt = receivedAt
    }
}

public struct PullResponse: Hashable, Sendable {
    /// Ascending by `seq`.
    public let ops: [PulledOp]
    public let cursor: PullCursor
    /// Exact — the server reads one row past the limit to answer it.
    public let hasMore: Bool
    /// Entries in `ops` this build could not read as an op at all. Counted rather than
    /// dropped in silence — see the decoder below.
    public let unreadableOps: Int

    public init(ops: [PulledOp], cursor: PullCursor, hasMore: Bool, unreadableOps: Int = 0) {
        self.ops = ops
        self.cursor = cursor
        self.hasMore = hasMore
        self.unreadableOps = unreadableOps
    }
}

extension PullResponse: Codable {
    private enum CodingKeys: String, CodingKey { case ops, cursor, hasMore }

    /// One unreadable op must not cost the batch, because it costs *every future
    /// batch*.
    ///
    /// Decoding `ops` as a plain array is all-or-nothing, and the failure has no way
    /// out: the cursor only advances inside the transaction that applies a batch, so a
    /// response that cannot be decoded is requested again, fails again, and inbound
    /// sync stops for good while push carries on working. The device then diverges in
    /// one direction and it looks like intermittent network trouble.
    ///
    /// So each element is decoded on its own and a failure yields nothing rather than
    /// throwing. Nothing better is available for one of these: without an `opId` it
    /// cannot even be quarantined, and the alternative is the permanent stall above.
    /// It is counted, surfaced in the report, and the cursor moves on.
    ///
    /// This does not rescue a body that fails to *parse* — Foundation refuses JSON
    /// nested past about 512 levels before any of this runs, and there is no
    /// per-element seam below a parse error. The server accepts such a payload (it
    /// checks only "object" and "under 256 KB"), so a peer holding this user's token
    /// can still wedge inbound sync. Out of reach from here; it needs a server-side
    /// depth limit.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let entries = try container.decode([ReadableOp].self, forKey: .ops)
        ops = entries.compactMap(\.op)
        unreadableOps = entries.count - ops.count
        cursor = try container.decode(PullCursor.self, forKey: .cursor)
        hasMore = try container.decodeIfPresent(Bool.self, forKey: .hasMore) ?? false
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(ops, forKey: .ops)
        try container.encode(cursor, forKey: .cursor)
        try container.encode(hasMore, forKey: .hasMore)
    }

    /// One array element, decoded or not. The unkeyed container still steps past a
    /// failure because the element type itself always succeeds.
    private struct ReadableOp: Decodable {
        let op: PulledOp?

        init(from decoder: any Decoder) throws {
            op = try? PulledOp(from: decoder)
        }
    }
}

// MARK: - Transport

/// The network, held at arm's length.
///
/// CurationKit has no networking in it and this protocol is what keeps that true.
/// The app implements it over `JellyfinClient` — same host, same token, base path
/// `/aoide/sync` — and the package stays buildable and testable from the command
/// line on macOS, with a fake server standing in for the real one. Without this
/// seam the sync engine could only be exercised against a running Jellyfin.
public protocol SyncTransport: Sendable {
    func push(_ request: PushRequest) async throws -> PushResponse

    /// `since` is `nil` on a device that has never synced, which the transport sends
    /// as the beginning of the log.
    func pull(since cursor: PullCursor?, limit: Int) async throws -> PullResponse
}
