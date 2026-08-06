import Foundation

/// What one sync did, in numbers a UI can show without lying.
public struct SyncReport: Hashable, Sendable {
    /// Ops the server acknowledged, including ones it had already seen.
    public var pushed = 0
    /// Ours, refused before they left or refused by the server. Never retried.
    public var quarantinedOutbound = 0
    /// The subset of `quarantinedOutbound` the server refused rather than we did.
    public var rejected = 0

    /// Ops received, whatever became of them.
    public var pulled = 0
    /// Ops that changed a local row.
    public var applied = 0
    /// Ops that lost last-writer-wins, including our own coming back.
    public var ignoredStale = 0
    /// Play events already present.
    public var ignoredDuplicate = 0
    /// Items applied whose playlist has not arrived yet.
    public var orphanedItems = 0
    /// Duplicate likes for one track, collapsed to the newer row.
    public var supersededLikes = 0
    /// Inbound ops this build cannot apply.
    public var quarantinedInbound = 0
    /// Entries in a pulled batch that could not be read as an op at all, so there was
    /// nothing to quarantine. See `PullResponse.init(from:)`.
    public var unreadable = 0
    /// Timestamps pulled back to the server's receipt time.
    public var clockSkewed = 0

    /// Where the pull got to. `nil` when nothing was pulled.
    public var cursor: PullCursor?

    public init() {}

    public var quarantined: Int { quarantinedOutbound + quarantinedInbound }

    /// Whether anything at all moved, for a UI deciding between "up to date" and a
    /// list of numbers.
    public var isEmpty: Bool {
        pushed == 0 && pulled == 0 && quarantined == 0
    }

    mutating func absorb(_ other: SyncReport) {
        pushed += other.pushed
        quarantinedOutbound += other.quarantinedOutbound
        rejected += other.rejected
        pulled += other.pulled
        applied += other.applied
        ignoredStale += other.ignoredStale
        ignoredDuplicate += other.ignoredDuplicate
        orphanedItems += other.orphanedItems
        supersededLikes += other.supersededLikes
        quarantinedInbound += other.quarantinedInbound
        unreadable += other.unreadable
        clockSkewed += other.clockSkewed
        if let cursor = other.cursor { self.cursor = cursor }
    }
}

/// Where a sync has got to. Reported as it happens rather than only at the end,
/// because a first sync on a device with years of play history is many round trips
/// and a spinner that says nothing for two minutes reads as broken.
public enum SyncPhase: Hashable, Sendable {
    case idle
    case pushing(pushed: Int)
    case pulling(applied: Int)
    case failed(reason: String)
}

/// The sync loop: push everything pending, then read everything new.
///
/// Push before pull, always. A device's own ops come back down with a sequence
/// number, which is how it learns they are durably on disk — pulling first would
/// merge a server state that does not yet contain the local changes, and any row
/// touched on both sides would resolve against a version of itself that is missing.
public actor SyncEngine {
    private let store: CurationStore
    private let transport: any SyncTransport
    private let policy: SyncPolicy
    private let clock: @Sendable () -> Millis
    private let observer: (@Sendable (SyncPhase) -> Void)?

    public private(set) var phase: SyncPhase = .idle
    public private(set) var lastReport: SyncReport?

    private var running = false

    public init(
        store: CurationStore,
        transport: any SyncTransport,
        policy: SyncPolicy = .default,
        clock: @escaping @Sendable () -> Millis = { Date().millis },
        onPhaseChange observer: (@Sendable (SyncPhase) -> Void)? = nil
    ) {
        self.store = store
        self.transport = transport
        self.policy = policy
        self.clock = clock
        self.observer = observer
    }

    /// Runs one full sync.
    ///
    /// Throws `SyncError.alreadyRunning` if one is in flight. An actor is not enough
    /// on its own — the loop suspends at every network call, and a second caller
    /// walks straight in during one of those suspensions — so exclusion is explicit.
    ///
    /// The alternative was to coalesce: hand the second caller the first one's task
    /// and let them share a result. It looks friendlier and it is wrong. A caller
    /// that has just written a row and syncs to send it would get back the report of
    /// a sync that started *before* that write, containing none of it, and would have
    /// no way to tell. Refusing is honest, and a UI that syncs on a timer as well as
    /// on foreground can ignore this one error.
    @discardableResult
    public func sync() async throws -> SyncReport {
        guard !running else { throw SyncError.alreadyRunning }
        running = true
        defer { running = false }

        do {
            var report = try await pushPending()
            report.absorb(try await pullAndApply())
            lastReport = report
            transition(to: .idle)
            return report
        } catch {
            transition(to: .failed(reason: "\(error)"))
            throw error
        }
    }

    // MARK: - Push

    private func pushPending() async throws -> SyncReport {
        var report = SyncReport()
        var previousBatch: Set<String> = []

        while true {
            let pending = try store.pendingOps(limit: policy.pushBatchSize)
            guard !pending.isEmpty else { break }

            // A batch identical to the last one means the round trip accepted
            // nothing, rejected nothing and quarantined nothing, so the next attempt
            // sends the same bytes to the same effect. Better to surface a stall than
            // to hold the connection open forever making no progress.
            let ids = Set(pending.map(\.opId))
            guard ids != previousBatch else { throw SyncError.pushStalled(pending: pending.count) }
            previousBatch = ids

            var wire: [WireOp] = []
            for op in pending {
                switch WireOp.make(from: op) {
                case .success(let valid):
                    wire.append(valid)
                case .failure(let fault):
                    try store.quarantine(op, reason: fault, at: clock())
                    report.quarantinedOutbound += 1
                }
            }
            // Everything in this batch was invalid. They are out of the queue now, so
            // the next fetch returns different rows and the loop still terminates.
            guard !wire.isEmpty else { continue }

            let response = try await transport.push(
                PushRequest(deviceId: store.deviceId, ops: wire)
            )

            // `accepted` includes ops the server had already seen, so a push that
            // timed out and was sent again acknowledges everything rather than
            // stranding the duplicate half.
            try store.markSynced(response.accepted)
            report.pushed += response.accepted.count

            if !response.rejected.isEmpty {
                let byId = Dictionary(pending.map { ($0.opId, $0) }, uniquingKeysWith: { first, _ in first })
                for rejection in response.rejected {
                    // A rejected op will never be accepted. Retrying it is an
                    // infinite loop, so it leaves the queue here and is surfaced
                    // instead.
                    guard let op = byId[rejection.opId] else { continue }
                    try store.quarantine(op, reason: .serverRejected(rejection.reason), at: clock())
                    report.quarantinedOutbound += 1
                    report.rejected += 1
                }
            }

            // The response's cursor is deliberately dropped on the floor. It is the
            // server's head sequence, not this device's read position — see
            // `PushCursor`.
            transition(to: .pushing(pushed: report.pushed))
        }

        return report
    }

    // MARK: - Pull

    private func pullAndApply() async throws -> SyncReport {
        var report = SyncReport()
        var cursor = try store.pullCursor()

        while true {
            let response = try await transport.pull(since: cursor, limit: policy.pullLimit)

            // An empty batch teaches nothing that can be verified, so its cursor is
            // not stored. The one already held returns the same empty answer next
            // time at no cost, and advancing on the strength of an empty response is
            // the one way left to skip an op.
            //
            // A batch whose every entry was unreadable is *not* empty in that sense:
            // the server sent rows and the cursor has to clear them or the same
            // unreadable page comes back forever.
            guard !response.ops.isEmpty || response.unreadableOps > 0 else { break }

            var applied = try store.apply(
                response.ops,
                advancingTo: response.cursor,
                policy: policy,
                now: clock()
            )
            applied.unreadable = response.unreadableOps
            applied.pulled += response.unreadableOps
            report.absorb(applied)
            transition(to: .pulling(applied: report.applied))

            // The batch was applied before this check, because applying is idempotent
            // and skipping it could drop ops. Looping on it could not: a cursor that
            // does not advance means the next request asks the same question and gets
            // the same answer.
            if let cursor, response.cursor.value <= cursor.value { break }
            cursor = response.cursor

            guard response.hasMore else { break }
        }

        return report
    }

    // MARK: - Progress

    private func transition(to phase: SyncPhase) {
        self.phase = phase
        observer?(phase)
    }
}
