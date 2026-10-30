import Foundation
import GRDB

/// The limits that keep queue persistence from being expensive, and the reasoning
/// for each number. They live here rather than as literals at the call site because
/// the caller has to be able to see what it is being charged for.
public enum QueuePolicy {
    /// How long another device's queue stays worth offering as a resume.
    ///
    /// A resume prompt is a claim about intent, and the claim decays: finishing the
    /// commute's album at your desk is continuity, being asked on Thursday whether
    /// you want Monday's queue back is a question about something you no longer
    /// remember queuing, and answering it wrong costs you whatever you were about to
    /// play. A day covers the case this feature exists for — evening on the phone,
    /// next morning in the car — and excludes the rest.
    ///
    /// Note this is a rule about what to *offer*. Rows are never trimmed by age: a
    /// device that has been offline for a week should still sync the state it has.
    public static let resumeWindow: Millis = 24 * 60 * 60 * 1000

    /// The most track ids ever written to a queue row.
    ///
    /// Shuffling a whole library produces a queue of thousands of ids; at ~35 bytes
    /// each that is a six-figure-byte JSON string, rewritten every few seconds of
    /// playback and pushed as an op each time. A cap is not optional at that size.
    public static let maxTracks = 500

    /// The most already-played tracks kept behind the current position.
    ///
    /// History is what gets sacrificed to `maxTracks`, and it is the right thing to
    /// sacrifice: its only job is making "previous track" work a few times, and on
    /// the device you resume *onto* it is worth nothing at all. Everything upcoming
    /// survives — the remaining 475 slots ahead are well over a day of continuous
    /// listening, so a truncated tail belongs to a generated queue that was never
    /// going to be reached in the session being resumed.
    public static let maxHistory = 25

    /// Elapsed time must move by more than this for a save to be worth doing.
    ///
    /// Playback moves it every second, and every save rewrites the whole track-id
    /// JSON *and* appends an op. The threshold is chosen from the read side: this
    /// row is only ever consumed to seek back to where you were, and resuming up to
    /// five seconds early is invisible next to the act of picking up another device
    /// and pressing play. Track changes and edits bypass it entirely — they move the
    /// index or the list, which is always worth a write.
    public static let elapsedThresholdMs = 5_000

    /// The slice of `trackIds` that is actually persisted, with `position` rebased
    /// into it.
    ///
    /// Exposed because a caller restoring a queue needs to know that the index it
    /// gets back is not the index it saved.
    public static func window(trackIds: [String], position: Int) -> (trackIds: [String], position: Int) {
        guard !trackIds.isEmpty else { return ([], 0) }

        // A position past the end means the queue ran out; restoring to the last
        // track is the only reading of that which produces something playable.
        let index = min(max(position, 0), trackIds.count - 1)
        guard trackIds.count > maxTracks else { return (trackIds, index) }

        // Slide the window back from the end when the position is near it, so the
        // cap is spent on history that at least exists rather than on slots past the
        // last track. This is what makes "everything upcoming survives" true right
        // to the end of a long queue.
        let start = min(max(0, index - maxHistory), trackIds.count - maxTracks)
        return (Array(trackIds[start..<(start + maxTracks)]), index - start)
    }
}

/// Queue persistence and the read side of cross-device resume.
///
/// `queueState` is the one syncable table that is not `Syncable`. It is keyed by
/// `deviceId`, has no `id` and no `deleted` column, and by construction only ever
/// gets overwritten by the device that owns it — so it cannot go through `record`.
/// The tempting fix is a retroactive `Syncable` conformance with `id` returning
/// `deviceId` and a computed `deleted` whose setter discards; that would make
/// `record(_:deleted:)` compile for this type and then silently not delete, and
/// would emit delete ops the schema has no column to represent. So the writes below
/// open the transaction themselves and put the row and its op inside it, which is
/// the property `record` exists to guarantee in the first place. `entityId` on those
/// ops is the device id, because that is this table's identity.
public extension CurationStore {
    /// This device's saved queue, for restoring on launch.
    ///
    /// A signed-out device keeps a row with an empty track list rather than no row —
    /// see `clearQueue` — so callers must check the list, not just for nil.
    func localQueue() throws -> QueueState? {
        try read { try QueueState.fetchOne($0, key: deviceId) }
    }

    /// Other devices' queues, most recently updated first.
    ///
    /// Queues older than `window`, and queues with nothing in them, are not offered.
    /// Pass `Millis.max` to ignore age.
    func resumableQueues(
        now: Millis = Date().millis,
        within window: Millis = QueuePolicy.resumeWindow
    ) throws -> [QueueState] {
        // `updatedAt` is the writing device's own clock, so a device running fast
        // looks more recent than it is and can sort above a queue that is genuinely
        // newer. That is the tolerable direction for this error to point — the
        // alternative is hiding a queue the user put down thirty seconds ago — and
        // a server-side receipt time is the real fix.
        let cutoff = window < now ? now - window : Millis.min
        return try read { db in
            try QueueState
                .filter(Column("deviceId") != deviceId)
                .filter(Column("updatedAt") >= cutoff)
                .order(Column("updatedAt").desc)
                .fetchAll(db)
        }
        // In SQL this would mean matching the encoder's exact output for an empty
        // array. There are only ever a handful of devices, so decode instead.
        .filter { !$0.trackIdList.isEmpty }
    }

    /// Upserts this device's queue row unconditionally.
    ///
    /// Returns what was actually stored, which is not always what was passed:
    /// `QueuePolicy.window` may have dropped played history and rebased `position`.
    @discardableResult
    func saveQueue(
        deviceName: String,
        trackIds: [String],
        position: Int,
        elapsedMs: Int,
        at now: Millis = Date().millis
    ) throws -> QueueState {
        let state = queueState(
            deviceName: deviceName,
            trackIds: trackIds,
            position: position,
            elapsedMs: elapsedMs,
            at: now
        )
        try writeQueue(state)
        return state
    }

    /// Upserts this device's queue row only if something meaningful moved, and
    /// reports whether it wrote.
    ///
    /// Meaningful means the track list, the index, or the device's name changed, or
    /// elapsed moved by more than `QueuePolicy.elapsedThresholdMs` in either
    /// direction — backwards counts, because a seek back is the one case where the
    /// stored value is not merely stale but wrong in a way the listener asked for.
    ///
    /// Deliberately not a timer: how often to *ask* is the player's business, and a
    /// timer owned in here would keep running through a paused track. This only
    /// promises that asking often is cheap.
    @discardableResult
    func saveQueueIfChanged(
        deviceName: String,
        trackIds: [String],
        position: Int,
        elapsedMs: Int,
        at now: Millis = Date().millis
    ) throws -> Bool {
        let candidate = queueState(
            deviceName: deviceName,
            trackIds: trackIds,
            position: position,
            elapsedMs: elapsedMs,
            at: now
        )

        guard let existing = try localQueue() else {
            // A player that has never played anything still ticks. Creating a row
            // and an op to record an empty queue nobody has yet is pure noise.
            guard !candidate.trackIdList.isEmpty else { return false }
            try writeQueue(candidate)
            return true
        }

        // Compared *after* windowing, so an edit past the cap — reordering track 900
        // of a shuffle — correctly registers as no change rather than forcing a
        // write that would store a byte-identical row.
        let unchanged = existing.trackIds == candidate.trackIds
            && existing.position == candidate.position
            && existing.deviceName == candidate.deviceName
            && abs(existing.elapsedMs - candidate.elapsedMs) <= QueuePolicy.elapsedThresholdMs
        if unchanged { return false }

        try writeQueue(candidate)
        return true
    }

    /// Empties this device's queue on sign-out. Reports whether there was one.
    ///
    /// An empty upsert rather than a `DELETE`, for the same reason the rest of the
    /// schema soft-deletes: a missing row is indistinguishable from a row never
    /// seen, so the other devices would keep offering this one's stale queue
    /// forever, and any of them could push it back. An empty list is a fact that
    /// travels. The device name is kept from the row being cleared — it is the only
    /// thing here that isn't the user's listening.
    @discardableResult
    func clearQueue(at now: Millis = Date().millis) throws -> Bool {
        guard let existing = try localQueue() else { return false }
        try writeQueue(QueueState(
            deviceId: deviceId,
            deviceName: existing.deviceName,
            trackIds: [],
            position: 0,
            elapsedMs: 0,
            updatedAt: now
        ))
        return true
    }

    private func queueState(
        deviceName: String,
        trackIds: [String],
        position: Int,
        elapsedMs: Int,
        at now: Millis
    ) -> QueueState {
        let window = QueuePolicy.window(trackIds: trackIds, position: position)
        return QueueState(
            deviceId: deviceId,
            deviceName: deviceName,
            trackIds: window.trackIds,
            position: window.position,
            // A negative elapsed reaches here from a player that reports before its
            // first tick; stored as-is it would make the resumed seek fail.
            elapsedMs: max(0, elapsedMs),
            updatedAt: now
        )
    }

    /// The row and its op, in one transaction — the invariant `record` enforces for
    /// every other table, restated here because this table cannot use it.
    private func writeQueue(_ state: QueueState) throws {
        let op = Op(
            entity: QueueState.databaseTableName,
            entityId: state.deviceId,
            operation: .upsert,
            payload: try Self.json(state),
            createdAt: state.updatedAt
        )
        try writeLocal { db in
            // Supersede this device's unpushed queue op instead of stacking another
            // one behind it. Queue state is a latest-value channel, not a history:
            // an older unsynced op for this device is certain to be overwritten by
            // this one the moment both land, so keeping it only inflates the push —
            // and at one save per few seconds of playback it inflates it without
            // bound. Already-synced ops are left alone; their opIds are what make a
            // server-side retry idempotent. If a push is in flight while this runs,
            // the ack for the dropped opId matches no row, which `markSynced`
            // tolerates, and the newer state goes out with the next push.
            try Op
                .filter(Column("entity") == QueueState.databaseTableName)
                .filter(Column("entityId") == state.deviceId)
                .filter(Column("synced") == false)
                .deleteAll(db)
            try state.save(db)
            try op.insert(db)
        }
    }

}
