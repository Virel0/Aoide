import Foundation
import GRDB
import Testing
@testable import CurationKit

@Suite("Applying pulled ops")
struct SyncMergeTests {
    private func store() throws -> CurationStore { try .inMemory(deviceId: "phone") }

    private func storedPlaylist(_ store: CurationStore, _ id: String = "list-1") throws -> Playlist? {
        try store.read { try Playlist.fetchOne($0, key: id) }
    }

    // MARK: - The invariant everything else depends on

    /// The single worst failure available here. An inbound change that queues an
    /// outbound op is a change this device claims as its own and pushes back; the
    /// other device pulls it, applies it, pushes it back, and the two trade the same
    /// row until one is switched off.
    @Test("applying inbound ops never queues an outbound one")
    func applyingNeverQueuesOps() throws {
        let store = try store()
        let mine = try store.createPlaylist(name: "Mine")
        let before = try store.pendingOps(limit: 1_000).count

        let batch = [
            try Wire.pulled(.playlist, makePlaylist(id: "theirs", updatedAt: 9_000, device: "mac"), entityId: "theirs", seq: 1),
            try Wire.pulled(
                .playlistItem,
                PlaylistItem(id: "item-1", playlistId: mine.id, jellyfinId: "t1", contentKey: "k1",
                             position: "V", updatedAt: 9_000, originDevice: "mac"),
                entityId: "item-1",
                seq: 2
            ),
            try Wire.pulled(
                .folder,
                Folder(id: "f1", name: "Mixes", sortIndex: "V", updatedAt: 9_000, originDevice: "mac"),
                entityId: "f1",
                seq: 3
            ),
            try Wire.pulled(
                .like,
                Like(id: "like-1", jellyfinId: "t1", contentKey: "k1", liked: true, updatedAt: 9_000, originDevice: "mac"),
                entityId: "like-1",
                seq: 4
            ),
            try Wire.pulled(
                .playEvent,
                PlayEvent(id: "e1", jellyfinId: "t1", contentKey: "k1", startedAt: 9_000, originDevice: "mac"),
                entityId: "e1",
                seq: 5
            ),
            try Wire.pulled(
                .queueState,
                QueueState(deviceId: "mac", deviceName: "Studio", trackIds: ["t1"], position: 0, elapsedMs: 0, updatedAt: 9_000),
                entityId: "mac",
                seq: 6
            )
        ]

        let report = try store.apply(batch, advancingTo: PullCursor(6), policy: .default, now: 10_000)
        #expect(report.applied == 6)
        #expect(try store.pendingOps(limit: 1_000).count == before)
    }

    /// The same op arriving twice — a replayed batch after an interrupted sync —
    /// must change nothing the second time.
    @Test("applying the same op twice changes nothing")
    func idempotent() throws {
        let store = try store()
        let op = try Wire.pulled(.playlist, makePlaylist(updatedAt: 5_000, device: "mac"), entityId: "list-1", seq: 1)

        #expect(try store.applyOne(op).applied == 1)
        let second = try store.applyOne(op)
        #expect(second.applied == 0)
        #expect(second.ignoredStale == 1)
        #expect(try store.read { try Playlist.fetchCount($0) } == 1)
    }

    /// Decision: our own ops go through the same merge path as everyone else's.
    @Test("our own op coming back leaves the row and the queue alone")
    func ownOpsAreNotSpecialCased() throws {
        let store = try store()
        let saved = try store.record(makePlaylist(id: "list-1", name: "Focus", updatedAt: 0, device: ""), at: 5_000)
        let pending = try store.pendingOps()

        let mine = try Wire.pulled(
            .playlist, saved, entityId: saved.id,
            opId: pending[0].opId, createdAt: 5_000, seq: 1, deviceId: "phone"
        )
        let report = try store.applyOne(mine)

        #expect(report.applied == 0)
        #expect(report.ignoredStale == 1)
        #expect(try storedPlaylist(store)?.name == "Focus")
        // Still pending: applying it is not the same as the server acknowledging it.
        #expect(try store.pendingOps().count == 1)
    }

    /// A device that was reinstalled keeps its id but has no rows. Skipping ops by
    /// device id would refuse to restore any of them.
    @Test("our own ops restore rows we no longer have")
    func ownOpsRestoreMissingRows() throws {
        let store = try store()
        let op = try Wire.pulled(
            .playlist, makePlaylist(updatedAt: 5_000, device: "phone"),
            entityId: "list-1", seq: 1, deviceId: "phone"
        )
        #expect(try store.applyOne(op).applied == 1)
        #expect(try storedPlaylist(store)?.name == "Late Night")
    }

    // MARK: - Last writer wins, per row

    @Test("a newer inbound row replaces an older local one")
    func newerWins() throws {
        let store = try store()
        try store.record(makePlaylist(id: "list-1", name: "Old", updatedAt: 0, device: ""), at: 1_000)

        let op = try Wire.pulled(
            .playlist, makePlaylist(id: "list-1", name: "New", updatedAt: 2_000, device: "mac"),
            entityId: "list-1", seq: 1
        )
        #expect(try store.applyOne(op).applied == 1)
        #expect(try storedPlaylist(store)?.name == "New")
    }

    @Test("an older inbound row loses and writes nothing")
    func olderLoses() throws {
        let store = try store()
        try store.record(makePlaylist(id: "list-1", name: "New", updatedAt: 0, device: ""), at: 5_000)

        let op = try Wire.pulled(
            .playlist, makePlaylist(id: "list-1", name: "Old", updatedAt: 2_000, device: "mac"),
            entityId: "list-1", seq: 1
        )
        let report = try store.applyOne(op)
        #expect(report.ignoredStale == 1)
        #expect(try storedPlaylist(store)?.name == "New")
    }

    /// Every device has to reach the same answer independently, or they diverge and
    /// stay diverged. Which device wins is arbitrary; that it is the same one
    /// everywhere is not.
    @Test("two writes in the same millisecond are settled by the device id")
    func tiebreak() throws {
        #expect(InboundApplier.incomingWins(incoming: (5, "zed"), existing: (5, "abe")))
        #expect(!InboundApplier.incomingWins(incoming: (5, "abe"), existing: (5, "zed")))
        // Identical in both fields is not "later", which is what makes replay safe.
        #expect(!InboundApplier.incomingWins(incoming: (5, "abe"), existing: (5, "abe")))

        let store = try store()
        try store.record(makePlaylist(id: "list-1", name: "Local", updatedAt: 0, device: ""), at: 3_000)
        let op = try Wire.pulled(
            .playlist, makePlaylist(id: "list-1", name: "Remote", updatedAt: 3_000, device: "zzz-mac"),
            entityId: "list-1", seq: 1
        )
        #expect(try store.applyOne(op).applied == 1)
        #expect(try storedPlaylist(store)?.name == "Remote")
    }

    // MARK: - Deletes

    @Test("an inbound delete soft-deletes the local row")
    func inboundDelete() throws {
        let store = try store()
        try store.record(makePlaylist(id: "list-1", updatedAt: 0, device: ""), at: 1_000)

        let op = try Wire.pulled(
            .playlist, makePlaylist(id: "list-1", updatedAt: 2_000, deleted: true, device: "mac"),
            entityId: "list-1", operation: .delete, seq: 1
        )
        #expect(try store.applyOne(op).applied == 1)
        #expect(try storedPlaylist(store)?.deleted == true)
        #expect(try store.playlist("list-1") == nil)
    }

    /// A delete is a versioned write like any other. Deletes-always-win would make a
    /// delete unrecoverable and let a device that has been offline for a week destroy
    /// work done since.
    @Test("a newer inbound edit revives a row deleted locally")
    func resurrection() throws {
        let store = try store()
        let list = try store.record(makePlaylist(id: "list-1", updatedAt: 0, device: ""), at: 1_000)
        try store.record(list, deleted: true, at: 2_000)
        #expect(try storedPlaylist(store)?.deleted == true)

        let op = try Wire.pulled(
            .playlist, makePlaylist(id: "list-1", name: "Renamed", updatedAt: 3_000, device: "mac"),
            entityId: "list-1", seq: 1
        )
        #expect(try store.applyOne(op).applied == 1)
        #expect(try storedPlaylist(store)?.deleted == false)
        #expect(try storedPlaylist(store)?.name == "Renamed")
    }

    @Test("an inbound delete older than a local edit loses")
    func staleDelete() throws {
        let store = try store()
        try store.record(makePlaylist(id: "list-1", name: "Kept", updatedAt: 0, device: ""), at: 9_000)

        let op = try Wire.pulled(
            .playlist, makePlaylist(id: "list-1", updatedAt: 2_000, deleted: true, device: "mac"),
            entityId: "list-1", operation: .delete, seq: 1
        )
        #expect(try store.applyOne(op).ignoredStale == 1)
        #expect(try storedPlaylist(store)?.deleted == false)
    }

    @Test("a delete whose payload does not say so is quarantined")
    func deleteWithoutFlag() throws {
        let store = try store()
        let op = try Wire.pulled(
            .playlist, makePlaylist(id: "list-1", updatedAt: 2_000, device: "mac"),
            entityId: "list-1", operation: .delete, seq: 1
        )
        #expect(try store.applyOne(op).quarantinedInbound == 1)
        #expect(try storedPlaylist(store) == nil)
        #expect(try store.quarantinedOps().first?.reason.contains("deleted") == true)
    }

    /// The contract writes the invariant as `deleted = 1`, after the SQLite column, and
    /// the delete gate reads both spellings on purpose — so a peer that serialises its
    /// rows straight out of SQLite gets past it and then meets Foundation, which refuses
    /// a `Bool` from a JSON number. Quarantining there loses the deletion for good: the
    /// cursor has already moved past the op and the server never offers it again, so the
    /// playlist stays alive on this device and nowhere else.
    @Test("a flag spelled as 1 applies rather than being quarantined")
    func integerFlagsDecode() throws {
        let store = try store()
        var fields = try #require(
            try Wire.payload(makePlaylist(id: "list-1", name: "Gone", updatedAt: 2_000,
                                          deleted: true, device: "mac")).objectValue
        )
        fields["deleted"] = .int(1)
        fields["isSmart"] = .int(0)
        let op = Wire.pulledRaw(
            entity: SyncEntity.playlist.wireName, entityId: "list-1",
            payload: .object(fields), operation: "delete", seq: 1
        )

        let report = try store.applyOne(op)
        #expect(report.applied == 1)
        #expect(report.quarantinedInbound == 0)
        #expect(try storedPlaylist(store)?.deleted == true)
        #expect(try storedPlaylist(store)?.isSmart == false)
    }

    /// Tolerance is not the same as guessing. A field that is genuinely the wrong type
    /// still fails, and the reason still names it.
    @Test("a field that is not a flag at all is still quarantined")
    func nonFlagTypeMismatchStillFails() throws {
        let store = try store()
        var fields = try #require(
            try Wire.payload(makePlaylist(id: "list-1", updatedAt: 2_000, device: "mac")).objectValue
        )
        fields["name"] = .int(7)
        let op = Wire.pulledRaw(
            entity: SyncEntity.playlist.wireName, entityId: "list-1",
            payload: .object(fields), seq: 1
        )
        #expect(try store.applyOne(op).quarantinedInbound == 1)
        #expect(try storedPlaylist(store) == nil)
    }

    // MARK: - Playlist items

    /// Ops arrive in commit order, so the usual cause is that the playlist is simply
    /// in a later batch. Refusing the item would turn a wait into permanent loss,
    /// because the cursor moves past either way.
    @Test("an item for a playlist we have never seen is stored and counted")
    func orphanItem() throws {
        let store = try store()
        let op = try Wire.pulled(
            .playlistItem,
            PlaylistItem(id: "item-1", playlistId: "nobody", jellyfinId: "t1", contentKey: "k1",
                         position: "V", updatedAt: 1_000, originDevice: "mac"),
            entityId: "item-1", seq: 1
        )
        let report = try store.applyOne(op)
        #expect(report.applied == 1)
        #expect(report.orphanedItems == 1)
        #expect(try store.read { try PlaylistItem.fetchCount($0) } == 1)
        // Invisible until its parent lands, rather than wrong.
        #expect(try store.items(in: "nobody").count == 1)
    }

    @Test("an item whose playlist is already here is not an orphan")
    func attachedItem() throws {
        let store = try store()
        let list = try store.createPlaylist(name: "Host")
        let op = try Wire.pulled(
            .playlistItem,
            PlaylistItem(id: "item-1", playlistId: list.id, jellyfinId: "t1", contentKey: "k1",
                         position: "V", updatedAt: 1_000, originDevice: "mac"),
            entityId: "item-1", seq: 1
        )
        let report = try store.applyOne(op)
        #expect(report.applied == 1)
        #expect(report.orphanedItems == 0)
        #expect(try store.items(in: list.id).map(\.jellyfinId) == ["t1"])
    }

    // MARK: - Likes

    /// Two devices liking the same track offline mint two row ids for it, and the
    /// schema has a unique index on the track. Inserting the second blindly is a
    /// constraint violation that would roll back the whole batch.
    @Test("a duplicate like for one track collapses instead of failing the batch")
    func duplicateLikes() throws {
        let store = try store()
        try store.record(
            Like(id: "like-local", jellyfinId: "t1", contentKey: "k1", liked: true, updatedAt: 0, originDevice: ""),
            at: 1_000
        )

        let op = try Wire.pulled(
            .like,
            Like(id: "like-remote", jellyfinId: "t1", contentKey: "k1", liked: false, updatedAt: 5_000, originDevice: "mac"),
            entityId: "like-remote", seq: 1
        )
        let report = try store.applyOne(op)
        #expect(report.applied == 1)
        #expect(report.supersededLikes == 1)

        let likes = try store.read { try Like.fetchAll($0) }
        #expect(likes.map(\.id) == ["like-remote"])
        #expect(likes[0].liked == false)
    }

    /// The comparison is a function of the two rows, so every device reaches the same
    /// winner without anybody announcing anything.
    @Test("the older of two duplicate likes does not displace the newer")
    func duplicateLikeLoses() throws {
        let store = try store()
        try store.record(
            Like(id: "like-local", jellyfinId: "t1", contentKey: "k1", liked: true, updatedAt: 0, originDevice: ""),
            at: 9_000
        )

        let op = try Wire.pulled(
            .like,
            Like(id: "like-remote", jellyfinId: "t1", contentKey: "k1", liked: false, updatedAt: 1_000, originDevice: "mac"),
            entityId: "like-remote", seq: 1
        )
        #expect(try store.applyOne(op).ignoredStale == 1)
        #expect(try store.read { try Like.fetchAll($0) }.map(\.id) == ["like-local"])
    }

    // MARK: - Play events

    @Test("a play event is inserted once and never again")
    func playEventInsertIfAbsent() throws {
        let store = try store()
        let event = PlayEvent(id: "e1", jellyfinId: "t1", contentKey: "k1", startedAt: 5_000,
                              msPlayed: 1_000, originDevice: "mac")
        let op = try Wire.pulled(.playEvent, event, entityId: "e1", seq: 1)

        #expect(try store.applyOne(op).applied == 1)
        let second = try store.applyOne(op)
        #expect(second.applied == 0)
        #expect(second.ignoredDuplicate == 1)
        #expect(try store.read { try PlayEvent.fetchCount($0) } == 1)
    }

    /// The one amendment history allows, and the one insert-if-absent would drop.
    /// `beginPlay` writes the row when playback starts — iOS kills backgrounded audio
    /// apps during exactly the long plays — and `finishPlay` fills in how it went. A
    /// sync landing between the two is the normal case, so the other devices see the
    /// bare start first and the outcome second.
    @Test("a finished play replaces the bare start it was opened with")
    func playEventAmendment() throws {
        let store = try store()
        let started = PlayEvent(id: "e1", jellyfinId: "t1", contentKey: "k1",
                                startedAt: 5_000, originDevice: "mac")
        try store.applyOne(try Wire.pulled(.playEvent, started, entityId: "e1", seq: 1))

        var finished = started
        finished.endedAt = 250_000
        finished.msPlayed = 245_000
        finished.completed = true
        let report = try store.applyOne(try Wire.pulled(.playEvent, finished, entityId: "e1", seq: 2))

        #expect(report.applied == 1)
        let stored = try #require(try store.read { try PlayEvent.fetchOne($0, key: "e1") })
        #expect(stored.msPlayed == 245_000)
        #expect(stored.completed)
        // Amended, not duplicated: the same listen, known better.
        #expect(try store.read { try PlayEvent.fetchCount($0) } == 1)
    }

    /// The comparison runs in one direction only. A batch replayed from a rewound
    /// cursor delivers the bare start again, and it must not undo the outcome.
    @Test("a play event never becomes less finished than it already is")
    func playEventAmendmentDirection() throws {
        let store = try store()
        let started = PlayEvent(id: "e1", jellyfinId: "t1", contentKey: "k1",
                                startedAt: 5_000, originDevice: "mac")
        var finished = started
        finished.endedAt = 250_000
        finished.msPlayed = 245_000
        finished.completed = true

        try store.applyOne(try Wire.pulled(.playEvent, finished, entityId: "e1", seq: 1))
        let report = try store.applyOne(try Wire.pulled(.playEvent, started, entityId: "e1", seq: 2))

        #expect(report.applied == 0)
        #expect(report.ignoredDuplicate == 1)
        #expect(try store.read { try PlayEvent.fetchOne($0, key: "e1") }?.msPlayed == 245_000)
    }

    /// Only the device that opened an event ever writes that id, so this settles no
    /// conflict — it decides which copy is more complete. Equal is not more.
    @Test("outcome ordering is by when the listen ended")
    func playEventOutcomeOrdering() {
        let started = PlayEvent(id: "e1", jellyfinId: "t1", contentKey: "k1",
                                startedAt: 5_000, originDevice: "mac")
        var finished = started
        finished.endedAt = 250_000
        var later = started
        later.endedAt = 260_000

        #expect(InboundApplier.isMoreFinished(finished, than: started))
        #expect(!InboundApplier.isMoreFinished(started, than: finished))
        #expect(InboundApplier.isMoreFinished(later, than: finished))
        #expect(!InboundApplier.isMoreFinished(finished, than: later))
        // Both unfinished, and both finished at the same instant, are both "no change".
        #expect(!InboundApplier.isMoreFinished(started, than: started))
        #expect(!InboundApplier.isMoreFinished(finished, than: finished))
    }

    @Test("a delete aimed at history is quarantined rather than obeyed")
    func playEventDelete() throws {
        let store = try store()
        let event = PlayEvent(id: "e1", jellyfinId: "t1", contentKey: "k1", startedAt: 5_000, originDevice: "mac")
        let op = try Wire.pulled(.playEvent, event, entityId: "e1", operation: .delete, seq: 1)

        #expect(try store.applyOne(op).quarantinedInbound == 1)
        #expect(try store.read { try PlayEvent.fetchCount($0) } == 0)
    }

    // MARK: - Queue state

    @Test("a queue row is keyed by its device, not by a uuid")
    func queueState() throws {
        let store = try store()
        let state = QueueState(deviceId: "mac", deviceName: "Studio", trackIds: ["a", "b"],
                               position: 1, elapsedMs: 500, updatedAt: 5_000)
        #expect(try store.applyOne(try Wire.pulled(.queueState, state, entityId: "mac", seq: 1)).applied == 1)

        let resumable = try store.resumableQueues(now: 5_000, within: .max)
        #expect(resumable.map(\.deviceId) == ["mac"])
        #expect(resumable[0].trackIdList == ["a", "b"])
    }

    @Test("an older queue row does not overwrite a newer one")
    func queueStateLWW() throws {
        let store = try store()
        let newer = QueueState(deviceId: "mac", deviceName: "Studio", trackIds: ["new"],
                               position: 0, elapsedMs: 0, updatedAt: 9_000)
        try store.applyOne(try Wire.pulled(.queueState, newer, entityId: "mac", seq: 1))

        let older = QueueState(deviceId: "mac", deviceName: "Studio", trackIds: ["old"],
                               position: 0, elapsedMs: 0, updatedAt: 1_000)
        #expect(try store.applyOne(try Wire.pulled(.queueState, older, entityId: "mac", seq: 2)).ignoredStale == 1)
        #expect(try store.read { try QueueState.fetchOne($0, key: "mac") }?.trackIdList == ["new"])
    }

    @Test("a queue row with a mismatched device is quarantined")
    func queueStateIdentity() throws {
        let store = try store()
        let state = QueueState(deviceId: "mac", deviceName: "Studio", trackIds: ["a"],
                               position: 0, elapsedMs: 0, updatedAt: 1_000)
        let op = try Wire.pulled(.queueState, state, entityId: "ipad", seq: 1)
        #expect(try store.applyOne(op).quarantinedInbound == 1)
        #expect(try store.read { try QueueState.fetchCount($0) } == 0)
    }

    // MARK: - Ops this build cannot apply

    /// A newer client may sync an entity that did not exist when this one shipped.
    @Test("an unknown entity is quarantined, not crashed on")
    func unknownEntity() throws {
        let store = try store()
        let op = Wire.pulledRaw(entity: "downloads", entityId: "d1", payload: .object(["id": .string("d1")]), seq: 1)
        let report = try store.applyOne(op)
        #expect(report.quarantinedInbound == 1)
        #expect(try store.quarantinedOps().first?.reason.contains("downloads") == true)
    }

    /// The payload is the only copy: the cursor has moved past it, so the server
    /// will not offer it again and a later build could replay it from here.
    @Test("a quarantined inbound op keeps its payload and its direction")
    func quarantineKeepsEvidence() throws {
        let store = try store()
        let op = Wire.pulledRaw(entity: "downloads", entityId: "d1",
                                payload: .object(["id": .string("d1"), "size": .int(42)]), seq: 1)
        try store.applyOne(op)

        let quarantined = try #require(try store.quarantinedOps().first)
        #expect(quarantined.syncDirection == .inbound)
        #expect(quarantined.entity == "downloads")
        #expect(quarantined.payload.contains("\"size\":42"))
    }

    @Test("a payload that does not decode into the local row is quarantined")
    func undecodablePayload() throws {
        let store = try store()
        // `name` is not optional, and no default can honestly stand in for it.
        let op = Wire.pulledRaw(
            entity: SyncEntity.playlist.wireName,
            entityId: "list-1",
            payload: .object(["id": .string("list-1"), "updatedAt": .int(1), "deleted": .bool(false),
                              "originDevice": .string("mac"), "sortIndex": .string("V")]),
            seq: 1
        )
        #expect(try store.applyOne(op).quarantinedInbound == 1)
        #expect(try storedPlaylist(store) == nil)
    }

    /// The common case for a newer client, and it is not an error: unknown keys are
    /// ignored, so an added column decodes and is simply absent from this device's
    /// copy.
    @Test("a newer client's extra column applies rather than quarantining")
    func extraColumnApplies() throws {
        let store = try store()
        var fields = try #require(try Wire.payload(makePlaylist(updatedAt: 5_000, device: "mac")).objectValue)
        fields["colourTheme"] = .string("dusk")
        let op = Wire.pulledRaw(entity: SyncEntity.playlist.wireName, entityId: "list-1",
                                payload: .object(fields), seq: 1)

        #expect(try store.applyOne(op).applied == 1)
        #expect(try storedPlaylist(store)?.name == "Late Night")
    }

    @Test("an op that disagrees with its own payload is quarantined")
    func identityMismatch() throws {
        let store = try store()
        let op = try Wire.pulled(
            .playlist, makePlaylist(id: "list-1", updatedAt: 1_000, device: "mac"),
            entityId: "list-2", seq: 1
        )
        #expect(try store.applyOne(op).quarantinedInbound == 1)
        #expect(try store.read { try Playlist.fetchCount($0) } == 0)
    }

    @Test("a payload that is not an object is quarantined")
    func payloadNotAnObject() throws {
        let store = try store()
        let op = Wire.pulledRaw(entity: SyncEntity.playlist.wireName, entityId: "list-1",
                                payload: .array([.string("nope")]), seq: 1)
        #expect(try store.applyOne(op).quarantinedInbound == 1)
    }

    @Test("an operation the server would not have accepted is quarantined")
    func unknownOperation() throws {
        let store = try store()
        var op = try Wire.pulled(.playlist, makePlaylist(updatedAt: 1, device: "mac"), entityId: "list-1", seq: 1)
        op = Wire.pulledRaw(entity: op.entity, entityId: op.entityId, payload: op.payload,
                            operation: "UPSERT", seq: 1)
        #expect(try store.applyOne(op).quarantinedInbound == 1)
    }

    /// One bad op must not abandon the batch around it.
    @Test("a bad op is quarantined and the rest of the batch still lands")
    func badOpDoesNotStopTheBatch() throws {
        let store = try store()
        let batch = [
            try Wire.pulled(.playlist, makePlaylist(id: "a", updatedAt: 1_000, device: "mac"), entityId: "a", seq: 1),
            Wire.pulledRaw(entity: "downloads", entityId: "d1", payload: .object(["id": .string("d1")]), seq: 2),
            try Wire.pulled(.playlist, makePlaylist(id: "b", updatedAt: 1_000, device: "mac"), entityId: "b", seq: 3)
        ]
        let report = try store.apply(batch, advancingTo: PullCursor(3), policy: .default, now: 5_000)

        #expect(report.applied == 2)
        #expect(report.quarantinedInbound == 1)
        #expect(try store.read { try Playlist.fetchCount($0) } == 2)
        #expect(try store.pullCursor() == PullCursor(3))
    }

    // MARK: - Clock skew

    /// A device whose clock says 2099 would win every conflict it ever entered, and
    /// nothing done on any other device could take the row back.
    @Test("a timestamp impossibly far ahead of the server is pulled back")
    func clockSkewCorrected() throws {
        let store = try store()
        try store.record(makePlaylist(id: "list-1", name: "Local", updatedAt: 0, device: "aaa"), at: 1_000_000)

        let broken = makePlaylist(id: "list-1", name: "Broken clock", updatedAt: 4_000_000_000_000, device: "mac")
        let op = try Wire.pulled(.playlist, broken, entityId: "list-1", createdAt: 4_000_000_000_000,
                                 seq: 1, receivedAt: 500_000)
        // This device's clock, and it has to be no earlier than its own last write: a
        // device that believes the time is before its own rows were written is one whose
        // clock has been *corrected*, and the merge reads those rows as undatable.
        let report = try store.applyOne(op, now: 1_000_000)

        #expect(report.clockSkewed == 1)
        // Corrected to the receipt time, which is older than the local row — so the
        // broken clock does not get to win.
        #expect(report.ignoredStale == 1)
        #expect(try storedPlaylist(store)?.name == "Local")
    }

    @Test("a corrected row is stored with the corrected time, not the claimed one")
    func correctedTimeIsStored() throws {
        let store = try store()
        let broken = makePlaylist(id: "list-1", updatedAt: 4_000_000_000_000, device: "mac")
        let op = try Wire.pulled(.playlist, broken, entityId: "list-1", createdAt: 4_000_000_000_000,
                                 seq: 1, receivedAt: 500_000)
        #expect(try store.applyOne(op).applied == 1)
        #expect(try storedPlaylist(store)?.updatedAt == 500_000)
    }

    /// An op written offline and pushed days later is normal, and its timestamp is
    /// legitimately far in the past. Correcting that would destroy the ordering the
    /// whole design rests on.
    @Test("an old timestamp is never corrected")
    func pastTimestampsAreLeftAlone() throws {
        let store = try store()
        let old = makePlaylist(id: "list-1", updatedAt: 1_000, device: "mac")
        let op = try Wire.pulled(.playlist, old, entityId: "list-1", createdAt: 1_000,
                                 seq: 1, receivedAt: 900_000_000)
        let report = try store.applyOne(op)
        #expect(report.clockSkewed == 0)
        #expect(try storedPlaylist(store)?.updatedAt == 1_000)
    }

    @Test("ordinary drift inside the tolerance is not treated as a broken clock")
    func toleranceBand() {
        let tolerance = SyncPolicy.default.clockSkewToleranceMs
        func credible(_ timestamp: Millis, receivedAt: Millis = 1_000, now: Millis = 1_000) -> Bool {
            InboundApplier.isCredible(timestamp, receivedAt: receivedAt, now: now, tolerance: tolerance)
        }
        #expect(credible(1_000 + tolerance))
        #expect(!credible(1_001 + tolerance))
        // Nothing overflows on a timestamp near the end of Int64.
        #expect(credible(.max, receivedAt: .max, now: .max))
    }

    /// The check that stops a *server* clock from being mistaken for a client one.
    /// Ahead of one reference is ordinary; ahead of both is a broken clock.
    @Test("a timestamp ahead of only one reference is still believed")
    func credibilityNeedsBothReferences() {
        let tolerance = SyncPolicy.default.clockSkewToleranceMs
        let far: Millis = 10_000_000

        // A server hours behind its devices: every write is ahead of `receivedAt` and
        // none of them is ahead of the device reading it.
        #expect(InboundApplier.isCredible(far, receivedAt: far - 3_600_000, now: far, tolerance: tolerance))
        // A device hours ahead of everything: ahead of both, so it is not believed.
        #expect(!InboundApplier.isCredible(
            far + 3_600_000, receivedAt: far, now: far, tolerance: tolerance
        ))
    }

    /// The other half of the same rule. A local row stamped by a clock that has since
    /// been corrected sits in the future of this device's own clock *and* of the
    /// server's, which means there is no order to compute against it at all — so it
    /// loses to a copy the server witnessed. Without this the poison is on the row
    /// rather than the clock, fixing the clock changes nothing, and no edit made
    /// anywhere else can ever take that row back.
    @Test("a local row this device can no longer date loses to an inbound one")
    func undatableLocalRowIsRepaired() throws {
        let store = try store()
        // Written while the clock said 2096, and the clock has since been put right.
        try store.record(makePlaylist(id: "list-1", name: "Stamped in 2096", updatedAt: 0, device: "phone"),
                         at: 4_000_000_000_000)

        let op = try Wire.pulled(
            .playlist, makePlaylist(id: "list-1", name: "Corrected", updatedAt: 1_000_000, device: "mac"),
            entityId: "list-1", seq: 1, receivedAt: 1_100_000
        )
        let report = try store.applyOne(op, now: 1_200_000)

        #expect(report.applied == 1)
        // Nothing was rewritten on the way in: the inbound row was perfectly datable.
        #expect(report.clockSkewed == 0)
        #expect(try storedPlaylist(store)?.name == "Corrected")
        #expect(try storedPlaylist(store)?.updatedAt == 1_000_000)
    }

    /// And while the clock is still wrong, the device keeps its own row — its clock is
    /// the second reference, so its writes look ordinary to it. Pinned so the repair
    /// above cannot be mistaken for "inbound always wins".
    @Test("a device whose clock is still wrong keeps its own row")
    func brokenClockKeepsItsOwnRow() throws {
        let store = try store()
        try store.record(makePlaylist(id: "list-1", name: "Stamped in 2096", updatedAt: 0, device: "phone"),
                         at: 4_000_000_000_000)

        let op = try Wire.pulled(
            .playlist, makePlaylist(id: "list-1", name: "Corrected", updatedAt: 1_000_000, device: "mac"),
            entityId: "list-1", seq: 1, receivedAt: 1_100_000
        )
        // The device still believes it is 2096.
        let report = try store.applyOne(op, now: 4_000_000_000_000)

        #expect(report.ignoredStale == 1)
        #expect(try storedPlaylist(store)?.name == "Stamped in 2096")
    }

    /// A play event wins no conflicts, and `startedAt` is a claim about when
    /// listening happened rather than something to rewrite on one comparison.
    @Test("a skewed play event is counted but not rewritten")
    func playEventSkew() throws {
        let store = try store()
        let event = PlayEvent(id: "e1", jellyfinId: "t1", contentKey: "k1",
                              startedAt: 4_000_000_000_000, originDevice: "mac")
        let op = try Wire.pulled(.playEvent, event, entityId: "e1",
                                 createdAt: 4_000_000_000_000, seq: 1, receivedAt: 500_000)
        let report = try store.applyOne(op)

        #expect(report.clockSkewed == 1)
        #expect(report.applied == 1)
        #expect(try store.read { try PlayEvent.fetchOne($0, key: "e1") }?.startedAt == 4_000_000_000_000)
    }

    // MARK: - The cursor

    @Test("the cursor advances with the batch it describes")
    func cursorMovesWithTheBatch() throws {
        let store = try store()
        #expect(try store.pullCursor() == nil)

        let op = try Wire.pulled(.playlist, makePlaylist(updatedAt: 1_000, device: "mac"), entityId: "list-1", seq: 77)
        let report = try store.apply([op], advancingTo: PullCursor(77), policy: .default, now: 5_000)

        #expect(report.cursor == PullCursor(77))
        #expect(try store.pullCursor() == PullCursor(77))
    }
}
