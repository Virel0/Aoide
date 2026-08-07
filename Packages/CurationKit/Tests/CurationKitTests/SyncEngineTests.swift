import Foundation
import GRDB
import Testing
@testable import CurationKit

@Suite("Sync engine")
struct SyncEngineTests {
    private func engine(
        _ store: CurationStore,
        _ server: FakeSyncServer,
        policy: SyncPolicy = .default,
        onPhaseChange: (@Sendable (SyncPhase) -> Void)? = nil
    ) -> SyncEngine {
        SyncEngine(store: store, transport: server, policy: policy, clock: { 10_000 }, onPhaseChange: onPhaseChange)
    }

    // MARK: - Push

    @Test("pending ops are pushed and stop being pending")
    func pushesAndAcknowledges() async throws {
        let store = try CurationStore.inMemory(deviceId: "phone")
        try store.createPlaylist(name: "Focus")
        let server = FakeSyncServer()

        let report = try await engine(store, server).sync()

        #expect(report.pushed == 1)
        #expect(try store.pendingOps().isEmpty)
        #expect(await server.log.count == 1)
        #expect(await server.log[0].op.entity == "playlists")
        #expect(await server.lastPushedDeviceId == "phone")
    }

    @Test("nothing pending means nothing is pushed")
    func nothingToPush() async throws {
        let store = try CurationStore.inMemory(deviceId: "phone")
        let server = FakeSyncServer()
        _ = try await engine(store, server).sync()
        #expect(await server.pushCount == 0)
    }

    /// The engine's local validation and the server's rules have to agree, or the
    /// first real sync is a pile of rejections. A faithful double is what makes this
    /// evidence rather than decoration.
    @Test("a realistic set of local changes is accepted whole")
    func realWorkPushesCleanly() async throws {
        let store = try CurationStore.inMemory(deviceId: "phone")
        let list = try store.createPlaylist(name: "Late Night")
        try store.addTracks(
            (0..<5).map { TrackLink(jellyfinId: "t\($0)", contentKey: "k\($0)") },
            to: list.id
        )
        let folder = try store.createFolder(name: "Mixes")
        try store.move(playlist: list.id, toFolder: folder.id)
        try store.record(Like(jellyfinId: "t1", contentKey: "k1", liked: true, updatedAt: 1, originDevice: "phone"))
        try store.append(PlayEvent(jellyfinId: "t1", contentKey: "k1", startedAt: 1, originDevice: "phone"))
        try store.saveQueue(deviceName: "iPhone", trackIds: ["t0", "t1"], position: 0, elapsedMs: 0)
        try store.deletePlaylist(list.id)

        let pending = try store.pendingOps(limit: 1_000).count
        let server = FakeSyncServer()
        let report = try await engine(store, server).sync()

        #expect(report.pushed == pending)
        #expect(report.quarantinedOutbound == 0)
        #expect(try store.quarantineCount() == 0)
    }

    @Test("pushes are split into batches no larger than the policy allows")
    func batching() async throws {
        let store = try CurationStore.inMemory(deviceId: "phone")
        for index in 0..<25 {
            try store.createPlaylist(name: "List \(index)")
        }
        let server = FakeSyncServer()

        let report = try await engine(store, server, policy: SyncPolicy(pushBatchSize: 10)).sync()

        #expect(report.pushed == 25)
        #expect(await server.pushCount == 3)
        #expect(await server.largestBatchSeen == 10)
        #expect(try store.pendingOps().isEmpty)
    }

    /// Over the limit the server 400s the *whole* push, valid ops included, so the
    /// ceiling is never a number to send.
    @Test("the batch size can never exceed the server's ceiling")
    func batchCeiling() {
        #expect(SyncPolicy(pushBatchSize: 5_000).pushBatchSize == SyncPolicy.maxBatch)
        #expect(SyncPolicy(pushBatchSize: 0).pushBatchSize == 1)
        #expect(SyncPolicy(pullLimit: 5_000).pullLimit == SyncPolicy.maxPullLimit)
        #expect(SyncPolicy.default.pushBatchSize <= SyncPolicy.maxBatch)
    }

    /// Re-pushing an op the server already holds is accepted and ignored — the
    /// property that makes retrying a timed-out push safe.
    @Test("a push that times out can simply be sent again")
    func retryAfterTimeout() async throws {
        let store = try CurationStore.inMemory(deviceId: "phone")
        try store.createPlaylist(name: "Focus")
        let server = FakeSyncServer()
        let engine = engine(store, server)

        await server.goOfflineForNextPush()
        await #expect(throws: FakeServerError.offline) { try await engine.sync() }
        #expect(try store.pendingOps().count == 1)

        let report = try await engine.sync()
        #expect(report.pushed == 1)
        #expect(try store.pendingOps().isEmpty)
        #expect(await server.log.count == 1)
    }

    @Test("an op the server rejects is quarantined and never sent again")
    func rejectionIsFinal() async throws {
        let store = try CurationStore.inMemory(deviceId: "phone")
        try store.createPlaylist(name: "Doomed")
        try store.createPlaylist(name: "Fine")
        let doomed = try #require(try store.pendingOps().first)

        let server = FakeSyncServer()
        await server.reject(doomed.opId, reason: "payload failed validation")
        let engine = engine(store, server)

        let report = try await engine.sync()
        #expect(report.rejected == 1)
        #expect(report.pushed == 1)
        #expect(try store.pendingOps().isEmpty)

        let quarantined = try #require(try store.quarantinedOps().first)
        #expect(quarantined.opId == doomed.opId)
        #expect(quarantined.syncDirection == .outbound)
        #expect(quarantined.reason.contains("payload failed validation"))

        // A second sync must not resurrect it.
        let pushesBefore = await server.pushCount
        _ = try await engine.sync()
        #expect(await server.pushCount == pushesBefore)
        #expect(try store.quarantineCount() == 1)
    }

    /// Cheaper than a round trip that learns nothing, and it keeps the queue moving:
    /// an op that would certainly bounce sits at the head being retried otherwise.
    @Test("an op that would certainly bounce is quarantined before it is sent")
    func invalidOpsNeverLeave() async throws {
        let store = try CurationStore.inMemory(deviceId: "phone")
        try store.writeLocal { db in
            try Op(
                opId: "bad-1",
                entity: "track",
                entityId: "t1",
                operation: .upsert,
                payload: #"{"id":"t1"}"#,
                createdAt: 1_000
            ).insert(db)
        }
        try store.createPlaylist(name: "Fine")

        let server = FakeSyncServer()
        let report = try await engine(store, server).sync()

        #expect(report.quarantinedOutbound == 1)
        #expect(report.rejected == 0)
        #expect(report.pushed == 1)
        // The invalid one never reached the server at all.
        #expect(await server.log.count == 1)
        #expect(try store.quarantinedOps().first?.reason.contains("'track'") == true)
    }

    @Test("a whole batch of invalid ops still lets the queue drain")
    func allInvalid() async throws {
        let store = try CurationStore.inMemory(deviceId: "phone")
        try store.writeLocal { db in
            for index in 0..<3 {
                try Op(opId: "bad-\(index)", entity: "track", entityId: "t\(index)",
                       operation: .upsert, payload: #"{"id":"t"}"#, createdAt: Millis(index + 1)).insert(db)
            }
        }
        let server = FakeSyncServer()
        let report = try await engine(store, server, policy: SyncPolicy(pushBatchSize: 2)).sync()

        #expect(report.quarantinedOutbound == 3)
        #expect(try store.pendingOps().isEmpty)
        #expect(await server.pushCount == 0)
    }

    /// A server that accepts nothing and rejects nothing would otherwise hold the
    /// connection open forever, re-sending the same bytes.
    @Test("a push that changes nothing is reported rather than retried forever")
    func pushStall() async throws {
        let store = try CurationStore.inMemory(deviceId: "phone")
        try store.createPlaylist(name: "Focus")
        let server = FakeSyncServer()
        await server.setAcceptNothing(true)

        // The counts are part of the assertion now: a stall that cannot say whether
        // the server answered is the failure this whole error exists to describe.
        await #expect(throws: SyncError.pushStalled(
            pending: 1, accepted: 0, rejected: 0, unmatchedRejections: 0
        )) {
            try await self.engine(store, server).sync()
        }
        #expect(try store.pendingOps().count == 1)
    }

    // MARK: - Cursors

    /// The push cursor is the head of the *whole* log. Storing it as the read
    /// position skips every op another device pushed below it, permanently.
    @Test("the push cursor is never mistaken for the pull cursor")
    func cursorsStayApart() async throws {
        let store = try CurationStore.inMemory(deviceId: "phone")
        let server = FakeSyncServer()

        // Ten ops from another device are already on the server.
        var seeded: [WireOp] = []
        for index in 0..<10 {
            let list = makePlaylist(id: "mac-\(index)", name: "Mac \(index)", updatedAt: 1_000, device: "mac")
            seeded.append(WireOp(
                opId: "mac-op-\(index)",
                entity: SyncEntity.playlist.wireName,
                entityId: list.id,
                operation: "upsert",
                payload: try Wire.payload(list),
                createdAt: 1_000
            ))
        }
        await server.seed(seeded, from: "mac")

        // This device pushes one of its own, which lands above all of them.
        //
        // Stamped from the same clock the engine is given. Letting it default to
        // `Date().millis` while the engine's clock says 10 seconds past the epoch would
        // describe a device whose writes are decades ahead of its own clock, which is
        // the shape the merge reads as a clock that has been fixed since.
        try store.createPlaylist(name: "Mine", now: 9_000)
        let report = try await engine(store, server).sync()

        // Had the push response's cursor been stored, the pull would have started
        // above every one of the mac's ops and applied none of them.
        #expect(report.pushed == 1)
        #expect(report.pulled == 11)
        // Ten from the mac; the eleventh is ours coming back, which loses to the row
        // that wrote it.
        #expect(report.applied == 10)
        #expect(try store.playlists().count == 11)
        #expect(try store.pullCursor() == PullCursor(await server.head))
    }

    /// Storing the cursor only with the batch it describes is what makes an
    /// interrupted sync replay rather than skip.
    @Test("an interrupted pull resumes from the last batch it applied")
    func interruptedPullReplays() async throws {
        let store = try CurationStore.inMemory(deviceId: "phone")
        let server = FakeSyncServer()

        var seeded: [WireOp] = []
        for index in 0..<10 {
            let list = makePlaylist(id: "mac-\(index)", name: "Mac \(index)", updatedAt: 1_000, device: "mac")
            seeded.append(WireOp(
                opId: "mac-op-\(index)", entity: SyncEntity.playlist.wireName, entityId: list.id,
                operation: "upsert", payload: try Wire.payload(list), createdAt: 1_000
            ))
        }
        await server.seed(seeded, from: "mac")
        await server.failPull(atCall: 2)

        let engine = engine(store, server, policy: SyncPolicy(pullLimit: 4))
        await #expect(throws: FakeServerError.offline) { try await engine.sync() }

        #expect(try store.playlists().count == 4)
        #expect(try store.pullCursor() == PullCursor(4))

        let report = try await engine.sync()
        #expect(report.applied == 6)
        #expect(try store.playlists().count == 10)
    }

    @Test("hasMore drives the pull until the log runs out")
    func pullPaging() async throws {
        let store = try CurationStore.inMemory(deviceId: "phone")
        let server = FakeSyncServer()

        var seeded: [WireOp] = []
        for index in 0..<9 {
            let list = makePlaylist(id: "mac-\(index)", name: "Mac \(index)", updatedAt: 1_000, device: "mac")
            seeded.append(WireOp(
                opId: "mac-op-\(index)", entity: SyncEntity.playlist.wireName, entityId: list.id,
                operation: "upsert", payload: try Wire.payload(list), createdAt: 1_000
            ))
        }
        await server.seed(seeded, from: "mac")

        let report = try await engine(store, server, policy: SyncPolicy(pullLimit: 4)).sync()
        #expect(report.pulled == 9)
        #expect(report.applied == 9)
        // Two full pages and a short one. `hasMore` is exact, so the short page ends
        // the loop rather than costing an extra empty round trip.
        #expect(await server.pullCount == 3)
    }

    /// Advancing on the strength of an empty response is the one way left to skip
    /// an op.
    @Test("an empty pull does not move the cursor")
    func emptyPullKeepsCursor() async throws {
        let store = try CurationStore.inMemory(deviceId: "phone")
        let server = FakeSyncServer()

        let report = try await engine(store, server).sync()
        #expect(report.pulled == 0)
        #expect(try store.pullCursor() == nil)
    }

    // MARK: - Two devices

    @Test("a playlist made on one device arrives whole on the other")
    func roundTrip() async throws {
        let server = FakeSyncServer()
        let phone = try CurationStore.inMemory(deviceId: "phone")
        let mac = try CurationStore.inMemory(deviceId: "mac")

        let list = try phone.createPlaylist(name: "Late Night")
        try phone.addTracks(
            (0..<3).map { TrackLink(jellyfinId: "t\($0)", contentKey: "k\($0)") },
            to: list.id
        )
        _ = try await engine(phone, server).sync()
        _ = try await engine(mac, server).sync()

        #expect(try mac.playlists().map(\.name) == ["Late Night"])
        #expect(try mac.items(in: list.id).map(\.jellyfinId) == ["t0", "t1", "t2"])
        // And the merge produced nothing to push back.
        #expect(try mac.pendingOps().isEmpty)
    }

    @Test("an edit made on the second device comes back to the first")
    func editsFlowBothWays() async throws {
        let server = FakeSyncServer()
        let phone = try CurationStore.inMemory(deviceId: "phone")
        let mac = try CurationStore.inMemory(deviceId: "mac")
        let phoneEngine = engine(phone, server)
        let macEngine = engine(mac, server)

        let list = try phone.createPlaylist(name: "Draft", now: 1_000)
        _ = try await phoneEngine.sync()
        _ = try await macEngine.sync()

        try mac.rename(playlist: list.id, to: "Final", now: 5_000)
        _ = try await macEngine.sync()
        _ = try await phoneEngine.sync()

        #expect(try phone.playlist(list.id)?.name == "Final")
        #expect(try mac.playlist(list.id)?.name == "Final")
    }

    /// Concurrent edits to one row: per-row last-writer-wins, and both devices must
    /// land on the same answer.
    @Test("two devices editing one playlist converge")
    func concurrentEditsConverge() async throws {
        let server = FakeSyncServer()
        let phone = try CurationStore.inMemory(deviceId: "phone")
        let mac = try CurationStore.inMemory(deviceId: "mac")
        let phoneEngine = engine(phone, server)
        let macEngine = engine(mac, server)

        let list = try phone.createPlaylist(name: "Shared", now: 1_000)
        _ = try await phoneEngine.sync()
        _ = try await macEngine.sync()

        try phone.rename(playlist: list.id, to: "From phone", now: 5_000)
        try mac.rename(playlist: list.id, to: "From mac", now: 6_000)

        _ = try await phoneEngine.sync()
        _ = try await macEngine.sync()
        _ = try await phoneEngine.sync()

        #expect(try phone.playlist(list.id)?.name == "From mac")
        #expect(try mac.playlist(list.id)?.name == "From mac")
    }

    /// Fractional indexing means concurrent inserts do not conflict at all: each
    /// writes one row, and both survive.
    @Test("two devices adding tracks at once both keep their additions")
    func concurrentInsertsBothSurvive() async throws {
        let server = FakeSyncServer()
        let phone = try CurationStore.inMemory(deviceId: "phone")
        let mac = try CurationStore.inMemory(deviceId: "mac")
        let phoneEngine = engine(phone, server)
        let macEngine = engine(mac, server)

        let list = try phone.createPlaylist(name: "Shared", now: 1_000)
        _ = try await phoneEngine.sync()
        _ = try await macEngine.sync()

        try phone.addTracks([TrackLink(jellyfinId: "p1", contentKey: "kp1")], to: list.id, now: 5_000)
        try mac.addTracks([TrackLink(jellyfinId: "m1", contentKey: "km1")], to: list.id, now: 5_000)

        _ = try await phoneEngine.sync()
        _ = try await macEngine.sync()
        _ = try await phoneEngine.sync()

        // Both survive. Their relative order is arbitrary and deliberately not
        // asserted: appending to an empty playlist on two devices produces the same
        // position key on both, and a tie between equal keys is the one thing
        // fractional indexing does not promise to settle. Losing an insert would be
        // the failure; disagreeing about which of two simultaneous ones comes first
        // is not.
        #expect(Set(try phone.items(in: list.id).map(\.jellyfinId)) == ["p1", "m1"])
        #expect(Set(try mac.items(in: list.id).map(\.jellyfinId)) == ["p1", "m1"])
    }

    /// Syncing twice with nothing new must be silent — a second run that queues work
    /// is the ping-pong failure showing up at the loop level.
    @Test("syncing again with nothing new does nothing at all")
    func idleSyncIsSilent() async throws {
        let server = FakeSyncServer()
        let phone = try CurationStore.inMemory(deviceId: "phone")
        let mac = try CurationStore.inMemory(deviceId: "mac")

        try phone.createPlaylist(name: "Focus")
        _ = try await engine(phone, server).sync()
        _ = try await engine(mac, server).sync()

        let macEngine = engine(mac, server)
        let second = try await macEngine.sync()
        #expect(second.pushed == 0)
        #expect(second.pulled == 0)
        #expect(second.isEmpty)

        let logCount = await server.log.count
        _ = try await macEngine.sync()
        #expect(await server.log.count == logCount)
    }

    @Test("history from another device lands once, however often it is pulled")
    func historyConverges() async throws {
        let server = FakeSyncServer()
        let phone = try CurationStore.inMemory(deviceId: "phone")
        let mac = try CurationStore.inMemory(deviceId: "mac")

        for index in 0..<4 {
            try phone.append(PlayEvent(
                jellyfinId: "t\(index)", contentKey: "k\(index)",
                startedAt: Millis(1_000 + index), msPlayed: 200_000, completed: true, originDevice: "phone"
            ))
        }
        _ = try await engine(phone, server).sync()

        let macEngine = engine(mac, server)
        _ = try await macEngine.sync()
        _ = try await macEngine.sync()

        #expect(try mac.read { try PlayEvent.fetchCount($0) } == 4)
    }

    // MARK: - Running once at a time

    /// An actor is not enough on its own: the loop suspends at every network call,
    /// and a second caller walks in during one of those suspensions.
    @Test("two syncs cannot run at once")
    func reentrancy() async throws {
        let store = try CurationStore.inMemory(deviceId: "phone")
        let server = FakeSyncServer()
        await server.setPullDelay(nanos: 300_000_000)
        let engine = engine(store, server)

        async let first: SyncReport = engine.sync()
        try await Task.sleep(nanoseconds: 50_000_000)
        await #expect(throws: SyncError.alreadyRunning) { try await engine.sync() }
        _ = try await first

        // And the refusal is not permanent — the flag is cleared when the run ends.
        _ = try await engine.sync()
    }

    @Test("a failed sync does not leave the engine locked")
    func failureUnlocks() async throws {
        let store = try CurationStore.inMemory(deviceId: "phone")
        try store.createPlaylist(name: "Focus")
        let server = FakeSyncServer()
        let engine = engine(store, server)

        await server.goOfflineForNextPush()
        await #expect(throws: FakeServerError.offline) { try await engine.sync() }
        #expect(try await engine.sync().pushed == 1)
    }

    // MARK: - Reporting

    @Test("the engine reports where it got to")
    func phases() async throws {
        let store = try CurationStore.inMemory(deviceId: "phone")
        // From the engine's own clock; see `cursorsStayApart`.
        try store.createPlaylist(name: "Focus", now: 9_000)
        let server = FakeSyncServer()

        let phases = PhaseLog()
        let engine = engine(store, server) { phases.record($0) }
        _ = try await engine.sync()

        let seen = phases.recorded
        #expect(seen.contains(SyncPhase.pushing(pushed: 1)))
        // Our own op comes straight back down and loses to the row that wrote it.
        #expect(seen.contains(SyncPhase.pulling(applied: 0)))
        #expect(seen.last == SyncPhase.idle)
        #expect(await engine.phase == .idle)
    }

    @Test("a failure is reported as one, with a reason")
    func failedPhase() async throws {
        let store = try CurationStore.inMemory(deviceId: "phone")
        try store.createPlaylist(name: "Focus")
        let server = FakeSyncServer()
        await server.goOfflineForNextPush()
        let engine = engine(store, server)

        await #expect(throws: FakeServerError.offline) { try await engine.sync() }
        guard case .failed(let reason) = await engine.phase else {
            Issue.record("expected a failed phase")
            return
        }
        #expect(reason.contains("offline"))
        #expect(await engine.lastReport == nil)
    }

    @Test("the last report survives for a UI to read")
    func lastReport() async throws {
        let store = try CurationStore.inMemory(deviceId: "phone")
        try store.createPlaylist(name: "Focus")
        let server = FakeSyncServer()
        let engine = engine(store, server)
        _ = try await engine.sync()

        #expect(await engine.lastReport?.pushed == 1)
        #expect(await engine.lastReport?.isEmpty == false)
    }

    @Test("quarantined ops are countable and discardable")
    func quarantineHousekeeping() async throws {
        let store = try CurationStore.inMemory(deviceId: "phone")
        try store.createPlaylist(name: "Doomed")
        let doomed = try #require(try store.pendingOps().first)
        let server = FakeSyncServer()
        await server.reject(doomed.opId, reason: "nope")

        _ = try await engine(store, server).sync()
        #expect(try store.quarantineCount() == 1)

        try store.discardQuarantined([doomed.opId])
        #expect(try store.quarantineCount() == 0)
        // Discarding does not re-queue it.
        #expect(try store.pendingOps().isEmpty)
    }

    /// A page whose every entry was unreadable is not the same as an empty one. Empty
    /// means "nothing above your cursor", and its cursor is deliberately not stored;
    /// this page has rows in it, and leaving the cursor where it is means asking for the
    /// same unreadable page forever.
    @Test("a batch of nothing but unreadable ops still moves the cursor on")
    func unreadableBatchDoesNotStall() async throws {
        let store = try CurationStore.inMemory(deviceId: "phone")
        let engine = SyncEngine(store: store, transport: UnreadablePull(), clock: { 10_000 })

        let report = try await engine.sync()

        #expect(report.unreadable == 2)
        #expect(report.applied == 0)
        #expect(try store.pullCursor() == PullCursor(9))
    }
}

/// A server whose first page is two ops this build cannot read at all, and nothing
/// after it.
private struct UnreadablePull: SyncTransport {
    func push(_ request: PushRequest) async throws -> PushResponse {
        PushResponse(accepted: request.ops.map(\.opId))
    }

    func pull(since cursor: PullCursor?, limit: Int) async throws -> PullResponse {
        guard cursor == nil else { return PullResponse(ops: [], cursor: PullCursor(9), hasMore: false) }
        return PullResponse(ops: [], cursor: PullCursor(9), hasMore: false, unreadableOps: 2)
    }
}
