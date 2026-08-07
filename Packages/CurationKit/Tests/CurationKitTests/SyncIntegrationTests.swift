import Foundation
import GRDB
import Testing
@testable import CurationKit

/// The sync engine driven end to end against a sidecar that enforces the contract.
///
/// Everything here goes through `SyncEngine.sync()` and `Sidecar` rather than poking
/// at the merge directly, because the failures this file exists to catch are the ones
/// that only exist between the parts: a cursor stored from the wrong response, an
/// apply that queues an op, a batch that splits and loses its tail. Unit tests for the
/// merge live in `SyncMergeTests`; these are about what two devices end up holding.
@Suite("Sync against a faithful sidecar")
struct SyncIntegrationTests {
    /// `clock` is *this device's* clock, and the skew tests set it per device on
    /// purpose: a phone whose writes say 2096 has an engine that reads 2096 too, and
    /// modelling one half broken would test a device that cannot exist.
    private func engine(
        _ store: CurationStore,
        _ link: SidecarLink,
        policy: SyncPolicy = .default,
        clock: @escaping @Sendable () -> Millis = { 2_000_000_000_000 }
    ) -> SyncEngine {
        SyncEngine(store: store, transport: link, policy: policy, clock: clock)
    }

    /// Puts a device's pending ops on the server without pulling anything back.
    ///
    /// A device that pushed and then went offline, and — more usefully here — a way to
    /// seed the log that does not spend the pull calls a test is counting.
    private func pushOnly(_ store: CurationStore, to link: SidecarLink) async throws {
        var pending = try store.pendingOps(limit: 5_000)
        while !pending.isEmpty {
            let batch = Array(pending.prefix(1_000))
            let wire = batch.compactMap { try? WireOp.make(from: $0).get() }
            let response = try await link.push(PushRequest(deviceId: store.deviceId, ops: wire))
            try store.markSynced(response.accepted)
            pending = Array(pending.dropFirst(batch.count))
        }
    }

    /// A library with something of every syncable kind in it, at fixed times.
    ///
    /// Fixed rather than `Date().millis` so a convergence failure is a real
    /// disagreement rather than two devices having read the clock a millisecond apart.
    @discardableResult
    private func buildLibrary(on store: CurationStore, device: String) throws -> (list: String, focus: String) {
        let folder = try store.createFolder(name: "Mixes", now: 1_000)
        let late = try store.createPlaylist(
            name: "Late Night", folderId: folder.id, notes: "for the drive", now: 1_100
        )
        try store.addTracks(
            (0..<4).map { TrackLink(jellyfinId: "t\($0)", contentKey: "k\($0)") },
            to: late.id, now: 1_200
        )
        let focus = try store.createPlaylist(name: "Focus", now: 1_300)
        try store.addTracks([TrackLink(jellyfinId: "t9", contentKey: "k9")], to: focus.id, now: 1_400)
        try store.record(
            Like(jellyfinId: "t1", contentKey: "k1", liked: true, updatedAt: 0, originDevice: device),
            at: 1_500
        )
        for index in 0..<3 {
            try store.append(PlayEvent(
                id: "\(device)-e\(index)", jellyfinId: "t\(index)", contentKey: "k\(index)",
                startedAt: Millis(1_600 + index), msPlayed: 200_000, completed: true, originDevice: device
            ))
        }
        try store.saveQueue(
            deviceName: "The \(device)", trackIds: ["t0", "t1", "t2"], position: 1, elapsedMs: 4_000, at: 1_700
        )
        // A soft delete and an edit, so deleted rows and second versions travel too.
        try store.removeItem(try store.items(in: late.id)[1].id, now: 1_800)
        try store.rename(playlist: focus.id, to: "Deep Focus", now: 1_900)
        return (late.id, focus.id)
    }

    // MARK: - 1. Round trip

    /// The headline. Not "the playlist arrived" — every column of every syncable table,
    /// deleted rows included, because two devices that agree on names while disagreeing
    /// on a flag have already diverged and will keep diverging.
    @Test("a library made on one device arrives on the other, byte for byte")
    func roundTripConverges() async throws {
        let sidecar = Sidecar()
        let phone = try CurationStore.inMemory(deviceId: "phone")
        let mac = try CurationStore.inMemory(deviceId: "mac")
        let ids = try buildLibrary(on: phone, device: "phone")

        let queued = try phone.pendingOps(limit: 5_000).count
        let sent = try await engine(phone, sidecar.link()).sync()
        #expect(sent.pushed == queued)
        #expect(sent.quarantinedOutbound == 0)
        #expect(sent.rejected == 0)

        let received = try await engine(mac, sidecar.link()).sync()
        #expect(received.pulled == queued)
        #expect(received.applied == queued)
        #expect(received.quarantinedInbound == 0)

        let phoneRows = try syncedRows(of: phone)
        let macRows = try syncedRows(of: mac)
        #expect(macRows == phoneRows)

        // Not vacuously equal: the library really is there, and reads the same way.
        #expect(try mac.playlists().map(\.name) == ["Late Night", "Deep Focus"])
        #expect(try mac.items(in: ids.list).map(\.jellyfinId) == ["t0", "t2", "t3"])
        #expect(try mac.folders().map(\.name) == ["Mixes"])
        #expect(try mac.read { try PlayEvent.fetchCount($0) } == 3)
        #expect(try mac.resumableQueues(now: 2_000, within: .max).map(\.deviceName) == ["The phone"])
    }

    @Test("edits made on the second device come back to the first")
    func editsFlowBothWays() async throws {
        let sidecar = Sidecar()
        let phone = try CurationStore.inMemory(deviceId: "phone")
        let mac = try CurationStore.inMemory(deviceId: "mac")
        let phoneSync = engine(phone, sidecar.link())
        let macSync = engine(mac, sidecar.link())

        let ids = try buildLibrary(on: phone, device: "phone")
        _ = try await phoneSync.sync()
        _ = try await macSync.sync()

        try mac.rename(playlist: ids.list, to: "Very Late Night", now: 5_000)
        try mac.addTracks([TrackLink(jellyfinId: "t7", contentKey: "k7")], to: ids.list, now: 5_100)
        try mac.deletePlaylist(ids.focus, now: 5_200)
        _ = try await macSync.sync()
        _ = try await phoneSync.sync()

        #expect(try phone.playlist(ids.list)?.name == "Very Late Night")
        #expect(try phone.items(in: ids.list).map(\.jellyfinId) == ["t0", "t2", "t3", "t7"])
        #expect(try phone.playlist(ids.focus) == nil)

        let phoneRows = try syncedRows(of: phone)
        let macRows = try syncedRows(of: mac)
        #expect(macRows == phoneRows)
        #expect(try phone.pendingOps().isEmpty)
        #expect(try mac.pendingOps().isEmpty)
    }

    /// Three devices is where an order-dependent merge shows up: each of them sees the
    /// same ops but has a different set of rows already in place when they arrive.
    @Test("three devices editing in turn all end up holding the same rows")
    func threeDevicesConverge() async throws {
        let sidecar = Sidecar()
        let phone = try CurationStore.inMemory(deviceId: "phone")
        let mac = try CurationStore.inMemory(deviceId: "mac")
        let pad = try CurationStore.inMemory(deviceId: "pad")
        let syncs = [engine(phone, sidecar.link()), engine(mac, sidecar.link()), engine(pad, sidecar.link())]

        let ids = try buildLibrary(on: phone, device: "phone")
        for sync in syncs { _ = try await sync.sync() }

        try mac.rename(playlist: ids.list, to: "From the mac", now: 6_000)
        try mac.record(Like(jellyfinId: "t3", contentKey: "k3", liked: true, updatedAt: 0, originDevice: "mac"), at: 6_100)
        try pad.addTracks([TrackLink(jellyfinId: "t5", contentKey: "k5")], to: ids.list, now: 6_200)
        try phone.deletePlaylist(ids.focus, now: 6_300)

        // Two full rounds: one to get everybody's work onto the server, one for
        // everybody to read everybody else's.
        for _ in 0..<2 {
            for sync in syncs { _ = try await sync.sync() }
        }

        let rows = try [phone, mac, pad].map { try syncedRows(of: $0) }
        #expect(rows[0] == rows[1])
        #expect(rows[1] == rows[2])
        #expect(try pad.playlist(ids.list)?.name == "From the mac")
        #expect(try phone.items(in: ids.list).map(\.jellyfinId) == ["t0", "t2", "t3", "t5"])
    }

    /// The sidecar keys its log by user, and nothing crosses. A device signed in as
    /// somebody else must see none of this user's ops — and the global sequence must
    /// not leak them either.
    @Test("one user's ops are invisible to another")
    func perUserLogs() async throws {
        let sidecar = Sidecar()
        let mine = try CurationStore.inMemory(deviceId: "phone")
        let theirs = try CurationStore.inMemory(deviceId: "their-phone")

        try buildLibrary(on: mine, device: "phone")
        _ = try await engine(mine, sidecar.link(user: "alex")).sync()

        let report = try await engine(theirs, sidecar.link(user: "someone-else")).sync()
        #expect(report.pulled == 0)
        #expect(try theirs.playlists().isEmpty)
        #expect(try theirs.pullCursor() == nil)
    }

    /// Push before pull, always. A device's own ops come back with a sequence number,
    /// which is how it learns they are durably on disk — and pulling first would merge
    /// a server state that does not yet contain the local changes, so any row touched
    /// on both sides would resolve against a version of itself that is missing.
    @Test("a sync pushes before it pulls")
    func pushComesFirst() async throws {
        let sidecar = Sidecar()
        let phone = try CurationStore.inMemory(deviceId: "phone")
        try phone.createPlaylist(name: "Focus", now: 1_000)
        _ = try await engine(phone, sidecar.link()).sync()
        #expect(await sidecar.calls == ["push", "pull"])
    }

    /// The envelope's `deviceId` has to agree with `origin_device` inside the payloads,
    /// and `entityId` with the id inside the payload. Neither is checkable on the
    /// server — it never parses a payload — so an op that disagrees with itself syncs
    /// perfectly and confuses every reader from then on. Asserted against the traffic
    /// that actually went out.
    @Test("every op that leaves agrees with its own payload")
    func opsAgreeWithTheirPayloads() async throws {
        let sidecar = Sidecar()
        let phone = try CurationStore.inMemory(deviceId: "phone")
        try buildLibrary(on: phone, device: "phone")
        _ = try await engine(phone, sidecar.link()).sync()

        let sent = await sidecar.ops(for: "alex")
        #expect(Set(sent.map(\.op.entity)).count == 6)
        for row in sent {
            let fields = try #require(row.op.payload.objectValue, "\(row.op.entity) payload")
            // Queue state is keyed by the device rather than by a UUID, so its identity
            // lives in `deviceId` and there is no `id` field at all.
            let identity = row.op.entity == "queue_state" ? "deviceId" : "id"
            #expect(fields[identity]?.stringValue == row.op.entityId, "\(row.op.entity) identity")
            #expect(fields["originDevice"]?.stringValue == row.deviceId, "\(row.op.entity) origin")
            if row.op.operation == "delete" {
                #expect(fields["deleted"]?.isFlagSet == true, "\(row.op.entity) delete flag")
            }
        }
    }

    /// Both sides offline, both busy. Nothing either of them did may be lost, and one
    /// round each is not enough — the second is where each reads the other's work.
    @Test("work done on both devices while offline all arrives")
    func offlineWorkFromBothSidesArrives() async throws {
        let sidecar = Sidecar()
        let phone = try CurationStore.inMemory(deviceId: "phone")
        let mac = try CurationStore.inMemory(deviceId: "mac")
        let phoneSync = engine(phone, sidecar.link())
        let macSync = engine(mac, sidecar.link())

        for index in 0..<3 {
            try phone.createPlaylist(name: "Phone \(index)", now: Millis(1_000 + index))
            try mac.createPlaylist(name: "Mac \(index)", now: Millis(1_000 + index))
            try phone.append(PlayEvent(
                id: "phone-e\(index)", jellyfinId: "t\(index)", contentKey: "k\(index)",
                startedAt: Millis(2_000 + index), msPlayed: 250_000, completed: true, originDevice: "phone"
            ))
            try mac.append(PlayEvent(
                id: "mac-e\(index)", jellyfinId: "t\(index)", contentKey: "k\(index)",
                startedAt: Millis(3_000 + index), msPlayed: 250_000, completed: true, originDevice: "mac"
            ))
        }

        for _ in 0..<2 {
            _ = try await phoneSync.sync()
            _ = try await macSync.sync()
        }

        #expect(try phone.playlists().count == 6)
        #expect(try mac.playlists().count == 6)
        #expect(try phone.read { try PlayEvent.fetchCount($0) } == 6)
        #expect(try syncedRows(of: phone) == syncedRows(of: mac))
    }

    /// A reinstall keeps the device id and loses the database. Skipping inbound ops
    /// whose `deviceId` matches ours would refuse to restore a single row of it — which
    /// is why our own ops go through the same merge as everybody else's.
    @Test("a reinstalled device rebuilds itself from its own ops")
    func reinstalledDeviceRestoresItself() async throws {
        let sidecar = Sidecar()
        let phone = try CurationStore.inMemory(deviceId: "phone")
        try buildLibrary(on: phone, device: "phone")
        _ = try await engine(phone, sidecar.link()).sync()

        let reinstalled = try CurationStore.inMemory(deviceId: "phone")
        let report = try await engine(reinstalled, sidecar.link()).sync()

        #expect(report.applied > 0)
        #expect(try syncedRows(of: reinstalled) == syncedRows(of: phone))
        #expect(try reinstalled.localQueue()?.trackIdList == ["t0", "t1", "t2"])
        // Restoring is not editing: it owes the server nothing.
        #expect(try reinstalled.totalOpCount() == 0)
    }

    // MARK: - 2. Idempotency

    /// A push that timed out is sent again, in full. The server holds every op already
    /// and says so — `accepted` includes what it had — and the log does not grow.
    @Test("pushing the same ops twice adds nothing to the server")
    func pushingTwiceIsANoOp() async throws {
        let sidecar = Sidecar()
        let phone = try CurationStore.inMemory(deviceId: "phone")
        try buildLibrary(on: phone, device: "phone")
        let sync = engine(phone, sidecar.link())

        let first = try await sync.sync()
        let stored = await sidecar.opCount(for: "alex")
        #expect(stored == first.pushed)

        try phone.forgetAcknowledgements()
        let second = try await sync.sync()

        #expect(second.pushed == first.pushed)
        #expect(second.rejected == 0)
        #expect(await sidecar.opCount(for: "alex") == stored)
        #expect(try phone.pendingOps().isEmpty)
        // And re-reading its own ops changed nothing about the rows.
        #expect(try phone.playlists().map(\.name) == ["Late Night", "Deep Focus"])
    }

    /// A batch replayed from a cursor that was rolled back — the shape an interrupted
    /// sync leaves behind — must be a no-op the second time through.
    @Test("pulling the same batch twice changes nothing")
    func pullingTwiceIsANoOp() async throws {
        let sidecar = Sidecar()
        let phone = try CurationStore.inMemory(deviceId: "phone")
        let mac = try CurationStore.inMemory(deviceId: "mac")
        try buildLibrary(on: phone, device: "phone")
        _ = try await engine(phone, sidecar.link()).sync()

        let macSync = engine(mac, sidecar.link())
        let first = try await macSync.sync()
        let after = try syncedRows(of: mac)
        #expect(first.applied > 0)

        // Rewind as though the cursor write had been lost, and read the whole log again.
        try mac.setSyncCursor("0")
        let second = try await macSync.sync()

        #expect(second.pulled == first.pulled)
        #expect(second.applied == 0)
        #expect(second.ignoredStale + second.ignoredDuplicate == second.pulled)
        #expect(try syncedRows(of: mac) == after)
        #expect(try mac.totalOpCount() == 0)
    }

    @Test("the same batch applied twice by hand is a no-op the second time")
    func applyingTwiceIsANoOp() async throws {
        let sidecar = Sidecar()
        let phone = try CurationStore.inMemory(deviceId: "phone")
        let mac = try CurationStore.inMemory(deviceId: "mac")
        try buildLibrary(on: phone, device: "phone")
        let link = sidecar.link()
        try await pushOnly(phone, to: link)

        let batch = try await link.pull(since: nil, limit: 1_000)
        let first = try mac.apply(batch.ops, advancingTo: batch.cursor, policy: .default, now: 2_000)
        let second = try mac.apply(batch.ops, advancingTo: batch.cursor, policy: .default, now: 2_000)

        #expect(first.applied == batch.ops.count)
        #expect(second.applied == 0)
        #expect(try syncedRows(of: mac) == syncedRows(of: phone))
        #expect(try mac.pullCursor() == batch.cursor)
    }

    // MARK: - 3. Interruption

    /// The cursor is stored with the batch it describes, so a pull that dies half way
    /// replays the rest rather than skipping it. Skipping would be silent and
    /// permanent: the server never offers an op below the cursor again.
    @Test("a pull that dies midway leaves the cursor on the last batch it applied")
    func interruptedPullReplays() async throws {
        let sidecar = Sidecar()
        let mac = try CurationStore.inMemory(deviceId: "mac")
        let phone = try CurationStore.inMemory(deviceId: "phone")
        let link = sidecar.link()

        for index in 0..<12 {
            try mac.createPlaylist(name: "List \(index)", now: Millis(1_000 + index))
        }
        try await pushOnly(mac, to: link)

        await sidecar.failPull(atCall: 2)
        let sync = engine(phone, link, policy: SyncPolicy(pullLimit: 5))

        await #expect(throws: SidecarError.unreachable) { try await sync.sync() }
        #expect(try phone.pullCursor() == PullCursor(5))
        #expect(try phone.playlists().count == 5)

        let resumed = try await sync.sync()
        #expect(resumed.applied == 7)
        #expect(try phone.playlists().count == 12)
        #expect(try phone.pullCursor() == PullCursor(12))
        #expect(try syncedRows(of: phone) == syncedRows(of: mac))
    }

    /// The failure is not the interesting part; what happens on the next attempt is.
    /// Two interruptions in one sync, and nothing is applied twice or missed once.
    @Test("repeated interruptions still converge, losing and duplicating nothing")
    func repeatedInterruptionsConverge() async throws {
        let sidecar = Sidecar()
        let mac = try CurationStore.inMemory(deviceId: "mac")
        let phone = try CurationStore.inMemory(deviceId: "phone")
        let link = sidecar.link()

        for index in 0..<20 {
            try mac.createPlaylist(name: "List \(index)", now: Millis(1_000 + index))
        }
        try await pushOnly(mac, to: link)

        await sidecar.failPull(atCall: 2)
        await sidecar.failPull(atCall: 4)
        let sync = engine(phone, link, policy: SyncPolicy(pullLimit: 4))

        // Two attempts die; the third gets through the rest.
        for _ in 0..<3 { _ = try? await sync.sync() }

        // Exactly twenty rows, once each, however many attempts it took. Counting the
        // reports would not say this: a sync that throws returns none, and the batches
        // it applied before dying are real.
        #expect(try phone.playlists().count == 20)
        #expect(Set(try phone.playlists().map(\.name)).count == 20)
        #expect(try syncedRows(of: phone) == syncedRows(of: mac))
        #expect(try phone.totalOpCount() == 0)

        // The interruptions really happened — five pages would otherwise have taken
        // five calls, not seven.
        #expect(await sidecar.pullCount == 7)
        // And there is nothing left to read.
        #expect(try await sync.sync().pulled == 0)
    }

    /// A push that never lands leaves its ops pending, and the retry is the same
    /// bytes to the same effect — no duplicate rows on the server.
    @Test("a push that dies is simply sent again")
    func interruptedPushRetries() async throws {
        let sidecar = Sidecar()
        let phone = try CurationStore.inMemory(deviceId: "phone")
        try buildLibrary(on: phone, device: "phone")
        let queued = try phone.pendingOps(limit: 5_000).count

        await sidecar.failPush(atCall: 1)
        let sync = engine(phone, sidecar.link())

        await #expect(throws: SidecarError.unreachable) { try await sync.sync() }
        #expect(try phone.pendingOps(limit: 5_000).count == queued)
        #expect(await sidecar.opCount(for: "alex") == 0)

        let report = try await sync.sync()
        #expect(report.pushed == queued)
        #expect(await sidecar.opCount(for: "alex") == queued)
    }

    // MARK: - 4. Ping-pong

    /// The failure that makes two devices trade one row until somebody switches a phone
    /// off. If applying an inbound op queues an outbound one, the op table grows on
    /// every sync and never stops — so the assertion is on the count, not on symptoms.
    @Test("applying another device's ops queues nothing to push back")
    func applyingQueuesNothing() async throws {
        let sidecar = Sidecar()
        let phone = try CurationStore.inMemory(deviceId: "phone")
        let mac = try CurationStore.inMemory(deviceId: "mac")
        try buildLibrary(on: phone, device: "phone")

        _ = try await engine(phone, sidecar.link()).sync()
        let phoneOps = try phone.totalOpCount()
        let macSync = engine(mac, sidecar.link())
        _ = try await macSync.sync()

        // The mac wrote nothing of its own, so it owes the server nothing — despite
        // having just merged a whole library.
        #expect(try mac.totalOpCount() == 0)
        #expect(try mac.pendingOps().isEmpty)

        let logged = await sidecar.opCount(for: "alex")
        for _ in 0..<3 { _ = try await macSync.sync() }

        #expect(try mac.totalOpCount() == 0)
        #expect(await sidecar.opCount(for: "alex") == logged)
        #expect(await sidecar.pushesByDevice["mac"] == nil)
        // And the phone's queue did not grow from reading its own ops back either.
        _ = try await engine(phone, sidecar.link()).sync()
        #expect(try phone.totalOpCount() == phoneOps)
    }

    /// The same property stated as a budget: after any number of syncs, each device's
    /// op table holds exactly the mutations that device made and not one more.
    @Test("the op count is a function of local edits, not of how often you sync")
    func opCountTracksLocalEditsOnly() async throws {
        let sidecar = Sidecar()
        let phone = try CurationStore.inMemory(deviceId: "phone")
        let mac = try CurationStore.inMemory(deviceId: "mac")
        let phoneSync = engine(phone, sidecar.link())
        let macSync = engine(mac, sidecar.link())

        try buildLibrary(on: phone, device: "phone")
        let phoneEdits = try phone.totalOpCount()

        for _ in 0..<3 {
            _ = try await phoneSync.sync()
            _ = try await macSync.sync()
        }
        #expect(try phone.totalOpCount() == phoneEdits)
        #expect(try mac.totalOpCount() == 0)

        // One edit on the mac is one op on the mac, and none anywhere else.
        try mac.createPlaylist(name: "Mac's own", now: 7_000)
        for _ in 0..<3 {
            _ = try await macSync.sync()
            _ = try await phoneSync.sync()
        }
        #expect(try mac.totalOpCount() == 1)
        #expect(try phone.totalOpCount() == phoneEdits)
        #expect(await sidecar.opCount(for: "alex") == phoneEdits + 1)
    }

    // MARK: - 5. Conflict

    /// Per-row last writer wins on `updatedAt`. Which one wins matters less than both
    /// devices picking the same one — a merge that is right on one device and wrong on
    /// the other is worse than either answer.
    @Test("two devices editing one playlist offline pick the same winner")
    func concurrentEditsPickOneWinner() async throws {
        let sidecar = Sidecar()
        let phone = try CurationStore.inMemory(deviceId: "phone")
        let mac = try CurationStore.inMemory(deviceId: "mac")
        let phoneSync = engine(phone, sidecar.link())
        let macSync = engine(mac, sidecar.link())

        let list = try phone.createPlaylist(name: "Shared", now: 1_000)
        _ = try await phoneSync.sync()
        _ = try await macSync.sync()

        // Both offline, both editing.
        try phone.rename(playlist: list.id, to: "From the phone", now: 5_000)
        try mac.rename(playlist: list.id, to: "From the mac", now: 6_000)

        _ = try await phoneSync.sync()
        _ = try await macSync.sync()
        _ = try await phoneSync.sync()

        #expect(try phone.playlist(list.id)?.name == "From the mac")
        #expect(try mac.playlist(list.id)?.name == "From the mac")
        #expect(try phone.playlist(list.id)?.updatedAt == 6_000)
        #expect(try phone.playlist(list.id)?.originDevice == "mac")
        #expect(try syncedRows(of: phone) == syncedRows(of: mac))
    }

    /// Same millisecond, so the timestamp settles nothing and `originDevice` has to.
    /// It is a string comparison and the larger id wins; the value of that rule is that
    /// it is a function of the two rows, so every device reaches it alone.
    @Test("a tie is broken by the device id, the same way on both devices")
    func tiesAreBrokenIdentically() async throws {
        let sidecar = Sidecar()
        let phone = try CurationStore.inMemory(deviceId: "phone")
        let mac = try CurationStore.inMemory(deviceId: "mac")
        let phoneSync = engine(phone, sidecar.link())
        let macSync = engine(mac, sidecar.link())

        let list = try phone.createPlaylist(name: "Shared", now: 1_000)
        _ = try await phoneSync.sync()
        _ = try await macSync.sync()

        try phone.rename(playlist: list.id, to: "From the phone", now: 5_000)
        try mac.rename(playlist: list.id, to: "From the mac", now: 5_000)

        _ = try await macSync.sync()
        _ = try await phoneSync.sync()
        _ = try await macSync.sync()

        // "phone" > "mac", and it would still be "phone" had the mac synced second.
        #expect(try phone.playlist(list.id)?.name == "From the phone")
        #expect(try mac.playlist(list.id)?.name == "From the phone")
        #expect(try syncedRows(of: phone) == syncedRows(of: mac))
    }

    /// Fractional indices mean two inserts at the same spot are not a conflict at all:
    /// each writes one row, and both survive.
    @Test("concurrent inserts into one playlist all survive")
    func concurrentInsertsSurvive() async throws {
        let sidecar = Sidecar()
        let phone = try CurationStore.inMemory(deviceId: "phone")
        let mac = try CurationStore.inMemory(deviceId: "mac")
        let phoneSync = engine(phone, sidecar.link())
        let macSync = engine(mac, sidecar.link())

        let list = try phone.createPlaylist(name: "Shared", now: 1_000)
        try phone.addTracks([TrackLink(jellyfinId: "t0", contentKey: "k0")], to: list.id, now: 1_100)
        _ = try await phoneSync.sync()
        _ = try await macSync.sync()

        try phone.addTracks([TrackLink(jellyfinId: "p1", contentKey: "kp1")], to: list.id, now: 5_000)
        try mac.addTracks([TrackLink(jellyfinId: "m1", contentKey: "km1")], to: list.id, now: 5_000)

        _ = try await phoneSync.sync()
        _ = try await macSync.sync()
        _ = try await phoneSync.sync()

        // Their relative order is arbitrary — appending to the same list on two devices
        // mints the same position key — but losing one would be the failure.
        #expect(Set(try phone.items(in: list.id).map(\.jellyfinId)) == ["t0", "p1", "m1"])
        #expect(try syncedRows(of: phone) == syncedRows(of: mac))
    }

    // MARK: - 6. Cursor confusion

    /// The trap, built rather than described. A push answers with the head of the whole
    /// log; ops this device has never read sit below it, and past that head they are
    /// never offered again.
    @Test("storing the push cursor as the pull cursor would lose another device's ops")
    func pushCursorIsNotAReadPosition() async throws {
        let sidecar = Sidecar()
        let mac = try CurationStore.inMemory(deviceId: "mac")
        let phone = try CurationStore.inMemory(deviceId: "phone")
        let link = sidecar.link()

        // Ten ops the phone has never seen.
        for index in 0..<10 {
            try mac.createPlaylist(name: "Mac \(index)", now: Millis(1_000 + index))
        }
        try await pushOnly(mac, to: link)

        // The phone pushes one of its own, which lands above all of them.
        try phone.createPlaylist(name: "Mine", now: 2_000)
        let pending = try phone.pendingOps()
        let wire = pending.compactMap { try? WireOp.make(from: $0).get() }
        let response = try await link.push(PushRequest(deviceId: "phone", ops: wire))

        #expect(response.cursor == PushCursor(11))

        // Had that been stored as the read position, this is what the next pull would
        // have returned: nothing, forever, with ten ops stranded below it.
        let head = try #require(response.cursor)
        let fromTheHead = try await link.pull(since: PullCursor(head.value), limit: 500)
        #expect(fromTheHead.ops.isEmpty)
        #expect(!fromTheHead.hasMore)

        // What the engine does instead.
        let report = try await engine(phone, link).sync()
        #expect(report.applied == 10)
        #expect(try phone.playlists().count == 11)
        #expect(try phone.pullCursor() == PullCursor(11))
    }

    /// The same trap one step further along: the head can be above this user's log
    /// entirely, because the sequence is global and somebody else has been writing.
    @Test("the push head can sit above every op this user has")
    func pushHeadIsGlobal() async throws {
        let sidecar = Sidecar()
        let mine = try CurationStore.inMemory(deviceId: "phone")
        let theirs = try CurationStore.inMemory(deviceId: "their-phone")

        for index in 0..<5 {
            try theirs.createPlaylist(name: "Theirs \(index)", now: Millis(1_000 + index))
        }
        try await pushOnly(theirs, to: sidecar.link(user: "someone-else"))

        try mine.createPlaylist(name: "Mine", now: 2_000)
        let link = sidecar.link(user: "alex")
        let wire = try mine.pendingOps().compactMap { try? WireOp.make(from: $0).get() }
        let response = try await link.push(PushRequest(deviceId: "phone", ops: wire))

        // Six, not one — the sequence counts every commit on the server.
        #expect(response.cursor == PushCursor(6))
        // And this user's own op is at seq 6, which a pull from 6 would skip.
        let all = try await link.pull(since: nil, limit: 500)
        #expect(all.ops.map(\.seq) == [6])
        #expect(try await link.pull(since: PullCursor(6), limit: 500).ops.isEmpty)
    }

    // MARK: - 7. Rejection

    /// A rejected op will never be accepted, so retrying it is an infinite loop with a
    /// queue backed up behind it. It leaves the queue and is surfaced instead.
    @Test("a rejected op is quarantined while its batch-mates land")
    func rejectionLeavesTheQueue() async throws {
        let sidecar = Sidecar()
        let phone = try CurationStore.inMemory(deviceId: "phone")
        try phone.createPlaylist(name: "First", now: 1_000)
        try phone.createPlaylist(name: "Doomed", now: 1_100)
        try phone.createPlaylist(name: "Third", now: 1_200)

        let doomed = try #require(try phone.pendingOps().first { $0.createdAt == 1_100 })
        await sidecar.reject(doomed.opId, because: "payload failed validation")
        let sync = engine(phone, sidecar.link())

        let report = try await sync.sync()
        #expect(report.pushed == 2)
        #expect(report.rejected == 1)
        #expect(report.quarantinedOutbound == 1)
        #expect(try phone.pendingOps().isEmpty)
        #expect(await sidecar.opCount(for: "alex") == 2)

        let held = try #require(try phone.quarantinedOps().first)
        #expect(held.opId == doomed.opId)
        #expect(held.syncDirection == .outbound)
        #expect(held.reason.contains("payload failed validation"))
        // The evidence survives: the payload is what makes the failure diagnosable.
        #expect(held.payload.contains("Doomed"))

        // And it is never sent again, however often the device syncs.
        let pushes = await sidecar.pushesByDevice["phone"]
        for _ in 0..<3 { _ = try await sync.sync() }
        #expect(await sidecar.pushesByDevice["phone"] == pushes)
        #expect(await sidecar.opCount(for: "alex") == 2)
        #expect(try phone.quarantineCount() == 1)
    }

    /// A whole batch refused, twice over. The queue has to keep draining: rejections
    /// leave it, so the next fetch returns different rows and the loop terminates
    /// instead of resending the same bytes forever.
    @Test("a push where every op is rejected still drains the queue")
    func everythingRejected() async throws {
        let sidecar = Sidecar()
        let phone = try CurationStore.inMemory(deviceId: "phone")
        for index in 0..<5 { try phone.createPlaylist(name: "List \(index)", now: Millis(1_000 + index)) }
        for op in try phone.pendingOps() {
            await sidecar.reject(op.opId, because: "no")
        }

        let report = try await engine(phone, sidecar.link(), policy: SyncPolicy(pushBatchSize: 2)).sync()
        #expect(report.rejected == 5)
        #expect(report.pushed == 0)
        #expect(try phone.pendingOps().isEmpty)
        #expect(try phone.quarantineCount() == 5)
        #expect(await sidecar.opCount(for: "alex") == 0)
    }

    /// Rejections spread across several batches, with survivors in each. Every good op
    /// lands and every bad one stops, whichever batch it happened to fall in.
    @Test("rejections in the middle of a multi-batch push do not take the batch with them")
    func rejectionsAcrossBatches() async throws {
        let sidecar = Sidecar()
        let phone = try CurationStore.inMemory(deviceId: "phone")
        for index in 0..<9 { try phone.createPlaylist(name: "List \(index)", now: Millis(1_000 + index)) }

        let doomed = try phone.pendingOps().enumerated().filter { $0.offset % 3 == 1 }.map(\.element)
        for op in doomed { await sidecar.reject(op.opId, because: "no") }

        let report = try await engine(phone, sidecar.link(), policy: SyncPolicy(pushBatchSize: 3)).sync()
        #expect(report.pushed == 6)
        #expect(report.rejected == 3)
        #expect(await sidecar.opCount(for: "alex") == 6)
        #expect(try phone.pendingOps().isEmpty)
        #expect(try Set(phone.quarantinedOps().map(\.opId)) == Set(doomed.map(\.opId)))
    }

    /// An op certain to bounce costs a round trip to learn nothing, and while it is at
    /// the head of the queue being retried everything behind it waits. This one never
    /// leaves the device — and the batch-mate beside it still does.
    @Test("an op the server would refuse is stopped before it is sent")
    func invalidOpNeverLeaves() async throws {
        let sidecar = Sidecar()
        let phone = try CurationStore.inMemory(deviceId: "phone")

        // The track cache is per-device and the server refuses the entity outright.
        try phone.writeLocal { db in
            try Op(
                opId: "cache-1", entity: "track", entityId: "t1", operation: .upsert,
                payload: #"{"id":"t1"}"#, createdAt: 1_000
            ).insert(db)
        }
        try phone.createPlaylist(name: "Fine", now: 1_100)

        let report = try await engine(phone, sidecar.link()).sync()
        #expect(report.quarantinedOutbound == 1)
        #expect(report.rejected == 0)
        #expect(report.pushed == 1)
        #expect(await sidecar.opCount(for: "alex") == 1)
        #expect(await sidecar.entities(for: "alex") == ["playlists"])
        #expect(try phone.quarantinedOps().first?.reason.contains("'track'") == true)
    }

    /// The payload ceiling is the one local rule measured in bytes, and the two ends
    /// have to agree on the count or the first real sync is a pile of rejections.
    @Test("an oversized payload is caught locally and the batch around it still lands")
    func oversizedPayloadStopsHere() async throws {
        let sidecar = Sidecar()
        let phone = try CurationStore.inMemory(deviceId: "phone")
        let list = try phone.createPlaylist(name: "Fine", now: 1_000)
        try phone.setNotes(String(repeating: "x", count: 300 * 1024), on: list.id, now: 1_100)

        let report = try await engine(phone, sidecar.link()).sync()
        #expect(report.pushed == 1)
        #expect(report.quarantinedOutbound == 1)
        #expect(try phone.quarantinedOps().first?.reason.contains("bytes") == true)
        #expect(await sidecar.opCount(for: "alex") == 1)
    }

    /// The client's local validation exists to save a round trip, which is only worth
    /// anything if it refuses the same things the server does. Every rule, both ends.
    @Test("every rule the server enforces is a rule the client checks first")
    func rejectionRulesAgree() async throws {
        func wire(
            opId: String = UUID().uuidString,
            entity: String = "playlists",
            entityId: String = "list-1",
            operation: String = "upsert",
            payload: JSONValue = .object(["id": .string("list-1")]),
            createdAt: Millis = 1_000
        ) -> WireOp {
            WireOp(
                opId: opId, entity: entity, entityId: entityId, operation: operation,
                payload: payload, createdAt: createdAt
            )
        }

        let refused: [(String, WireOp)] = [
            ("an empty op id", wire(opId: "")),
            ("an op id over 128 characters", wire(opId: String(repeating: "a", count: 129))),
            ("an empty entity id", wire(entityId: "")),
            ("an entity id over 256 characters", wire(entityId: String(repeating: "b", count: 257))),
            ("the track cache", wire(entity: "tracks")),
            ("an entity that does not exist", wire(entity: "downloads")),
            ("an uppercase operation", wire(operation: "UPSERT")),
            ("a capitalised operation", wire(operation: "Delete")),
            ("a payload that is an array", wire(payload: .array([.int(1)]))),
            ("a payload that is a string", wire(payload: .string("nope"))),
            ("a payload that is null", wire(payload: .null)),
            ("a zero timestamp", wire(createdAt: 0)),
            ("a negative timestamp", wire(createdAt: -1)),
            ("a payload over 256 KB", wire(payload: .object([
                "id": .string("list-1"),
                "notes": .string(String(repeating: "x", count: 300 * 1024))
            ])))
        ]

        for (description, op) in refused {
            #expect(Sidecar.refusal(op) != nil, "the server should refuse \(description)")
        }

        let sidecar = Sidecar()
        let link = sidecar.link()
        let good = wire(opId: "good-1")
        let response = try await link.push(
            PushRequest(deviceId: "phone", ops: refused.map(\.1) + [good])
        )

        // Valid ops in the same batch still land — a rejection is per op, not per push.
        #expect(response.accepted == ["good-1"])
        #expect(response.rejected.count == refused.count)
        #expect(await sidecar.opCount(for: "alex") == 1)
    }

    /// Over a thousand ops is a 400 for the *whole* request, so the ceiling is never a
    /// number to send. The policy clamps rather than trusting its caller.
    @Test("a batch over the server's ceiling is refused outright")
    func oversizedBatchIsA400() async throws {
        let sidecar = Sidecar()
        let ops = (0..<1_001).map { index in
            WireOp(
                opId: "op-\(index)", entity: "playlists", entityId: "list-\(index)",
                operation: "upsert", payload: .object(["id": .string("list-\(index)")]),
                createdAt: 1_000
            )
        }
        await #expect(throws: SidecarError.batchTooLarge(1_001)) {
            try await sidecar.link().push(PushRequest(deviceId: "phone", ops: ops))
        }
        #expect(await sidecar.opCount(for: "alex") == 0)
    }

    /// A server deployed ahead of this build relays an entity it has never heard of.
    /// It cannot be applied and it cannot be asked for again — the cursor moves past it
    /// either way — so it is kept whole, and the ops beside it still land.
    @Test("an entity from a newer server is quarantined without stopping the batch")
    func unknownInboundEntity() async throws {
        let sidecar = Sidecar()
        await sidecar.alsoAllow("downloads")
        let phone = try CurationStore.inMemory(deviceId: "phone")
        let link = sidecar.link()

        let ops = [
            WireOp(
                opId: "a", entity: "playlists", entityId: "list-1", operation: "upsert",
                payload: try Wire.payload(makePlaylist(id: "list-1", updatedAt: 1_000, device: "mac")),
                createdAt: 1_000
            ),
            WireOp(
                opId: "b", entity: "downloads", entityId: "d1", operation: "upsert",
                payload: .object(["id": .string("d1"), "sizeBytes": .int(42)]), createdAt: 1_100
            ),
            WireOp(
                opId: "c", entity: "playlists", entityId: "list-2", operation: "upsert",
                payload: try Wire.payload(makePlaylist(id: "list-2", name: "Other", updatedAt: 1_200, device: "mac")),
                createdAt: 1_200
            )
        ]
        _ = try await link.push(PushRequest(deviceId: "mac", ops: ops))

        let report = try await engine(phone, link).sync()
        #expect(report.applied == 2)
        #expect(report.quarantinedInbound == 1)
        #expect(try phone.playlists().count == 2)
        #expect(try phone.pullCursor() == PullCursor(3))

        let held = try #require(try phone.quarantinedOps().first)
        #expect(held.entity == "downloads")
        #expect(held.syncDirection == .inbound)
        // The only copy that will ever exist on this device, kept for a build that
        // learns to understand it.
        #expect(held.payload.contains("42"))

        // And it is not gone looking for again.
        #expect(try await engine(phone, link).sync().pulled == 0)
        #expect(try phone.quarantineCount() == 1)
    }

    /// An item can arrive before the playlist it belongs to — ops go up in `createdAt`
    /// order, not in dependency order. Refusing it would turn a wait into permanent loss,
    /// because the cursor moves past it either way.
    @Test("an item that arrives before its playlist is kept, not dropped")
    func orphanAcrossABatchBoundary() async throws {
        let sidecar = Sidecar()
        let mac = try CurationStore.inMemory(deviceId: "mac")
        let phone = try CurationStore.inMemory(deviceId: "phone")
        let link = sidecar.link()

        // Items stamped before their playlist, so they sort ahead of it in the outbound
        // queue and land below it on the server.
        let list = try mac.createPlaylist(name: "Host", now: 9_000)
        try mac.addTracks(
            (0..<3).map { TrackLink(jellyfinId: "t\($0)", contentKey: "k\($0)") },
            to: list.id, now: 1_000
        )
        try await pushOnly(mac, to: link)
        #expect(await sidecar.entities(for: "alex").last == "playlists")

        let report = try await engine(phone, link, policy: SyncPolicy(pullLimit: 2)).sync()
        #expect(report.orphanedItems == 3)
        #expect(report.applied == 4)
        // Invisible until the parent lands, rather than wrong — and then whole.
        #expect(try phone.items(in: list.id).map(\.jellyfinId) == ["t0", "t1", "t2"])
        #expect(try syncedRows(of: phone) == syncedRows(of: mac))
    }

    /// Three versions of one row in a single batch, out of timestamp order. The merge
    /// is a comparison rather than an assignment, so the newest wins whatever position
    /// it arrives in — "the last op in the batch" would be a different, wrong answer.
    @Test("the newest version in a batch wins, not the last one")
    func withinBatchOrderingIsByTimestamp() async throws {
        let sidecar = Sidecar()
        let phone = try CurationStore.inMemory(deviceId: "phone")
        let link = sidecar.link()

        let versions: [(String, Millis)] = [("First", 1_000), ("Newest", 3_000), ("Middle", 2_000)]
        let ops = versions.enumerated().map { index, version in
            WireOp(
                opId: "op-\(index)", entity: "playlists", entityId: "list-1", operation: "upsert",
                payload: (try? Wire.payload(
                    makePlaylist(id: "list-1", name: version.0, updatedAt: version.1, device: "mac")
                )) ?? .null,
                createdAt: version.1
            )
        }
        _ = try await link.push(PushRequest(deviceId: "mac", ops: ops))

        let report = try await engine(phone, link).sync()
        #expect(report.applied == 2)
        #expect(report.ignoredStale == 1)
        #expect(try phone.playlist("list-1")?.name == "Newest")
    }

    /// The repair the whole identity design exists for: a rescan minted new Jellyfin
    /// ids, one device noticed, and the fix has to reach the other without it fighting
    /// back.
    @Test("a relink after a rescan travels, and the other device does not undo it")
    func relinkTravels() async throws {
        let sidecar = Sidecar()
        let phone = try CurationStore.inMemory(deviceId: "phone")
        let mac = try CurationStore.inMemory(deviceId: "mac")
        let phoneSync = engine(phone, sidecar.link())
        let macSync = engine(mac, sidecar.link())

        let key = ContentKey.make(artist: "Talk Talk", album: "Laughing Stock", title: "Ascension Day", durationMs: 366_000)
        let list = try phone.createPlaylist(name: "Fragile", now: 1_000)
        try phone.addTracks([TrackLink(jellyfinId: "old-1", contentKey: key)], to: list.id, now: 1_100)
        _ = try await phoneSync.sync()
        _ = try await macSync.sync()
        #expect(try mac.items(in: list.id).map(\.jellyfinId) == ["old-1"])

        try phone.relinkItems(live: { _ in false }, resolving: { _ in "new-1" }, now: 5_000)
        _ = try await phoneSync.sync()
        _ = try await macSync.sync()

        #expect(try mac.items(in: list.id).map(\.jellyfinId) == ["new-1"])
        #expect(try mac.totalOpCount() == 0)
        #expect(try syncedRows(of: phone) == syncedRows(of: mac))
    }

    /// A drag writes exactly one row, which is the whole return on fractional indices —
    /// and the receiving device has to end up with the same order from that one row
    /// rather than from a renumbering it never saw.
    @Test("a reorder travels as one row and reproduces the order")
    func reorderTravelsAsOneRow() async throws {
        let sidecar = Sidecar()
        let phone = try CurationStore.inMemory(deviceId: "phone")
        let mac = try CurationStore.inMemory(deviceId: "mac")
        let phoneSync = engine(phone, sidecar.link())
        let macSync = engine(mac, sidecar.link())

        let list = try phone.createPlaylist(name: "Set list", now: 1_000)
        try phone.addTracks(
            (0..<5).map { TrackLink(jellyfinId: "t\($0)", contentKey: "k\($0)") },
            to: list.id, now: 1_100
        )
        _ = try await phoneSync.sync()
        _ = try await macSync.sync()

        let last = try #require(try phone.items(in: list.id).last)
        let opsBefore = try phone.totalOpCount()
        try phone.moveItem(last.id, in: list.id, to: 0, now: 5_000)
        #expect(try phone.totalOpCount() == opsBefore + 1)

        _ = try await phoneSync.sync()
        _ = try await macSync.sync()

        #expect(try mac.items(in: list.id).map(\.jellyfinId) == ["t4", "t0", "t1", "t2", "t3"])
        #expect(try mac.totalOpCount() == 0)
        #expect(try syncedRows(of: phone) == syncedRows(of: mac))
    }

    /// A smart playlist's rules are JSON inside a JSON string inside a JSON payload. The
    /// nesting is where escaping goes wrong, and the symptom would be a rule set that
    /// evaluates on one device and throws on the other.
    @Test("smart rules survive the wire and still evaluate on the other device")
    func smartRulesSurviveTheWire() async throws {
        let sidecar = Sidecar()
        let phone = try CurationStore.inMemory(deviceId: "phone")
        let mac = try CurationStore.inMemory(deviceId: "mac")

        let rules = try SmartRules(
            match: .all,
            rules: [
                // A value with a quote and a backslash in it, because that is what the
                // nesting has to survive.
                try SmartRule(field: .genre, op: .is, value: .text(#"Jazz "fusion" \ funk"#)),
                try SmartRule(field: .playCount, op: .greaterThan, value: .number(2))
            ],
            sort: SmartRules.Sort(field: .lastPlayed, dir: .desc),
            limit: 100
        )
        let list = try phone.createPlaylist(name: "Rules", now: 1_000)
        try phone.record(try list.settingSmartRules(rules), at: 1_100)

        _ = try await engine(phone, sidecar.link()).sync()
        _ = try await engine(mac, sidecar.link()).sync()

        let merged = try #require(try mac.playlist(list.id))
        #expect(merged.isSmart)
        #expect(try merged.smartRuleSet() == rules)
        // And it compiles and runs, rather than merely round-tripping as text.
        #expect(try mac.matchCount(playlist: merged, asOf: 2_000) == 0)
        #expect(try syncedRows(of: phone) == syncedRows(of: mac))
    }

    /// Names are user text and user text is hostile: quotes, backslashes, newlines,
    /// astral-plane emoji, right-to-left scripts. They go through two JSON encoders and
    /// a SQLite text column, and any of those losing a byte is silent.
    @Test("awkward text survives the round trip unchanged")
    func awkwardTextSurvives() async throws {
        let sidecar = Sidecar()
        let phone = try CurationStore.inMemory(deviceId: "phone")
        let mac = try CurationStore.inMemory(deviceId: "mac")

        let awkward = #"He said "hi" \ then left"# + "\n\ttabbed 🎧👨‍👩‍👧‍👦 مرحبا Ω ünïcode"
        let list = try phone.createPlaylist(name: awkward, notes: awkward, now: 1_000)

        _ = try await engine(phone, sidecar.link()).sync()
        _ = try await engine(mac, sidecar.link()).sync()

        #expect(try mac.playlist(list.id)?.name == awkward)
        #expect(try mac.playlist(list.id)?.notes == awkward)
        #expect(try syncedRows(of: phone) == syncedRows(of: mac))
    }

    // MARK: - 8. Gaps

    /// A rolled-back transaction burns a sequence. The cursor means "everything up to
    /// here", not "the next number", and a client that treats the hole as data loss —
    /// by refusing to advance, or by re-reading from below it — never finishes a sync.
    @Test("a burnt sequence number is not data loss")
    func gapsAreNormal() async throws {
        let sidecar = Sidecar()
        let mac = try CurationStore.inMemory(deviceId: "mac")
        let phone = try CurationStore.inMemory(deviceId: "phone")
        let link = sidecar.link()

        for index in 0..<3 { try mac.createPlaylist(name: "Before \(index)", now: Millis(1_000 + index)) }
        try await pushOnly(mac, to: link)
        await sidecar.burnSequences(40)
        for index in 0..<3 { try mac.createPlaylist(name: "After \(index)", now: Millis(2_000 + index)) }
        try await pushOnly(mac, to: link)

        let seqs = await sidecar.ops(for: "alex").map(\.seq)
        #expect(seqs == [1, 2, 3, 44, 45, 46])

        // Paged small on purpose, so the loop crosses the hole rather than stepping
        // over it in one batch.
        let report = try await engine(phone, link, policy: SyncPolicy(pullLimit: 2)).sync()
        #expect(report.applied == 6)
        #expect(try phone.pullCursor() == PullCursor(46))
        #expect(try phone.playlists().count == 6)
        #expect(try syncedRows(of: phone) == syncedRows(of: mac))
    }

    /// Resuming from a cursor that lands *inside* a hole is the same question asked
    /// from the other side, and it has to return everything above it rather than
    /// nothing.
    @Test("a cursor inside a gap still returns everything above it")
    func cursorInsideAGap() async throws {
        let sidecar = Sidecar()
        let mac = try CurationStore.inMemory(deviceId: "mac")
        let phone = try CurationStore.inMemory(deviceId: "phone")
        let link = sidecar.link()

        try mac.createPlaylist(name: "One", now: 1_000)
        try await pushOnly(mac, to: link)
        await sidecar.burnSequences(10)
        try mac.createPlaylist(name: "Two", now: 2_000)
        try await pushOnly(mac, to: link)

        try phone.setSyncCursor("6")
        let report = try await engine(phone, link).sync()
        #expect(report.applied == 1)
        #expect(try phone.playlists().map(\.name) == ["Two"])
        #expect(try phone.pullCursor() == PullCursor(12))
    }

    /// `hasMore` is exact — the server reads one row past the limit to answer it — so a
    /// page that exactly fills the limit does not cost an extra empty round trip.
    @Test("hasMore is exact, so a full last page ends the loop")
    func hasMoreIsExact() async throws {
        let sidecar = Sidecar()
        let mac = try CurationStore.inMemory(deviceId: "mac")
        let phone = try CurationStore.inMemory(deviceId: "phone")
        let link = sidecar.link()

        for index in 0..<8 { try mac.createPlaylist(name: "List \(index)", now: Millis(1_000 + index)) }
        try await pushOnly(mac, to: link)

        let report = try await engine(phone, link, policy: SyncPolicy(pullLimit: 4)).sync()
        #expect(report.pulled == 8)
        // Two pages, not three: the second one fills the limit and still says there is
        // nothing after it.
        #expect(await sidecar.pullCount == 2)
    }

    /// Clamped at both ends. The policy will not ask for more than the server takes,
    /// and the server would silently cap it anyway — so a client that trusted the limit
    /// it asked for to be the page size it got would mis-set `hasMore` against itself.
    @Test("a pull limit above the server's ceiling is clamped, not refused")
    func pullLimitIsClamped() async throws {
        let sidecar = Sidecar()
        let mac = try CurationStore.inMemory(deviceId: "mac")
        let phone = try CurationStore.inMemory(deviceId: "phone")
        let link = sidecar.link()

        _ = try await engine(phone, link, policy: SyncPolicy(pullLimit: 9_999)).sync()
        #expect(await sidecar.pullLimitsRequested == [SyncPolicy.maxPullLimit])

        for index in 0..<5 { try mac.createPlaylist(name: "List \(index)", now: Millis(1_000 + index)) }
        try await pushOnly(mac, to: link)
        let page = try await link.pull(since: nil, limit: 9_999)
        #expect(page.ops.count == 5)
        #expect(!page.hasMore)
    }

    // MARK: - 9. Batch splitting

    /// More ops than one request may carry. Every one of them has to land, in order,
    /// with nothing dropped at a batch boundary — and no request may exceed the
    /// ceiling, because over it the server refuses the valid ops too.
    @Test("more than a thousand ops go up in several batches and every one lands")
    func batchesSplitAtTheCeiling() async throws {
        let sidecar = Sidecar()
        let phone = try CurationStore.inMemory(deviceId: "phone")
        let mac = try CurationStore.inMemory(deviceId: "mac")

        for index in 0..<1_100 {
            try phone.append(PlayEvent(
                id: "e-\(index)", jellyfinId: "t\(index % 20)", contentKey: "k\(index % 20)",
                startedAt: Millis(1_000_000 + index), msPlayed: 200_000, completed: true,
                originDevice: "phone"
            ))
        }

        // Asked for five thousand; the policy clamps to what the server will take.
        let report = try await engine(phone, sidecar.link(), policy: SyncPolicy(pushBatchSize: 5_000)).sync()

        #expect(report.pushed == 1_100)
        #expect(report.rejected == 0)
        #expect(await sidecar.largestBatchPushed == SyncPolicy.maxBatch)
        #expect(await sidecar.pushesByDevice["phone"] == 2)
        #expect(await sidecar.opCount(for: "alex") == 1_100)
        #expect(try phone.pendingOps(limit: 5_000).isEmpty)

        let received = try await engine(mac, sidecar.link()).sync()
        #expect(received.applied == 1_100)
        #expect(try mac.read { try PlayEvent.fetchCount($0) } == 1_100)
        #expect(try syncedRows(of: mac) == syncedRows(of: phone))
    }

    /// Every op in the queue sharing one millisecond, which is what a burst of writes
    /// actually looks like. Nothing but the pagination keeps the batches apart then: a
    /// batch that repeated a row would trip the stall guard, and one that skipped a row
    /// would strand it pending forever.
    @Test("ops sharing a millisecond still push exactly once each")
    func tiedTimestampsAcrossBatches() async throws {
        let sidecar = Sidecar()
        let phone = try CurationStore.inMemory(deviceId: "phone")

        for index in 0..<600 {
            try phone.append(PlayEvent(
                id: "e-\(index)", jellyfinId: "t1", contentKey: "k1", startedAt: 7_000,
                msPlayed: 250_000, completed: true, originDevice: "phone"
            ))
        }

        let report = try await engine(phone, sidecar.link(), policy: SyncPolicy(pushBatchSize: 100)).sync()
        #expect(report.pushed == 600)
        #expect(await sidecar.pushesByDevice["phone"] == 6)
        #expect(await sidecar.opCount(for: "alex") == 600)
        #expect(try phone.pendingOps(limit: 5_000).isEmpty)
    }

    // MARK: - 10. Clock skew

    /// A device whose clock says 2096 would win every conflict it ever entered, and no
    /// amount of editing anywhere else could take a row back from it. `receivedAt` is
    /// the only clock every device shares, so it is the only thing available to check
    /// the claim against.
    @Test("a device with a wildly wrong clock does not capture rows on other devices")
    func brokenClockDoesNotWinEverywhere() async throws {
        let sidecar = Sidecar()
        await sidecar.setClock(1_699_000_000_000)
        let phone = try CurationStore.inMemory(deviceId: "phone")
        let mac = try CurationStore.inMemory(deviceId: "mac")
        let phoneSync = engine(phone, sidecar.link(), clock: { 1_700_000_050_000 })
        let macSync = engine(mac, sidecar.link(), clock: { 4_000_000_000_000 })

        let list = try phone.createPlaylist(name: "Shared", now: 1_699_000_000_000)
        _ = try await phoneSync.sync()
        _ = try await macSync.sync()

        // The mac's clock says the year is 2096. It edits first in real time.
        try mac.rename(playlist: list.id, to: "From the mac", now: 4_000_000_000_000)
        await sidecar.setClock(1_699_500_000_000)
        _ = try await macSync.sync()

        // The phone edits afterwards, honestly.
        try phone.rename(playlist: list.id, to: "From the phone", now: 1_700_000_000_000)
        await sidecar.setClock(1_700_000_050_000)
        let report = try await phoneSync.sync()

        // Judged on when the server saw it, the mac's write is the older one — which
        // is the truth. Uncorrected, its 2096 timestamp would have won.
        #expect(report.clockSkewed == 1)
        #expect(try phone.playlist(list.id)?.name == "From the phone")
    }

    /// The offending device cannot be fixed from the outside while its clock is still
    /// wrong — its own clock is one of the two references, so its own rows look
    /// ordinary to it. What it must not do is stay broken *after* the clock is put
    /// right, which is what happens if the poisoned timestamp is only ever compared and
    /// never disbelieved: no edit made on any other device could take the row back, and
    /// only an edit made on the offender itself would end the divergence. This pins the
    /// repair happening without anybody touching anything.
    @Test("a fixed clock rejoins the fold with no edit on the device that was wrong")
    func brokenClockRecovers() async throws {
        let honest: Millis = 1_700_000_000_000
        let broken: Millis = 4_000_000_000_000

        let sidecar = Sidecar()
        await sidecar.setClock(honest)
        let phone = try CurationStore.inMemory(deviceId: "phone")
        let mac = try CurationStore.inMemory(deviceId: "mac")
        let phoneSync = engine(phone, sidecar.link(), clock: { honest + 100_000 })
        let macSync = engine(mac, sidecar.link(), clock: { broken })

        let list = try phone.createPlaylist(name: "Shared", now: honest)
        _ = try await phoneSync.sync()
        _ = try await macSync.sync()

        try mac.rename(playlist: list.id, to: "From the mac", now: broken)
        await sidecar.setClock(honest + 50_000)
        _ = try await macSync.sync()

        try phone.rename(playlist: list.id, to: "From the phone", now: honest + 100_000)
        await sidecar.setClock(honest + 150_000)
        _ = try await phoneSync.sync()
        _ = try await macSync.sync()

        // The phone is protected: 2096 is ahead of both the server's receipt time and
        // the phone's own clock, so it is read as a broken clock rather than a newer
        // write.
        #expect(try phone.playlist(list.id)?.name == "From the phone")
        // The mac is not, and nothing here can protect it: its own clock agrees with
        // its own row.
        #expect(try mac.playlist(list.id)?.name == "From the mac")

        // The clock is fixed. Nobody edits anything on the mac — the next change from
        // anywhere else is enough, because the mac can no longer place its own row in
        // time and a row it cannot date loses to one the server witnessed.
        try phone.rename(playlist: list.id, to: "Corrected", now: honest + 200_000)
        await sidecar.setClock(honest + 210_000)
        _ = try await phoneSync.sync()
        let repaired = engine(mac, sidecar.link(), clock: { honest + 220_000 })
        _ = try await repaired.sync()

        #expect(try mac.playlist(list.id)?.name == "Corrected")
        #expect(try syncedRows(of: phone) == syncedRows(of: mac))
    }

    /// The failure the skew check used to *cause*, which was worse and far likelier
    /// than the one it prevents.
    ///
    /// Checking a write only against the server's receipt time asks whether the writer
    /// is ahead of the server, and cannot tell a fast client from a slow server. A
    /// Jellyfin box with no RTC, or a VM resumed from a snapshot, sits behind every
    /// device at once — so every inbound row was dragged back to a receipt time older
    /// than the local copy it was compared with, every device rejected every other
    /// device's edits, and they diverged permanently with nothing on screen to say so.
    @Test("a server clock behind its devices does not split them")
    func slowServerStillConverges() async throws {
        let base: Millis = 1_800_000_000_000
        // Twice the skew tolerance, so every single op looks "impossibly" ahead of the
        // server.
        let lag: Millis = 10 * 60 * 1_000

        let sidecar = Sidecar()
        await sidecar.setClock(base - lag)
        let phone = try CurationStore.inMemory(deviceId: "phone")
        let mac = try CurationStore.inMemory(deviceId: "mac")
        // Both devices are right about the time. Only the server is wrong.
        let phoneSync = engine(phone, sidecar.link(), clock: { base + 300_000 })
        let macSync = engine(mac, sidecar.link(), clock: { base + 300_000 })

        let list = try phone.createPlaylist(name: "Late Night", now: base)
        _ = try await phoneSync.sync()
        _ = try await macSync.sync()
        #expect(try mac.playlist(list.id)?.name == "Late Night")

        try mac.rename(playlist: list.id, to: "Night Drive", now: base + 60_000)
        await sidecar.setClock(base + 60_000 - lag)
        _ = try await macSync.sync()
        let toPhone = try await phoneSync.sync()
        #expect(try phone.playlist(list.id)?.name == "Night Drive")
        #expect(toPhone.clockSkewed == 0)

        try phone.rename(playlist: list.id, to: "Phone Says", now: base + 180_000)
        await sidecar.setClock(base + 180_000 - lag)
        _ = try await phoneSync.sync()
        let toMac = try await macSync.sync()

        #expect(try mac.playlist(list.id)?.name == "Phone Says")
        #expect(toMac.clockSkewed == 0)
        #expect(try syncedRows(of: phone) == syncedRows(of: mac))
    }

    /// An op written offline and pushed days later is *normal*, and its timestamp is
    /// legitimately far in the past. Correcting that would throw away the ordering the
    /// whole design depends on.
    @Test("a week-old op pushed today is not treated as a broken clock")
    func offlineWorkIsNotSkew() async throws {
        let sidecar = Sidecar()
        await sidecar.setClock(1_700_000_000_000)
        let mac = try CurationStore.inMemory(deviceId: "mac")
        let phone = try CurationStore.inMemory(deviceId: "phone")
        let link = sidecar.link()

        let weekAgo: Millis = 1_700_000_000_000 - 7 * 24 * 60 * 60 * 1_000
        try mac.createPlaylist(name: "Written on a plane", now: weekAgo)
        try await pushOnly(mac, to: link)

        let report = try await engine(phone, link).sync()
        #expect(report.clockSkewed == 0)
        #expect(try phone.playlists().first?.updatedAt == weekAgo)
        #expect(try syncedRows(of: phone) == syncedRows(of: mac))
    }

    // MARK: - 11. Soft deletes

    /// A hard delete cannot be synced — the absence of a row is indistinguishable from
    /// never having seen it — so the removal has to travel as a row of its own.
    @Test("a delete travels and takes on the other device")
    func softDeletePropagates() async throws {
        let sidecar = Sidecar()
        let phone = try CurationStore.inMemory(deviceId: "phone")
        let mac = try CurationStore.inMemory(deviceId: "mac")
        let phoneSync = engine(phone, sidecar.link())
        let macSync = engine(mac, sidecar.link())

        let list = try phone.createPlaylist(name: "Temporary", now: 1_000)
        try phone.addTracks([TrackLink(jellyfinId: "t1", contentKey: "k1")], to: list.id, now: 1_100)
        _ = try await phoneSync.sync()
        _ = try await macSync.sync()
        #expect(try mac.playlist(list.id) != nil)

        try phone.deletePlaylist(list.id, now: 5_000)
        _ = try await phoneSync.sync()
        _ = try await macSync.sync()

        #expect(try mac.playlist(list.id) == nil)
        // The row is still there, carrying the fact of the deletion.
        #expect(try mac.read { try Playlist.fetchOne($0, key: list.id) }?.deleted == true)
        #expect(try mac.items(in: list.id).isEmpty)
        #expect(try syncedRows(of: phone) == syncedRows(of: mac))
    }

    /// A delete is a versioned write like any other, so a newer edit beats it. That is
    /// deliberate: deletes-always-win makes a delete unrecoverable and lets a device
    /// that has been offline for a week destroy work done since.
    @Test("a delete and a newer edit resolve the same way on both devices")
    func deleteLosesToANewerEdit() async throws {
        let sidecar = Sidecar()
        let phone = try CurationStore.inMemory(deviceId: "phone")
        let mac = try CurationStore.inMemory(deviceId: "mac")
        let phoneSync = engine(phone, sidecar.link())
        let macSync = engine(mac, sidecar.link())

        let list = try phone.createPlaylist(name: "Contested", now: 1_000)
        try phone.addTracks([TrackLink(jellyfinId: "t1", contentKey: "k1")], to: list.id, now: 1_100)
        _ = try await phoneSync.sync()
        _ = try await macSync.sync()

        try phone.deletePlaylist(list.id, now: 5_000)
        try mac.rename(playlist: list.id, to: "Kept", now: 6_000)

        _ = try await phoneSync.sync()
        _ = try await macSync.sync()
        _ = try await phoneSync.sync()

        #expect(try phone.playlist(list.id)?.name == "Kept")
        #expect(try mac.playlist(list.id)?.name == "Kept")
        // Revived empty, and that is the documented cost of per-row merging: the
        // delete stamped every item at the moment it ran, and the rename that beat it
        // touched only the playlist row.
        #expect(try phone.items(in: list.id).isEmpty)
        #expect(try syncedRows(of: phone) == syncedRows(of: mac))
    }

    @Test("a delete newer than the edit it races wins, on both devices")
    func deleteBeatsAnOlderEdit() async throws {
        let sidecar = Sidecar()
        let phone = try CurationStore.inMemory(deviceId: "phone")
        let mac = try CurationStore.inMemory(deviceId: "mac")
        let phoneSync = engine(phone, sidecar.link())
        let macSync = engine(mac, sidecar.link())

        let list = try phone.createPlaylist(name: "Contested", now: 1_000)
        _ = try await phoneSync.sync()
        _ = try await macSync.sync()

        try mac.rename(playlist: list.id, to: "Renamed", now: 5_000)
        try phone.deletePlaylist(list.id, now: 6_000)

        _ = try await macSync.sync()
        _ = try await phoneSync.sync()
        _ = try await macSync.sync()

        #expect(try phone.playlist(list.id) == nil)
        #expect(try mac.playlist(list.id) == nil)
        #expect(try syncedRows(of: phone) == syncedRows(of: mac))
    }

    /// Two devices liking the same track offline mint two row ids for it, and the
    /// schema is unique on the track. The clash is settled by the same comparison
    /// everything else uses, which is why both devices settle it the same way without
    /// announcing anything.
    @Test("the same track liked on two devices collapses to one row everywhere")
    func duplicateLikesCollapse() async throws {
        let sidecar = Sidecar()
        let phone = try CurationStore.inMemory(deviceId: "phone")
        let mac = try CurationStore.inMemory(deviceId: "mac")
        let phoneSync = engine(phone, sidecar.link())
        let macSync = engine(mac, sidecar.link())

        try phone.record(
            Like(id: "like-phone", jellyfinId: "t1", contentKey: "k1", liked: true, updatedAt: 0, originDevice: "phone"),
            at: 5_000
        )
        try mac.record(
            Like(id: "like-mac", jellyfinId: "t1", contentKey: "k1", liked: false, updatedAt: 0, originDevice: "mac"),
            at: 6_000
        )

        _ = try await phoneSync.sync()
        _ = try await macSync.sync()
        _ = try await phoneSync.sync()

        let phoneLikes = try phone.read { try Like.fetchAll($0) }
        let macLikes = try mac.read { try Like.fetchAll($0) }
        #expect(phoneLikes.map(\.id) == ["like-mac"])
        #expect(macLikes.map(\.id) == ["like-mac"])
        #expect(phoneLikes[0].liked == false)
        #expect(try syncedRows(of: phone) == syncedRows(of: mac))
    }

    // MARK: - 12. Play events

    /// The append-only case. There is no such thing as a conflicting append, so the
    /// only failure available is counting one twice — which would inflate every play
    /// count, recap and weighted shuffle in the app.
    @Test("two devices' listening merges without either losing a play")
    func historyMergesBothWays() async throws {
        let sidecar = Sidecar()
        let phone = try CurationStore.inMemory(deviceId: "phone")
        let mac = try CurationStore.inMemory(deviceId: "mac")
        let phoneSync = engine(phone, sidecar.link())
        let macSync = engine(mac, sidecar.link())

        for index in 0..<3 {
            try phone.append(PlayEvent(
                id: "phone-e\(index)", jellyfinId: "t1", contentKey: "k1",
                startedAt: Millis(1_000 + index), msPlayed: 200_000, completed: true, originDevice: "phone"
            ))
            try mac.append(PlayEvent(
                id: "mac-e\(index)", jellyfinId: "t1", contentKey: "k1",
                startedAt: Millis(2_000 + index), msPlayed: 200_000, completed: true, originDevice: "mac"
            ))
        }

        _ = try await phoneSync.sync()
        _ = try await macSync.sync()
        _ = try await phoneSync.sync()

        #expect(try phone.playCount(jellyfinId: "t1") == 6)
        #expect(try mac.playCount(jellyfinId: "t1") == 6)
        #expect(try syncedRows(of: phone) == syncedRows(of: mac))
    }

    /// Delivered again after an interrupted sync, or read from a rewound cursor: an
    /// event already here is nothing to do, not a second play.
    @Test("the same play event delivered twice is not counted twice")
    func replayedHistoryDoesNotDouble() async throws {
        let sidecar = Sidecar()
        let phone = try CurationStore.inMemory(deviceId: "phone")
        let mac = try CurationStore.inMemory(deviceId: "mac")

        for index in 0..<4 {
            try phone.append(PlayEvent(
                id: "e\(index)", jellyfinId: "t1", contentKey: "k1",
                startedAt: Millis(1_000 + index), msPlayed: 200_000, completed: true, originDevice: "phone"
            ))
        }
        _ = try await engine(phone, sidecar.link()).sync()

        let macSync = engine(mac, sidecar.link())
        _ = try await macSync.sync()
        try mac.setSyncCursor("0")
        let again = try await macSync.sync()

        #expect(again.ignoredDuplicate == 4)
        #expect(again.applied == 0)
        #expect(try mac.playCount(jellyfinId: "t1") == 4)
    }

    /// The one amendment history allows, and the one that has to survive the wire.
    ///
    /// `beginPlay` writes the event when playback starts so that iOS killing a
    /// backgrounded app still leaves the play recorded; `finishPlay` fills in how it
    /// went. When a sync happens between the two — which is the normal case for a long
    /// play, and the whole reason the row is written early — the other device receives
    /// the 0 ms version first and the finished one second. If the second is dropped as
    /// a duplicate, every other device holds "started, outcome unknown" forever and its
    /// play counts disagree with the device that did the listening.
    @Test("an amended play event reaches the other device")
    func amendedPlayEventsPropagate() async throws {
        let sidecar = Sidecar()
        let phone = try CurationStore.inMemory(deviceId: "phone")
        let mac = try CurationStore.inMemory(deviceId: "mac")
        let phoneSync = engine(phone, sidecar.link())
        let macSync = engine(mac, sidecar.link())

        let started = try phone.beginPlay(jellyfinId: "t1", contentKey: "k1", source: .album, at: 5_000)
        _ = try await phoneSync.sync()
        _ = try await macSync.sync()
        #expect(try mac.playCount(jellyfinId: "t1") == 0)

        try phone.finishPlay(started, msPlayed: 250_000, trackDurationMs: 250_000, endedAt: 255_000)
        _ = try await phoneSync.sync()
        _ = try await macSync.sync()

        let merged = try #require(try mac.read { try PlayEvent.fetchOne($0, key: started.id) })
        #expect(merged.msPlayed == 250_000)
        #expect(merged.completed)
        #expect(merged.endedAt == 255_000)
        let phonePlays = try phone.playCount(jellyfinId: "t1")
        #expect(phonePlays == 1)
        #expect(try mac.playCount(jellyfinId: "t1") == phonePlays)
        #expect(try syncedRows(of: mac) == syncedRows(of: phone))
    }

    /// A skip amended onto an event that had already synced as a bare start. Same
    /// mechanism as the completed case, and the more damaging one to lose: a device
    /// that never learns about the skip counts it as a play.
    @Test("an amended skip reaches the other device too")
    func amendedSkipsPropagate() async throws {
        let sidecar = Sidecar()
        let phone = try CurationStore.inMemory(deviceId: "phone")
        let mac = try CurationStore.inMemory(deviceId: "mac")
        let phoneSync = engine(phone, sidecar.link())
        let macSync = engine(mac, sidecar.link())

        let started = try phone.beginPlay(jellyfinId: "t1", contentKey: "k1", at: 5_000)
        _ = try await phoneSync.sync()
        _ = try await macSync.sync()

        try phone.finishPlay(started, msPlayed: 3_000, trackDurationMs: 210_000, endedAt: 8_000)
        _ = try await phoneSync.sync()
        _ = try await macSync.sync()

        #expect(try mac.read { try PlayEvent.fetchOne($0, key: started.id) }?.skipped == true)
        let phoneSkips = try phone.stats(jellyfinId: "t1").skipCount
        #expect(phoneSkips == 1)
        #expect(try mac.stats(jellyfinId: "t1").skipCount == phoneSkips)
        #expect(try syncedRows(of: mac) == syncedRows(of: phone))
    }

    /// The short-play path, where no sync happened in between: the amendment supersedes
    /// the unsynced begin op rather than being queued behind it, so one op leaves the
    /// device and the other end never sees the 0 ms version at all.
    @Test("a play that starts and ends between syncs travels as one op")
    func unsyncedAmendmentCoalesces() async throws {
        let sidecar = Sidecar()
        let phone = try CurationStore.inMemory(deviceId: "phone")
        let mac = try CurationStore.inMemory(deviceId: "mac")

        let started = try phone.beginPlay(jellyfinId: "t1", contentKey: "k1", at: 5_000)
        try phone.finishPlay(started, msPlayed: 250_000, trackDurationMs: 250_000, endedAt: 255_000)
        #expect(try phone.pendingOps().count == 1)

        _ = try await engine(phone, sidecar.link()).sync()
        _ = try await engine(mac, sidecar.link()).sync()

        #expect(await sidecar.opCount(for: "alex") == 1)
        #expect(try mac.read { try PlayEvent.fetchOne($0, key: started.id) }?.completed == true)
        #expect(try syncedRows(of: mac) == syncedRows(of: phone))
    }

    /// The amendment is a more complete version of one row, not a licence to overwrite:
    /// an op that adds nothing must still change nothing, or a replayed batch would
    /// keep reporting work it did not do.
    @Test("a replayed amendment does not undo itself")
    func amendmentsAreIdempotent() async throws {
        let sidecar = Sidecar()
        let phone = try CurationStore.inMemory(deviceId: "phone")
        let mac = try CurationStore.inMemory(deviceId: "mac")

        let started = try phone.beginPlay(jellyfinId: "t1", contentKey: "k1", at: 5_000)
        _ = try await engine(phone, sidecar.link()).sync()
        try phone.finishPlay(started, msPlayed: 250_000, trackDurationMs: 250_000, endedAt: 255_000)
        _ = try await engine(phone, sidecar.link()).sync()

        let macSync = engine(mac, sidecar.link())
        _ = try await macSync.sync()
        let settled = try syncedRows(of: mac)

        // Read the whole log again, begin op and amendment in their original order.
        try mac.setSyncCursor("0")
        let replay = try await macSync.sync()

        #expect(replay.applied == 0)
        #expect(replay.ignoredDuplicate == 2)
        #expect(try syncedRows(of: mac) == settled)
        #expect(try mac.playCount(jellyfinId: "t1") == 1)
    }

    /// Two devices appending at the same instant is not a conflict and must never be
    /// resolved as one — both listens happened.
    @Test("simultaneous appends never conflict")
    func simultaneousAppendsBothSurvive() async throws {
        let sidecar = Sidecar()
        let phone = try CurationStore.inMemory(deviceId: "phone")
        let mac = try CurationStore.inMemory(deviceId: "mac")
        let phoneSync = engine(phone, sidecar.link())
        let macSync = engine(mac, sidecar.link())

        try phone.append(PlayEvent(
            id: "phone-e", jellyfinId: "t1", contentKey: "k1", startedAt: 5_000,
            msPlayed: 200_000, completed: true, originDevice: "phone"
        ))
        try mac.append(PlayEvent(
            id: "mac-e", jellyfinId: "t1", contentKey: "k1", startedAt: 5_000,
            msPlayed: 200_000, completed: true, originDevice: "mac"
        ))

        _ = try await phoneSync.sync()
        _ = try await macSync.sync()
        _ = try await phoneSync.sync()

        #expect(try phone.playCount(jellyfinId: "t1") == 2)
        #expect(try mac.playCount(jellyfinId: "t1") == 2)
        #expect(try syncedRows(of: phone) == syncedRows(of: mac))
    }

    // MARK: - Queue state

    /// Keyed by device rather than by a UUID, so two devices' queues coexist instead of
    /// overwriting each other — which is the whole point of resuming across devices.
    @Test("each device's queue is its own row and both survive the merge")
    func queuesCoexist() async throws {
        let sidecar = Sidecar()
        let phone = try CurationStore.inMemory(deviceId: "phone")
        let mac = try CurationStore.inMemory(deviceId: "mac")
        let phoneSync = engine(phone, sidecar.link())
        let macSync = engine(mac, sidecar.link())

        try phone.saveQueue(deviceName: "iPhone", trackIds: ["a", "b"], position: 0, elapsedMs: 1_000, at: 5_000)
        try mac.saveQueue(deviceName: "Studio", trackIds: ["c", "d"], position: 1, elapsedMs: 2_000, at: 6_000)

        _ = try await phoneSync.sync()
        _ = try await macSync.sync()
        _ = try await phoneSync.sync()

        #expect(try phone.resumableQueues(now: 6_000, within: .max).map(\.deviceId) == ["mac"])
        #expect(try mac.resumableQueues(now: 6_000, within: .max).map(\.deviceId) == ["phone"])
        #expect(try phone.localQueue()?.trackIdList == ["a", "b"])
        #expect(try syncedRows(of: phone) == syncedRows(of: mac))
    }

    /// Queue state is a latest-value channel: an unsynced op for this device is
    /// superseded rather than stacked behind. At a save every few seconds of playback
    /// the difference is a push that grows without bound.
    @Test("rapid queue saves collapse to one op rather than stacking")
    func queueSavesCoalesce() async throws {
        let sidecar = Sidecar()
        let phone = try CurationStore.inMemory(deviceId: "phone")

        for index in 0..<20 {
            try phone.saveQueue(
                deviceName: "iPhone", trackIds: ["a", "b", "c"], position: index % 3,
                elapsedMs: index * 10_000, at: Millis(5_000 + index)
            )
        }
        #expect(try phone.pendingOps().count == 1)

        let report = try await engine(phone, sidecar.link()).sync()
        #expect(report.pushed == 1)
        #expect(await sidecar.opCount(for: "alex") == 1)
        #expect(try phone.localQueue()?.elapsedMs == 190_000)
    }
}

/// A 5xx has no story in the contract: it is neither a rejection nor a validation
/// failure, so nothing takes the op out of the queue and every change behind it waits
/// on one the server cannot swallow.
@Suite("A server that throws on one op")
struct ServerFaultIsolationTests {
    @Test("the offending op is found and quarantined, and the rest get through")
    func isolatesAndContinues() async throws {
        let sidecar = Sidecar()
        let store = try CurationStore.inMemory(deviceId: "phone")

        var ops: [String] = []
        for index in 0..<8 {
            _ = try store.createPlaylist(name: "List \(index)")
        }
        ops = try store.pendingOps().map(\.opId)
        let victim = try #require(ops.dropFirst(3).first)
        await sidecar.poison(victim)

        let engine = SyncEngine(store: store, transport: SidecarLink(sidecar: sidecar, userId: "u1"))
        let report = try await engine.sync()

        #expect(report.quarantinedOutbound == 1)
        // Everything else reached the server rather than waiting behind it.
        #expect(report.pushed == ops.count - 1)
        #expect(try store.pendingOps().isEmpty)

        let held = try store.quarantinedOps()
        #expect(held.count == 1)
        #expect(held.first?.opId == victim)
    }

    /// A restart or a timeout must not cost a change. Only an op that reproduces the
    /// failure *by itself* is blamed for it.
    @Test("a fault that does not reproduce alone quarantines nothing")
    func transientFaultsAreNotBlamed() async throws {
        let sidecar = Sidecar()
        let store = try CurationStore.inMemory(deviceId: "phone")
        for index in 0..<4 { _ = try store.createPlaylist(name: "List \(index)") }

        let all = try store.pendingOps().map(\.opId)
        for id in all { await sidecar.poison(id) }
        // Only the first request fails, standing in for a server that was merely
        // restarting when the batch landed. Every op is poisoned, so a client that
        // blamed whichever op it happened to isolate would quarantine a healthy one.
        await sidecar.clearPoisonAfterNextFailure()

        let engine = SyncEngine(store: store, transport: SidecarLink(sidecar: sidecar, userId: "u1"))
        let report = try await engine.sync()

        #expect(report.quarantinedOutbound == 0)
        #expect(try store.quarantinedOps().isEmpty)
        #expect(try store.pendingOps().isEmpty)
    }
}

/// A server fault is the one thing in quarantine that gets fixed, so the change has
/// to be recoverable — otherwise a bug on the server permanently costs the listener
/// whatever they did while it was broken.
@Suite("Retrying after a server is fixed")
struct QuarantineRetryTests {
    @Test("a held change goes through once the server stops failing")
    func recoversAfterTheFix() async throws {
        let sidecar = Sidecar()
        let store = try CurationStore.inMemory(deviceId: "phone")
        let list = try store.createPlaylist(name: "Held Back")

        let opId = try #require(try store.pendingOps().first?.opId)
        await sidecar.poison(opId)

        let engine = SyncEngine(store: store, transport: SidecarLink(sidecar: sidecar, userId: "u1"))
        _ = try await engine.sync()
        #expect(try store.quarantinedOps().count == 1)
        #expect(try store.retryableQuarantineCount() == 1)

        // The server is fixed.
        await sidecar.unpoison(opId)
        #expect(try store.requeueQuarantined() == 1)
        #expect(try store.quarantinedOps().isEmpty)

        let report = try await engine.sync()
        #expect(report.pushed == 1)

        // And it really reached the server, in its original form.
        let stored = await sidecar.ops(for: "u1")
        #expect(stored.contains { $0.op.opId == opId })
        #expect(stored.contains { $0.op.entityId == list.id })
    }

    /// Retrying something the server will refuse forever would spin, so only server
    /// faults are offered.
    @Test("a permanently invalid op is not offered a retry")
    func permanentFaultsAreNotRetryable() throws {
        let store = try CurationStore.inMemory(deviceId: "phone")
        let list = try store.createPlaylist(name: "Bad")
        let op = try #require(try store.pendingOps().first)

        try store.quarantine(op, reason: .payloadTooLarge(bytes: 999_999), at: 100)

        #expect(try store.retryableQuarantineCount() == 0)
        #expect(try store.requeueQuarantined() == 0)
        #expect(try store.quarantinedOps().count == 1)
        _ = list
    }
}

/// "Stuck sending 7 changes" is true and useless: it describes the client's
/// predicament and says nothing about the cause. These pin that the stall carries
/// enough to tell the causes apart.
@Suite("A stall that explains itself")
struct StallDiagnosisTests {
    private func storeWithWork() throws -> CurationStore {
        let store = try CurationStore.inMemory(deviceId: "phone")
        for index in 0..<3 { _ = try store.createPlaylist(name: "List \(index)") }
        return store
    }

    @Test("a server that acknowledges nothing says so")
    func acknowledgesNothing() async throws {
        let sidecar = Sidecar()
        await sidecar.stopAcknowledging()
        let store = try storeWithWork()
        let engine = SyncEngine(store: store, transport: SidecarLink(sidecar: sidecar, userId: "u1"))

        await #expect(throws: SyncError.self) { _ = try await engine.sync() }

        do {
            _ = try await engine.sync()
            Issue.record("expected a stall")
        } catch let error as SyncError {
            guard case .pushStalled(let pending, let accepted, let rejected, let unmatched) = error else {
                Issue.record("expected pushStalled, got \(error)")
                return
            }
            #expect(pending == 3)
            #expect(accepted == 0)
            #expect(rejected == 0)
            #expect(unmatched == 0)
        }
    }

    /// Dropped silently, a rejection naming an op that was never sent is
    /// indistinguishable from the server saying nothing — and produces the same stall.
    @Test("a server rejecting ids it was never sent is told apart from one saying nothing")
    func rejectsUnknownIds() async throws {
        let sidecar = Sidecar()
        await sidecar.rejectWithUnknownIds()
        let store = try storeWithWork()
        let engine = SyncEngine(store: store, transport: SidecarLink(sidecar: sidecar, userId: "u1"))

        _ = try? await engine.sync()
        do {
            _ = try await engine.sync()
            Issue.record("expected a stall")
        } catch let error as SyncError {
            guard case .pushStalled(_, let accepted, let rejected, let unmatched) = error else {
                Issue.record("expected pushStalled, got \(error)")
                return
            }
            #expect(accepted == 0)
            #expect(rejected == 3, "the server did answer, in a shape that matched nothing")
            #expect(unmatched == 3)
        }
        // And nothing was quarantined on the strength of an id that matched no op.
        #expect(try store.quarantinedOps().isEmpty)
        #expect(try store.pendingOps().count == 3)
    }
}
