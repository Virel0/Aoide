import Foundation
import GRDB
@testable import CurationKit

// MARK: - Building payloads

enum Wire {
    /// A record encoded the way `CurationStore.record` encodes it, then parsed —
    /// the exact shape an op payload has on the wire.
    static func payload(_ value: some Encodable) throws -> JSONValue {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try JSONDecoder().decode(JSONValue.self, from: encoder.encode(value))
    }

    static func text(_ value: JSONValue) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    /// An op as it comes back from a pull.
    static func pulled(
        _ entity: SyncEntity,
        _ record: some Encodable,
        entityId: String,
        operation: Op.Kind = .upsert,
        opId: String = UUID().uuidString,
        createdAt: Millis = 1_000,
        seq: Int64 = 1,
        deviceId: String = "mac",
        receivedAt: Millis = 1_000
    ) throws -> PulledOp {
        PulledOp(
            opId: opId,
            entity: entity.wireName,
            entityId: entityId,
            operation: operation.rawValue,
            payload: try payload(record),
            createdAt: createdAt,
            seq: seq,
            deviceId: deviceId,
            receivedAt: receivedAt
        )
    }

    /// An op whose payload is arbitrary JSON, for the cases a real record cannot
    /// produce.
    static func pulledRaw(
        entity: String,
        entityId: String,
        payload: JSONValue,
        operation: String = "upsert",
        opId: String = UUID().uuidString,
        createdAt: Millis = 1_000,
        seq: Int64 = 1,
        deviceId: String = "mac",
        receivedAt: Millis = 1_000
    ) -> PulledOp {
        PulledOp(
            opId: opId,
            entity: entity,
            entityId: entityId,
            operation: operation,
            payload: payload,
            createdAt: createdAt,
            seq: seq,
            deviceId: deviceId,
            receivedAt: receivedAt
        )
    }
}

extension CurationStore {
    /// Applies one op through the real batch path.
    @discardableResult
    func applyOne(_ op: PulledOp, now: Millis = 5_000) throws -> SyncReport {
        try apply([op], advancingTo: PullCursor(op.seq), policy: .default, now: now)
    }
}

func makePlaylist(
    id: String = "list-1",
    name: String = "Late Night",
    updatedAt: Millis,
    deleted: Bool = false,
    device: String
) -> Playlist {
    Playlist(
        id: id,
        name: name,
        sortIndex: FractionalIndex.initial,
        updatedAt: updatedAt,
        deleted: deleted,
        originDevice: device
    )
}

/// Collects the engine's progress callbacks from whatever context they arrive on.
final class PhaseLog: @unchecked Sendable {
    private let lock = NSLock()
    private var phases: [SyncPhase] = []

    func record(_ phase: SyncPhase) {
        lock.lock()
        defer { lock.unlock() }
        phases.append(phase)
    }

    var recorded: [SyncPhase] {
        lock.lock()
        defer { lock.unlock() }
        return phases
    }
}

// MARK: - A stand-in for the sidecar

enum FakeServerError: Error, Equatable {
    /// The whole push is a 400 when the batch is over the limit.
    case batchTooLarge(Int)
    case offline
}

/// The sidecar, in memory, enforcing the rules it says it enforces.
///
/// Faithful on purpose rather than permissive: a double that accepts anything proves
/// only that the engine sends *something*. This one rejects exactly what the contract
/// says it rejects, so a happy-path test that ends with an empty `rejected` list is
/// evidence the engine's local validation agrees with the server's.
actor FakeSyncServer: SyncTransport {
    struct Entry: Sendable {
        var seq: Int64
        var op: WireOp
        var deviceId: String
        var receivedAt: Millis
    }

    private(set) var log: [Entry] = []
    private(set) var pushCount = 0
    private(set) var pullCount = 0
    private(set) var largestBatchSeen = 0
    private(set) var lastPushedDeviceId: String?

    private var nextSeq: Int64 = 1
    private var seenOpIds: Set<String> = []

    private var clock: Millis = 2_000
    private var forcedRejections: [String: String] = [:]
    private var acceptNothing = false
    private var offlineForNextPush = false
    private var failPullAtCall: Int?
    private var pullDelayNanos: UInt64 = 0

    // MARK: Knobs

    func setClock(_ value: Millis) { clock = value }
    func reject(_ opId: String, reason: String) { forcedRejections[opId] = reason }
    func setAcceptNothing(_ value: Bool) { acceptNothing = value }
    func goOfflineForNextPush() { offlineForNextPush = true }
    func failPull(atCall call: Int) { failPullAtCall = call }
    func setPullDelay(nanos: UInt64) { pullDelayNanos = nanos }

    /// Puts ops in the log as if another device had pushed them.
    func seed(_ ops: [WireOp], from deviceId: String, receivedAt: Millis? = nil) {
        for op in ops {
            guard seenOpIds.insert(op.opId).inserted else { continue }
            log.append(Entry(seq: nextSeq, op: op, deviceId: deviceId, receivedAt: receivedAt ?? clock))
            nextSeq += 1
        }
    }

    var head: Int64 { nextSeq - 1 }

    func entries(for entity: SyncEntity) -> [Entry] {
        log.filter { $0.op.entity == entity.wireName }
    }

    // MARK: Transport

    func push(_ request: PushRequest) async throws -> PushResponse {
        pushCount += 1
        largestBatchSeen = max(largestBatchSeen, request.ops.count)
        lastPushedDeviceId = request.deviceId

        if offlineForNextPush {
            offlineForNextPush = false
            throw FakeServerError.offline
        }
        guard request.ops.count <= SyncPolicy.maxBatch else {
            throw FakeServerError.batchTooLarge(request.ops.count)
        }
        guard !acceptNothing else {
            return PushResponse(accepted: [], rejected: [], cursor: PushCursor(head))
        }

        var accepted: [String] = []
        var rejected: [RejectedOp] = []

        for op in request.ops {
            if let reason = forcedRejections[op.opId] {
                rejected.append(RejectedOp(opId: op.opId, reason: reason))
                continue
            }
            if let reason = Self.validate(op) {
                rejected.append(RejectedOp(opId: op.opId, reason: reason))
                continue
            }
            // Already seen is accepted and ignored — the property that makes a
            // retried push safe.
            guard seenOpIds.insert(op.opId).inserted else {
                accepted.append(op.opId)
                continue
            }
            log.append(Entry(seq: nextSeq, op: op, deviceId: request.deviceId, receivedAt: clock))
            nextSeq += 1
            accepted.append(op.opId)
        }

        return PushResponse(accepted: accepted, rejected: rejected, cursor: PushCursor(head))
    }

    func pull(since cursor: PullCursor?, limit: Int) async throws -> PullResponse {
        pullCount += 1
        if pullDelayNanos > 0 { try await Task.sleep(nanoseconds: pullDelayNanos) }
        if let failPullAtCall, pullCount == failPullAtCall { throw FakeServerError.offline }

        let effective = min(max(1, limit), SyncPolicy.maxPullLimit)
        let since = cursor?.value ?? 0
        let matching = log.filter { $0.seq > since }
        let page = Array(matching.prefix(effective))

        return PullResponse(
            ops: page.map {
                PulledOp(
                    opId: $0.op.opId,
                    entity: $0.op.entity,
                    entityId: $0.op.entityId,
                    operation: $0.op.operation,
                    payload: $0.op.payload,
                    createdAt: $0.op.createdAt,
                    seq: $0.seq,
                    deviceId: $0.deviceId,
                    receivedAt: $0.receivedAt
                )
            },
            cursor: PullCursor(page.last?.seq ?? since),
            hasMore: matching.count > effective
        )
    }

    /// The server's allow-list, spelled out here rather than reused from
    /// `SyncEntity` — a test double that shares the mapping under test cannot catch
    /// the mapping being wrong.
    private static let allowedEntities: Set<String> = [
        "playlists", "playlist_items", "folders", "likes", "play_events", "queue_state"
    ]

    private static func validate(_ op: WireOp) -> String? {
        guard allowedEntities.contains(op.entity) else { return "unknown entity '\(op.entity)'" }
        guard op.operation == "upsert" || op.operation == "delete" else {
            return "unknown operation '\(op.operation)'"
        }
        guard op.payload.objectValue != nil else { return "payload is not an object" }
        guard !op.opId.isEmpty, op.opId.count <= 128 else { return "bad opId" }
        guard !op.entityId.isEmpty, op.entityId.count <= 256 else { return "bad entityId" }
        guard op.createdAt > 0 else { return "createdAt must be positive" }

        let encoder = JSONEncoder()
        let bytes = (try? encoder.encode(op.payload).count) ?? 0
        guard bytes <= 256 * 1024 else { return "payload too large" }
        return nil
    }
}
