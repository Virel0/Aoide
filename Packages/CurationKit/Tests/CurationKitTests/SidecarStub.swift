import Foundation
import GRDB
@testable import CurationKit

// MARK: - Failures the sidecar answers with

enum SidecarError: Error, Equatable {
    /// Over a thousand ops in one push is a 400 for the **whole** request, valid ops
    /// included. Modelled as a thrown error rather than a rejection list because that
    /// is the difference the client has to get right: rejections are per-op and final,
    /// this one is per-request and fixed by splitting.
    case batchTooLarge(Int)
    /// A round trip that never completed — a dropped connection, a timeout, a phone
    /// leaving a tunnel. Retryable, and nothing about the op is wrong.
    case unreachable
}

// MARK: - The sidecar

/// The sidecar, in memory, and deliberately as dumb as the real one.
///
/// Faithful rather than permissive, which is the only version worth testing against.
/// A double that accepts whatever it is handed proves the engine sends *something*;
/// this one enforces every rule the contract says the server enforces, so a sync that
/// ends with an empty `rejected` list is evidence the client's own validation agrees
/// with the server's rather than evidence that nobody checked.
///
/// It interprets nothing. Payloads are stored verbatim and never parsed beyond
/// confirming they are objects, so every invariant the contract leaves to the client —
/// `entityId` matching the payload's id, a delete carrying its flag, `queue_state`
/// being keyed by device — is one this type will happily let through. That is the
/// point: those are exactly the mistakes that sync perfectly and then confuse every
/// reader, and a double that silently corrected them would hide the only bugs worth
/// finding.
///
/// One log, one sequence, many users. `seq` is global and commit-ordered, which is
/// what makes the push cursor a real trap rather than a theoretical one — the head it
/// reports can sit well above anything this user has ever been offered.
actor Sidecar {
    /// One accepted op, as the server holds it.
    struct Row: Sendable {
        let seq: Int64
        let userId: String
        let op: WireOp
        let deviceId: String
        let receivedAt: Millis
    }

    /// Idempotency is `(user_id, op_id)`, scoped per user — two users minting the same
    /// UUID is absurd but the uniqueness is not global and the double should not
    /// pretend otherwise.
    private struct OpKey: Hashable {
        let userId: String
        let opId: String
    }

    private(set) var log: [Row] = []
    private(set) var pushCount = 0
    private(set) var pullCount = 0
    private(set) var largestBatchPushed = 0
    private(set) var pullLimitsRequested: [Int] = []
    private(set) var pushesByDevice: [String: Int] = [:]
    /// Every endpoint hit, in order. Push before pull is a rule about the loop, and
    /// this is the only place it is observable.
    private(set) var calls: [String] = []

    private var nextSeq: Int64 = 1
    private var seen: Set<OpKey> = []

    /// Server receipt time.
    ///
    /// A plausible value rather than a meaningful one — every test that cares about
    /// what this is set to sets it. It used to have to be ahead of every timestamp the
    /// tests wrote, because a server clock behind its clients tripped the skew
    /// correction on every single op; that is now a case the engine handles rather than
    /// one the double has to steer around (see `slowServerStillConverges`).
    private var clock: Millis = 2_000_000_000_000

    private var forcedRejections: [String: String] = [:]
    private var failPushCalls: Set<Int> = []
    private var failPullCalls: Set<Int> = []
    private var pullDelayNanos: UInt64 = 0
    private var extraEntities: Set<String> = []

    // MARK: Connections

    /// A transport bound to one user.
    ///
    /// `nonisolated` so a test can build links without awaiting: it reads nothing but
    /// the actor reference itself.
    nonisolated func link(user: String = "alex") -> SidecarLink {
        SidecarLink(sidecar: self, userId: user)
    }

    // MARK: Knobs

    func setClock(_ value: Millis) { clock = value }

    /// Burns sequence numbers without storing anything, the way a rolled-back
    /// transaction does. Gaps are normal and a client that reads one as data loss is
    /// broken.
    func burnSequences(_ count: Int = 1) { nextSeq += Int64(count) }

    /// Refuses one op permanently, standing in for a validation rule this client does
    /// not model. A rejected op is never accepted, however often it is sent.
    func reject(_ opId: String, because reason: String) { forcedRejections[opId] = reason }

    func failPush(atCall call: Int) { failPushCalls.insert(call) }

    /// Op ids the server throws a 500 on, as an unhandled exception would: the whole
    /// request fails, including the innocent ops that happened to travel with it.
    private var poisonOpIds: Set<String> = []
    func poison(_ opId: String) { poisonOpIds.insert(opId) }
    func unpoison(_ opId: String) { poisonOpIds.remove(opId) }

    /// Makes the poison one-shot, so the next request throws and everything after it
    /// succeeds — a server that was restarting rather than one with a bad row.
    private var clearPoisonAfterFailure = false
    func clearPoisonAfterNextFailure() { clearPoisonAfterFailure = true }
    func failPull(atCall call: Int) { failPullCalls.insert(call) }
    func setPullDelay(nanos: UInt64) { pullDelayNanos = nanos }

    /// Widens the allow-list, standing in for a server deployed ahead of this build —
    /// a `downloads` table it accepts and this client has never heard of. The only way
    /// an op the client cannot apply can legitimately come back down, and therefore
    /// the only way to exercise inbound quarantine end to end.
    func alsoAllow(_ entity: String) { extraEntities.insert(entity) }

    // MARK: Observation

    /// The server's head sequence — what a push reports back.
    var head: Int64 { nextSeq - 1 }

    func ops(for userId: String) -> [Row] { log.filter { $0.userId == userId } }

    func opCount(for userId: String) -> Int { ops(for: userId).count }

    func entities(for userId: String) -> [String] { ops(for: userId).map(\.op.entity) }

    // MARK: Transport

    func push(_ request: PushRequest, as userId: String) async throws -> PushResponse {
        pushCount += 1
        calls.append("push")
        pushesByDevice[request.deviceId, default: 0] += 1
        largestBatchPushed = max(largestBatchPushed, request.ops.count)

        if failPushCalls.contains(pushCount) { throw SidecarError.unreachable }
        if request.ops.contains(where: { poisonOpIds.contains($0.opId) }) {
            if clearPoisonAfterFailure {
                poisonOpIds.removeAll()
                clearPoisonAfterFailure = false
            }
            throw SyncTransportFault(status: 500, detail: "Error processing request.")
        }
        guard request.ops.count <= 1_000 else {
            throw SidecarError.batchTooLarge(request.ops.count)
        }

        var accepted: [String] = []
        var rejected: [RejectedOp] = []

        for op in request.ops {
            if let reason = forcedRejections[op.opId] ?? Self.refusal(op, alsoAllowing: extraEntities) {
                rejected.append(RejectedOp(opId: op.opId, reason: reason))
                continue
            }
            // Already held is accepted and ignored. This one line is what makes a
            // timed-out push safe to send again, and every retry test rests on it.
            guard seen.insert(OpKey(userId: userId, opId: op.opId)).inserted else {
                accepted.append(op.opId)
                continue
            }
            log.append(Row(
                seq: nextSeq,
                userId: userId,
                op: op,
                deviceId: request.deviceId,
                receivedAt: clock
            ))
            nextSeq += 1
            accepted.append(op.opId)
        }

        return PushResponse(accepted: accepted, rejected: rejected, cursor: PushCursor(head))
    }

    func pull(since cursor: PullCursor?, limit: Int, as userId: String) async throws -> PullResponse {
        pullCount += 1
        calls.append("pull")
        pullLimitsRequested.append(limit)
        if pullDelayNanos > 0 { try await Task.sleep(nanoseconds: pullDelayNanos) }
        if failPullCalls.contains(pullCount) { throw SidecarError.unreachable }

        let effective = min(max(1, limit), 1_000)
        let since = cursor?.value ?? 0

        // One row past the limit, which is what makes `hasMore` exact rather than the
        // guess "a full page probably means more".
        let window = Array(
            log.lazy
                .filter { $0.userId == userId && $0.seq > since }
                .prefix(effective + 1)
        )
        let page = window.prefix(effective)

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
            // "Everything up to here", not "the next number" — so a gap above the last
            // row of a page is invisible to the client and must stay that way.
            cursor: PullCursor(page.last?.seq ?? since),
            hasMore: window.count > effective
        )
    }

    // MARK: The rejection rules

    /// Spelled out literally rather than derived from `SyncEntity`.
    ///
    /// A double that shared the mapping under test could never catch the mapping being
    /// wrong: rename a case, and both sides would rename together and agree on a name
    /// the real server has never heard of.
    private static let allowedEntities: Set<String> = [
        "playlists", "playlist_items", "folders", "likes", "play_events", "queue_state"
    ]

    /// Why the server refuses an op, or `nil` if it does not. The contents of the
    /// payload are never examined — only that it is an object and how big it is.
    static func refusal(_ op: WireOp, alsoAllowing extra: Set<String> = []) -> String? {
        guard !op.opId.isEmpty else { return "opId must not be empty" }
        guard op.opId.count <= 128 else { return "opId is \(op.opId.count) characters, over the 128 limit" }
        guard !op.entityId.isEmpty else { return "entityId must not be empty" }
        guard op.entityId.count <= 256 else {
            return "entityId is \(op.entityId.count) characters, over the 256 limit"
        }
        // `tracks` lands here: a per-device cache the server refuses outright.
        guard allowedEntities.contains(op.entity) || extra.contains(op.entity) else {
            return "unknown entity '\(op.entity)'"
        }
        // Case-sensitive. "UPSERT" is a rejection.
        guard op.operation == "upsert" || op.operation == "delete" else {
            return "unknown operation '\(op.operation)'"
        }
        guard op.payload.objectValue != nil else { return "payload must be a JSON object" }
        guard op.createdAt > 0 else { return "createdAt must be a positive millisecond timestamp" }

        // Measured on the compact text that would go over the wire, which is what the
        // client's own check has to agree with.
        let bytes = (try? JSONEncoder().encode(op.payload).count) ?? .max
        guard bytes <= 256 * 1024 else { return "payload is \(bytes) bytes, over the 256 KB limit" }

        return nil
    }
}

/// One authenticated device's view of the sidecar.
///
/// `SyncTransport` carries no user because the endpoint does not: the Jellyfin token
/// identifies the user and the sidecar validates it. Binding the user here keeps that
/// shape honest, and lets a test hand two stores links for the same user — the whole
/// subject — or for different ones, which is how the per-user scoping gets checked.
struct SidecarLink: SyncTransport {
    let sidecar: Sidecar
    let userId: String

    func push(_ request: PushRequest) async throws -> PushResponse {
        try await sidecar.push(request, as: userId)
    }

    func pull(since cursor: PullCursor?, limit: Int) async throws -> PullResponse {
        try await sidecar.pull(since: cursor, limit: limit, as: userId)
    }
}

// MARK: - Comparing two stores

/// Every syncable row in a store, canonically ordered and fully encoded.
///
/// The assertion that matters after a sync is not "both devices have the playlist" but
/// "both devices hold the same bytes". Two stores that agree on names while disagreeing
/// about a soft-delete flag, a position key or an `originDevice` have diverged already;
/// the next edit on either side is what makes it visible, by which time the sync that
/// caused it is long finished. So this compares every column of every syncable table,
/// deleted rows included.
///
/// The per-device tables are deliberately absent — `track` is a cache each device
/// rebuilds from its own Jellyfin connection, and `op`, `quarantinedOp` and `syncState`
/// are one device's private bookkeeping. Requiring those to match would be requiring
/// the wrong thing.
func syncedRows(of store: CurationStore) throws -> String {
    var lines: [String] = []
    lines += try encodedRows(Folder.self, in: store)
    lines += try encodedRows(Playlist.self, in: store)
    lines += try encodedRows(PlaylistItem.self, in: store)
    lines += try encodedRows(Like.self, in: store)
    lines += try encodedRows(PlayEvent.self, in: store)
    lines += try encodedRows(QueueState.self, in: store)
    return lines.joined(separator: "\n")
}

private func encodedRows<R>(_ type: R.Type, in store: CurationStore) throws -> [String]
where R: FetchableRecord & PersistableRecord & Encodable {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]

    var lines: [String] = []
    for row in try store.read({ db in try R.fetchAll(db) }) {
        lines.append("\(R.databaseTableName) \(String(decoding: try encoder.encode(row), as: UTF8.self))")
    }
    // Sorted rather than left in table order: two devices that inserted the same rows
    // in a different sequence hold the same data, and rowid order is not part of it.
    return lines.sorted()
}

extension CurationStore {
    /// How many ops this device has queued or sent, ever.
    ///
    /// The number that must not grow when a device merely *applies* somebody else's
    /// changes — see the ping-pong tests.
    func totalOpCount() throws -> Int {
        try read { db in try Op.fetchCount(db) }
    }

    /// Re-queues every op this device has ever recorded, as though the acknowledgements
    /// had been lost. Used to prove that pushing the same work twice adds nothing.
    func forgetAcknowledgements() throws {
        _ = try writeLocal { db in
            try Op.updateAll(db, Column("synced").set(to: false))
        }
    }
}
