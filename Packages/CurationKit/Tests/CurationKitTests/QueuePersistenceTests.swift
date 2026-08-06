import Foundation
import GRDB
import Testing
@testable import CurationKit

@Suite("Queue persistence")
struct QueuePersistenceTests {
    private func store() throws -> CurationStore { try .inMemory(deviceId: "phone") }

    /// A queue belonging to another device, arriving the way the sync engine will
    /// apply one: the row lands without an op, because an inbound change is not this
    /// device's change to push back.
    private func receive(
        into store: CurationStore,
        deviceId: String,
        deviceName: String,
        trackIds: [String] = ["t1"],
        updatedAt: Millis
    ) throws {
        try store.writeLocal { db in
            try QueueState(
                deviceId: deviceId,
                deviceName: deviceName,
                trackIds: trackIds,
                position: 0,
                elapsedMs: 0,
                updatedAt: updatedAt
            ).insert(db)
        }
    }

    private func queueOps(_ store: CurationStore) throws -> [Op] {
        try store.pendingOps().filter { $0.entity == "queueState" }
    }

    // MARK: - Storing

    @Test("a saved queue comes back whole")
    func roundTrip() throws {
        let store = try store()
        try store.saveQueue(
            deviceName: "Alex's iPhone",
            trackIds: ["a", "b", "c"],
            position: 1,
            elapsedMs: 42_000,
            at: 1_000
        )

        let restored = try #require(try store.localQueue())
        #expect(restored.deviceId == "phone")
        #expect(restored.deviceName == "Alex's iPhone")
        #expect(restored.trackIdList == ["a", "b", "c"])
        #expect(restored.position == 1)
        #expect(restored.elapsedMs == 42_000)
        #expect(restored.updatedAt == 1_000)
        #expect(restored.originDevice == "phone")
    }

    /// The invariant `record` enforces everywhere else. This table cannot use
    /// `record`, so it is worth proving separately that it did not lose the op along
    /// the way — a queue that never syncs makes cross-device resume silently do
    /// nothing.
    @Test("saving a queue writes its op, keyed by the device")
    func writesItsOp() throws {
        let store = try store()
        try store.saveQueue(deviceName: "iPhone", trackIds: ["a"], position: 0, elapsedMs: 0, at: 500)

        let ops = try queueOps(store)
        #expect(ops.count == 1)
        #expect(ops[0].entityId == "phone")
        #expect(ops[0].operation == "upsert")
        #expect(ops[0].createdAt == 500)
        #expect(ops[0].payload.contains("\"deviceName\":\"iPhone\""))
    }

    @Test("repeated saves supersede their unpushed op instead of stacking")
    func opsCoalesce() throws {
        let store = try store()
        for second in 0..<10 {
            try store.saveQueue(
                deviceName: "iPhone",
                trackIds: ["a", "b"],
                position: 0,
                elapsedMs: second * 1_000,
                at: Millis(second)
            )
        }

        let ops = try queueOps(store)
        #expect(ops.count == 1)
        #expect(ops[0].createdAt == 9)
        #expect(ops[0].payload.contains("\"elapsedMs\":9000"))
    }

    /// Dropping an op the server already acknowledged would throw away the
    /// idempotency key that makes a retry safe.
    @Test("coalescing leaves acknowledged ops alone")
    func coalescingSparesSyncedOps() throws {
        let store = try store()
        try store.saveQueue(deviceName: "iPhone", trackIds: ["a"], position: 0, elapsedMs: 0, at: 1)
        let first = try #require(try queueOps(store).first)
        try store.markSynced([first.opId])

        try store.saveQueue(deviceName: "iPhone", trackIds: ["a"], position: 0, elapsedMs: 9_000, at: 2)

        let total = try store.read { try Op.fetchCount($0) }
        #expect(try queueOps(store).count == 1)
        #expect(total == 2)
    }

    @Test("an empty queue survives the JSON round trip as an empty list")
    func emptyQueueRoundTrip() throws {
        let store = try store()
        try store.saveQueue(deviceName: "iPhone", trackIds: [], position: 0, elapsedMs: 0, at: 1)

        let restored = try #require(try store.localQueue())
        #expect(restored.trackIds == "[]")
        #expect(restored.trackIdList.isEmpty)
        #expect(restored.position == 0)
    }

    @Test("ids with characters JSON has to escape come back unchanged")
    func awkwardIdsRoundTrip() throws {
        let store = try store()
        let ids = ["plain", "with \"quotes\"", "with\\backslash", "with/slash", "unicode–ダッシュ"]
        try store.saveQueue(deviceName: "iPhone", trackIds: ids, position: 0, elapsedMs: 0, at: 1)

        #expect(try store.localQueue()?.trackIdList == ids)
    }

    // MARK: - Resuming

    @Test("resume offers other devices' queues and never this one's")
    func excludesThisDevice() throws {
        let store = try store()
        try store.saveQueue(deviceName: "iPhone", trackIds: ["a"], position: 0, elapsedMs: 0, at: 1_000)
        try receive(into: store, deviceId: "mac", deviceName: "Studio", updatedAt: 900)

        let resumable = try store.resumableQueues(now: 1_000)
        #expect(resumable.map(\.deviceId) == ["mac"])
    }

    @Test("resume offers the most recently updated queue first")
    func recencyOrder() throws {
        let store = try store()
        let now: Millis = 10_000_000
        try receive(into: store, deviceId: "mac", deviceName: "Studio", updatedAt: now - 60_000)
        try receive(into: store, deviceId: "ipad", deviceName: "iPad", updatedAt: now - 1_000)
        try receive(into: store, deviceId: "carplay", deviceName: "Car", updatedAt: now - 3_600_000)

        #expect(try store.resumableQueues(now: now).map(\.deviceId) == ["ipad", "mac", "carplay"])
    }

    /// The point of the window: yesterday evening's queue is continuity, last week's
    /// is a question about something the user no longer remembers queuing.
    @Test("a queue older than the resume window is not offered")
    func staleQueuesAreDropped() throws {
        let store = try store()
        let now: Millis = 10_000_000_000
        try receive(into: store, deviceId: "mac", deviceName: "Studio", updatedAt: now - 2 * 60 * 60 * 1000)
        try receive(into: store, deviceId: "ipad", deviceName: "iPad", updatedAt: now - 3 * 24 * 60 * 60 * 1000)

        #expect(try store.resumableQueues(now: now).map(\.deviceId) == ["mac"])
        // Not offering is a display decision; the row itself is still there to sync.
        #expect(try store.resumableQueues(now: now, within: .max).count == 2)
    }

    @Test("a signed-out device's empty queue is not offered")
    func emptyRemoteQueueIsNotOffered() throws {
        let store = try store()
        try receive(into: store, deviceId: "mac", deviceName: "Studio", trackIds: [], updatedAt: 1_000)
        #expect(try store.resumableQueues(now: 1_000).isEmpty)
    }

    // MARK: - Skipping redundant writes

    @Test("a second of playback is not worth a write")
    func skipsWhenNothingMoved() throws {
        let store = try store()
        try store.saveQueue(deviceName: "iPhone", trackIds: ["a", "b"], position: 0, elapsedMs: 30_000, at: 1_000)

        let wrote = try store.saveQueueIfChanged(
            deviceName: "iPhone",
            trackIds: ["a", "b"],
            position: 0,
            elapsedMs: 31_000,
            at: 99_000
        )

        #expect(wrote == false)
        // The row is untouched, not merely equal: had it been rewritten, `updatedAt`
        // would carry the later clock.
        #expect(try store.localQueue()?.updatedAt == 1_000)
        #expect(try store.localQueue()?.elapsedMs == 30_000)
        #expect(try queueOps(store).count == 1)
    }

    @Test("elapsed moving past the threshold is worth a write")
    func writesWhenElapsedMovesEnough() throws {
        let store = try store()
        try store.saveQueue(deviceName: "iPhone", trackIds: ["a"], position: 0, elapsedMs: 30_000, at: 1_000)

        let wrote = try store.saveQueueIfChanged(
            deviceName: "iPhone",
            trackIds: ["a"],
            position: 0,
            elapsedMs: 30_000 + QueuePolicy.elapsedThresholdMs + 1,
            at: 2_000
        )

        #expect(wrote)
        #expect(try store.localQueue()?.updatedAt == 2_000)
    }

    /// A seek backwards lands inside the threshold's tolerance if you only look at
    /// magnitude in one direction, and then the resumed position is ahead of where
    /// the listener deliberately put it.
    @Test("seeking backwards is a change even when the jump is small")
    func seekBackwardsCounts() throws {
        let store = try store()
        try store.saveQueue(deviceName: "iPhone", trackIds: ["a"], position: 0, elapsedMs: 60_000, at: 1_000)

        let wrote = try store.saveQueueIfChanged(
            deviceName: "iPhone",
            trackIds: ["a"],
            position: 0,
            elapsedMs: 1_000,
            at: 2_000
        )

        #expect(wrote)
        #expect(try store.localQueue()?.elapsedMs == 1_000)
    }

    @Test("a track change is always worth a write, however little time passed")
    func trackChangeCounts() throws {
        let store = try store()
        try store.saveQueue(deviceName: "iPhone", trackIds: ["a", "b"], position: 0, elapsedMs: 1_000, at: 1_000)

        let wrote = try store.saveQueueIfChanged(
            deviceName: "iPhone",
            trackIds: ["a", "b"],
            position: 1,
            elapsedMs: 0,
            at: 2_000
        )

        #expect(wrote)
        #expect(try store.localQueue()?.position == 1)
    }

    @Test("editing the queue is worth a write even at the same index and time")
    func listChangeCounts() throws {
        let store = try store()
        try store.saveQueue(deviceName: "iPhone", trackIds: ["a", "b"], position: 0, elapsedMs: 1_000, at: 1_000)

        let wrote = try store.saveQueueIfChanged(
            deviceName: "iPhone",
            trackIds: ["a", "c"],
            position: 0,
            elapsedMs: 1_000,
            at: 2_000
        )

        #expect(wrote)
        #expect(try store.localQueue()?.trackIdList == ["a", "c"])
    }

    @Test("a player that has never played anything writes nothing at all")
    func idlePlayerWritesNothing() throws {
        let store = try store()
        let wrote = try store.saveQueueIfChanged(
            deviceName: "iPhone",
            trackIds: [],
            position: 0,
            elapsedMs: 0,
            at: 1_000
        )

        #expect(wrote == false)
        #expect(try store.localQueue() == nil)
        #expect(try store.pendingOps().isEmpty)
    }

    /// A shuffle-all queue's tail sits past the cap, so reordering out there produces
    /// a byte-identical row. Comparing before windowing would write it anyway, every
    /// time, forever.
    @Test("a change past the cap is not a change")
    func changeBeyondTheCapSkips() throws {
        let store = try store()
        var tracks = (0..<1_000).map { "t\($0)" }
        try store.saveQueue(deviceName: "iPhone", trackIds: tracks, position: 0, elapsedMs: 0, at: 1_000)

        tracks.swapAt(900, 901)
        let wrote = try store.saveQueueIfChanged(
            deviceName: "iPhone",
            trackIds: tracks,
            position: 0,
            elapsedMs: 0,
            at: 2_000
        )

        #expect(wrote == false)
        #expect(try store.localQueue()?.updatedAt == 1_000)
    }

    // MARK: - The cap

    @Test("a queue under the cap keeps its history")
    func shortQueuesAreNotTrimmed() throws {
        let store = try store()
        let tracks = (0..<100).map { "t\($0)" }
        try store.saveQueue(deviceName: "iPhone", trackIds: tracks, position: 90, elapsedMs: 0, at: 1)

        let restored = try #require(try store.localQueue())
        #expect(restored.trackIdList == tracks)
        #expect(restored.position == 90)
    }

    /// The whole point of the cap's shape: what has been heard is disposable, what is
    /// coming is not.
    @Test("the cap drops played history and keeps everything upcoming")
    func capPreservesUpcoming() throws {
        let store = try store()
        let tracks = (0..<1_000).map { "t\($0)" }
        try store.saveQueue(deviceName: "iPhone", trackIds: tracks, position: 100, elapsedMs: 0, at: 1)

        let restored = try #require(try store.localQueue())
        let stored = restored.trackIdList
        #expect(stored.count == QueuePolicy.maxTracks)
        #expect(stored[restored.position] == "t100")
        #expect(Array(stored[restored.position...]) == Array(tracks[100..<(100 + QueuePolicy.maxTracks - QueuePolicy.maxHistory)]))
        #expect(stored.first == "t75")
    }

    @Test("near the end of a long queue nothing upcoming is lost")
    func capNearTheEnd() throws {
        let store = try store()
        let tracks = (0..<1_000).map { "t\($0)" }
        try store.saveQueue(deviceName: "iPhone", trackIds: tracks, position: 990, elapsedMs: 0, at: 1)

        let restored = try #require(try store.localQueue())
        let stored = restored.trackIdList
        #expect(stored.count == QueuePolicy.maxTracks)
        #expect(Array(stored[restored.position...]) == Array(tracks[990...]))
    }

    @Test("a position past the end of the queue restores to the last track")
    func positionBeyondTheEndClamps() throws {
        let store = try store()
        try store.saveQueue(deviceName: "iPhone", trackIds: ["a", "b", "c"], position: 99, elapsedMs: 0, at: 1)
        #expect(try store.localQueue()?.position == 2)
    }

    @Test("a negative elapsed is stored as the start of the track")
    func negativeElapsedClamps() throws {
        let store = try store()
        try store.saveQueue(deviceName: "iPhone", trackIds: ["a"], position: 0, elapsedMs: -1, at: 1)
        #expect(try store.localQueue()?.elapsedMs == 0)
    }

    // MARK: - Sign-out

    @Test("clearing empties the queue in a form that can travel")
    func clearQueue() throws {
        let store = try store()
        try store.saveQueue(deviceName: "iPhone", trackIds: ["a", "b"], position: 1, elapsedMs: 5_000, at: 1_000)

        #expect(try store.clearQueue(at: 2_000))

        let restored = try #require(try store.localQueue())
        #expect(restored.trackIdList.isEmpty)
        #expect(restored.position == 0)
        #expect(restored.elapsedMs == 0)
        #expect(restored.deviceName == "iPhone")
        #expect(restored.updatedAt == 2_000)

        // A cleared queue has to reach the other devices, or they keep offering a
        // queue this one no longer has.
        let ops = try queueOps(store)
        #expect(ops.count == 1)
        #expect(ops[0].payload.contains("\"trackIds\":\"[]\""))
    }

    @Test("clearing a device that never played anything writes nothing")
    func clearWithNothingToClear() throws {
        let store = try store()
        #expect(try store.clearQueue(at: 1_000) == false)
        #expect(try store.pendingOps().isEmpty)
    }
}
