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
    /// Covers sent this sync. Counted separately from `pushed` because they are not
    /// ops — a sync that uploaded three pictures and no changes did do something.
    public var imagesUploaded = 0

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
        imagesUploaded += other.imagesUploaded
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
    /// Both optional: a sidecar without the image endpoints still syncs everything
    /// else, and covers simply stay on the device that chose them.
    private let images: (any SyncImageTransport)?
    private let imageBytes: (any ImageByteSource)?
    private let policy: SyncPolicy
    private let clock: @Sendable () -> Millis
    private let observer: (@Sendable (SyncPhase) -> Void)?

    public private(set) var phase: SyncPhase = .idle
    public private(set) var lastReport: SyncReport?

    private var running = false

    public init(
        store: CurationStore,
        transport: any SyncTransport,
        images: (any SyncImageTransport)? = nil,
        imageBytes: (any ImageByteSource)? = nil,
        policy: SyncPolicy = .default,
        clock: @escaping @Sendable () -> Millis = { Date().millis },
        onPhaseChange observer: (@Sendable (SyncPhase) -> Void)? = nil
    ) {
        self.store = store
        self.transport = transport
        self.images = images
        self.imageBytes = imageBytes
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
            // Before push, never after: an op naming a hash the server does not hold
            // leaves every other device with a cover it can never fetch, and nothing
            // afterwards notices — the playlist row is perfectly valid.
            let uploaded = try await uploadPendingImages()
            var report = try await pushPending()
            report.imagesUploaded = uploaded
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

    /// Finds which op the server chokes on by halving the batch, and quarantines it.
    ///
    /// Binary search rather than one-at-a-time: a batch of 250 costs eight round trips
    /// instead of 250, and a server that is failing is the last thing to send 250
    /// requests to. A half that succeeds is genuinely pushed on the way past, so the
    /// search makes progress rather than merely diagnosing.
    ///
    /// If a half stops failing when sent alone, the fault was transient — a restart,
    /// a timeout — and nothing is quarantined. That is the important asymmetry: only
    /// an op that reproduces the failure *by itself* is blamed for it.
    private func isolateServerFault(
        _ wire: [WireOp],
        pending: [Op],
        status: Int
    ) async throws -> (quarantined: Int, pushed: Int) {
        guard let single = wire.first, wire.count == 1 else {
            let middle = wire.count / 2
            var quarantined = 0
            var pushed = 0
            for half in [Array(wire[..<middle]), Array(wire[middle...])] where !half.isEmpty {
                do {
                    let response = try await transport.push(
                        PushRequest(deviceId: store.deviceId, ops: half)
                    )
                    try store.markSynced(response.accepted)
                    pushed += response.accepted.count
                } catch let error as SyncTransportFault where error.isServerFault {
                    let inner = try await isolateServerFault(
                        half, pending: pending, status: error.status
                    )
                    quarantined += inner.quarantined
                    pushed += inner.pushed
                }
            }
            return (quarantined, pushed)
        }

        guard let op = pending.first(where: { $0.opId == single.opId }) else { return (0, 0) }
        try store.quarantine(op, reason: .serverFaulted(status: status), at: clock())
        return (1, 0)
    }

    /// Gets every cover named by a waiting op onto the server, before any of them are
    /// pushed.
    ///
    /// The ordering is the whole rule: an op naming a hash the server does not have
    /// leaves every other device holding a playlist whose cover can never be fetched,
    /// and nothing later notices — the row is valid, the image simply is not there.
    /// Uploading first costs one HEAD per new cover and makes that impossible.
    ///
    /// A cover that cannot be uploaded does *not* fail the sync. Everything else
    /// still pushes, and the op naming it waits — a playlist arriving without its
    /// picture a few minutes late is a far smaller thing than a device that stops
    /// syncing because one image would not go.
    private func uploadPendingImages() async throws -> Int {
        guard let images, let bytes = imageBytes else { return 0 }

        var uploaded = 0
        for blob in try store.imagesNeededBeforePush() {
            // Asked before sent: another device may have uploaded the same bytes
            // already, which content addressing makes not merely possible but likely
            // for a cover shared between playlists.
            if try await images.hasImage(sha256: blob.hash) {
                try store.markImageUploaded(blob.hash, at: clock())
                continue
            }
            guard let data = await bytes.bytes(for: blob.hash) else { continue }
            try await images.uploadImage(sha256: blob.hash, data: data, mime: blob.mime)
            try store.markImageUploaded(blob.hash, at: clock())
            uploaded += 1
        }
        return uploaded
    }

    private func pushPending() async throws -> SyncReport {
        var report = SyncReport()
        var previousBatch: Set<String> = []
        /// What the previous round trip came back with, kept so a stall can say why.
        var lastExchange = (accepted: 0, rejected: 0, unmatched: 0)

        while true {
            let pending = try store.pendingOps(limit: policy.pushBatchSize)
            guard !pending.isEmpty else { break }

            // A batch identical to the last one means the round trip accepted
            // nothing, rejected nothing and quarantined nothing, so the next attempt
            // sends the same bytes to the same effect. Better to surface a stall than
            // to hold the connection open forever making no progress.
            let ids = Set(pending.map(\.opId))
            guard ids != previousBatch else {
                throw SyncError.pushStalled(
                    pending: pending.count,
                    accepted: lastExchange.accepted,
                    rejected: lastExchange.rejected,
                    unmatchedRejections: lastExchange.unmatched
                )
            }
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

            let response: PushResponse
            do {
                response = try await transport.push(
                    PushRequest(deviceId: store.deviceId, ops: wire)
                )
            } catch let error as SyncTransportFault where error.isServerFault {
                // The server threw on this batch. Retrying it unchanged sends the same
                // bytes to the same effect forever, and every innocent op behind it
                // waits on one the server cannot swallow — the same wedge `rejected`
                // exists to prevent, arriving as a 5xx where the contract has no story
                // for it. Bisecting finds the offender, quarantines that one alone,
                // and lets the rest through.
                let isolated = try await isolateServerFault(wire, pending: pending, status: error.status)
                report.quarantinedOutbound += isolated.quarantined
                // Halves that succeeded on the way past were genuinely pushed, so the
                // search makes progress rather than only diagnosing.
                report.pushed += isolated.pushed
                previousBatch = []
                continue
            }

            // `accepted` includes ops the server had already seen, so a push that
            // timed out and was sent again acknowledges everything rather than
            // stranding the duplicate half.
            try store.markSynced(response.accepted)
            report.pushed += response.accepted.count

            var unmatched = 0
            if !response.rejected.isEmpty {
                let byId = Dictionary(pending.map { ($0.opId, $0) }, uniquingKeysWith: { first, _ in first })
                for rejection in response.rejected {
                    // A rejected op will never be accepted. Retrying it is an
                    // infinite loop, so it leaves the queue here and is surfaced
                    // instead.
                    guard let op = byId[rejection.opId] else {
                        // A rejection naming an op that was not in this batch. Dropped
                        // silently, this is indistinguishable from the server saying
                        // nothing at all — and it produces the same stall, so the
                        // count has to survive to explain it.
                        unmatched += 1
                        continue
                    }
                    try store.quarantine(op, reason: .serverRejected(rejection.reason), at: clock())
                    report.quarantinedOutbound += 1
                    report.rejected += 1
                }
            }
            lastExchange = (response.accepted.count, response.rejected.count, unmatched)

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
