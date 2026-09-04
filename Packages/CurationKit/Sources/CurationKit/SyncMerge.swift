import Foundation
import GRDB

/// Applies pulled ops to local rows.
///
/// **Nothing in here may write to `op`.** An inbound change that appends an outbound
/// op is a change this device claims as its own and pushes back; the other device
/// pulls it, applies it, pushes it back, and the two of them trade the same row
/// until one of them is switched off. That is the single worst failure available in
/// this file, and it is prevented structurally rather than by care: this type is
/// handed a `Database` and never a `CurationStore`, so `record` and `append` — the
/// only two functions in the package that write ops — are not in scope. The store's
/// own apply wrapper asserts the op count is unchanged, and a test holds the line.
///
/// ## Conflict resolution is per **row**, not per field
///
/// The design document specifies per-field last-writer-wins, and the wire format
/// cannot express it: a payload is a full row carrying exactly one `updated_at`, so
/// there is no way to know *which* field that timestamp belongs to. What is
/// implemented here is per-row LWW on `updatedAt`, with `originDevice` as a
/// deterministic tiebreak so two devices resolving the same pair independently reach
/// the same answer.
///
/// The cost is real and worth stating plainly: two devices editing different fields
/// of one playlist — one renames it, the other moves it to a folder — do not both
/// win. The later write replaces the row and the earlier edit is lost. Per-field
/// merging would need per-field timestamps inside the payload (`{"name": {"v": …,
/// "t": …}}` or a parallel map of column to timestamp), which is a payload format
/// change, and every client would have to write it before any client could rely on
/// it. Playlist *ordering* never enters this path at all — fractional indices mean
/// an insert or a move writes one row and concurrent ones do not conflict — which is
/// what makes per-row acceptable in practice.
struct InboundApplier {
    let policy: SyncPolicy
    let now: Millis
    var report = SyncReport()

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(policy: SyncPolicy, now: Millis) {
        self.policy = policy
        self.now = now
    }

    /// Applies one op, or quarantines it. Never throws for anything the op itself is
    /// guilty of — a single bad op must not abandon the rest of the batch.
    mutating func apply(_ op: PulledOp, in db: Database) throws {
        // Our own ops come back on every pull, and they are applied through this
        // path like anyone else's. Skipping rows whose deviceId matches ours was the
        // alternative and it is worse twice over: this path has to be idempotent
        // regardless — a push that times out and is retried lands twice — so reusing
        // it costs nothing, whereas a skip rule is a second code path that only ever
        // runs on our own data and can therefore be subtly wrong for a long time
        // without anybody noticing. And it does the wrong thing outright for a device
        // that was reinstalled and kept its id: its rows are gone locally, its ops
        // are still on the server, and a skip-by-device rule would refuse to restore
        // any of them.
        guard let entity = SyncEntity(wireName: op.entity) else {
            try quarantine(op, .unknownEntity(op.entity), in: db)
            return
        }
        guard let operation = Op.Kind(rawValue: op.operation) else {
            try quarantine(op, .unknownOperation(op.operation), in: db)
            return
        }
        guard let fields = op.payload.objectValue else {
            try quarantine(op, .payloadNotAnObject, in: db)
            return
        }
        guard let identity = fields[entity.identityKey]?.stringValue, identity == op.entityId else {
            try quarantine(
                op,
                .identityMismatch(
                    entityId: op.entityId,
                    payloadId: fields[entity.identityKey]?.stringValue
                ),
                in: db
            )
            return
        }
        // `queueState` has no `deleted` column and `playEvent` is append-only, so
        // neither can carry the flag; the check belongs to the tables that can.
        if operation == .delete, entity != .queueState, entity != .playEvent,
           fields["deleted"]?.isFlagSet != true {
            try quarantine(op, .deleteWithoutFlag, in: db)
            return
        }

        switch entity {
        case .playlist: try mergePlaylist(op, in: db)
        case .folder: try mergeFolder(op, in: db)
        case .playlistItem: try mergeItem(op, in: db)
        case .like: try mergeLike(op, in: db)
        case .trackFlags: try mergeTrackFlags(op, in: db)
        case .queueState: try mergeQueue(op, in: db)
        case .playEvent: try appendEvent(op, operation: operation, in: db)
        }
    }

    // MARK: - Per entity

    /// A delete is merged through the same path as an upsert, because it *is* an
    /// upsert — of a row whose `deleted` flag is set. One path means applying a
    /// delete twice is as harmless as applying an edit twice, and it means a delete
    /// loses to a later edit exactly the way any other stale write does.
    private mutating func mergePlaylist(_ op: PulledOp, in db: Database) throws {
        let existing = try Playlist.fetchOne(db, key: op.entityId)
        guard let row = try fieldMergedWinner(Playlist.self, op, existing: existing, in: db) else { return }
        // A local soft delete losing to a newer inbound edit un-deletes the playlist,
        // and that is the intended reading rather than an oversight: a delete is a
        // versioned write like any other, and the alternative — deletes always win —
        // makes a delete unrecoverable and lets a device that has been offline for a
        // week destroy work done since.
        //
        // Its items are separate rows and are merged on their own timestamps, so a
        // playlist revived this way comes back with whatever each item's own merge
        // decided — which for a delete-then-rename is an empty playlist, because
        // `deletePlaylist` stamped every item at the moment of the delete and only
        // the playlist row was touched afterwards. Per-row merging cannot express
        // "this edit was about the whole playlist"; see the type comment.
        try row.save(db)
        report.applied += 1
    }

    private mutating func mergeFolder(_ op: PulledOp, in db: Database) throws {
        let existing = try Folder.fetchOne(db, key: op.entityId)
        guard let row = try fieldMergedWinner(Folder.self, op, existing: existing, in: db) else { return }
        try row.save(db)
        report.applied += 1
    }

    private mutating func mergeItem(_ op: PulledOp, in db: Database) throws {
        let existing = try PlaylistItem.fetchOne(db, key: op.entityId)
        guard let row = try winner(PlaylistItem.self, op, existing: existing, in: db) else { return }

        // An item whose playlist we have never seen is stored anyway, not held back
        // and not quarantined. Ops arrive in commit order, so the usual cause is
        // simply that the playlist is in a later batch — and every query for items
        // filters by playlist id, so an orphan is invisible until its parent lands
        // rather than being wrong. Refusing it would turn a wait into permanent data
        // loss, since the cursor moves past either way. Counted so a sync that
        // produces a lot of them is visible.
        if try Playlist.fetchOne(db, key: row.playlistId) == nil {
            report.orphanedItems += 1
        }
        try row.save(db)
        report.applied += 1
    }

    /// Likes are the one table with an identity that is not its primary key: the
    /// schema has a unique index on `jellyfinId`, and two devices liking the same
    /// track offline mint two different row ids for it. Inserting the second one
    /// blindly is a constraint violation, which would roll back the whole batch
    /// rather than the one row.
    ///
    /// So the clash is resolved by the same comparison used everywhere else, on the
    /// two rows' own timestamps, and the loser is removed. That the removal is a hard
    /// delete without an op is safe here and only here: it is not a decision this
    /// device made, it is a deterministic function of two rows that every device also
    /// has, so every device reaches it independently and they converge without
    /// anybody announcing anything.
    private mutating func mergeLike(_ op: PulledOp, in db: Database) throws {
        let existing = try Like.fetchOne(db, key: op.entityId)
        guard let row = try winner(Like.self, op, existing: existing, in: db) else { return }

        let clash = try Like.filter(Column("jellyfinId") == row.jellyfinId).fetchOne(db)
        if let clash, clash.id != row.id {
            guard Self.incomingWins(
                incoming: (row.updatedAt, row.originDevice),
                existing: (clash.updatedAt, clash.originDevice)
            ) else {
                report.ignoredStale += 1
                return
            }
            _ = try Like.deleteOne(db, key: clash.id)
            report.supersededLikes += 1
        }
        try row.save(db)
        report.applied += 1
    }

    /// Per-field like a playlist, deduped by track like a like: two devices that
    /// each minted a row for the same track keep the newer row, and within one row
    /// each flag keeps its own latest write.
    private mutating func mergeTrackFlags(_ op: PulledOp, in db: Database) throws {
        let existing = try TrackFlags.fetchOne(db, key: op.entityId)
        guard let row = try fieldMergedWinner(TrackFlags.self, op, existing: existing, in: db) else { return }

        let clash = try TrackFlags.filter(Column("jellyfinId") == row.jellyfinId).fetchOne(db)
        if let clash, clash.id != row.id {
            guard Self.incomingWins(
                incoming: (row.updatedAt, row.originDevice),
                existing: (clash.updatedAt, clash.originDevice)
            ) else {
                report.ignoredStale += 1
                return
            }
            _ = try TrackFlags.deleteOne(db, key: clash.id)
        }
        try row.save(db)
        report.applied += 1
    }

    /// Keyed by device, so `entityId` is a device id rather than a UUID and there is
    /// no `deleted` column to read. A row for *this* device can arrive — another
    /// installation using the same id, or our own op coming back — and it goes
    /// through the same comparison; a device whose queue op is genuinely older does
    /// not get to overwrite what is playing now.
    private mutating func mergeQueue(_ op: PulledOp, in db: Database) throws {
        var incoming: QueueState
        do {
            incoming = try decodeRow(QueueState.self, from: op)
        } catch {
            try quarantine(op, .undecodablePayload("\(error)"), in: db)
            return
        }
        correctSkew(&incoming.updatedAt, receivedAt: op.receivedAt)

        if let existing = try QueueState.fetchOne(db, key: op.entityId) {
            guard Self.incomingWins(
                incoming: (incoming.updatedAt, incoming.originDevice),
                existing: (existing.updatedAt, existing.originDevice),
                existingIsDatable: isDatable(existing.updatedAt, receivedAt: op.receivedAt)
            ) else {
                report.ignoredStale += 1
                return
            }
        }
        try incoming.save(db)
        report.applied += 1
    }

    /// Insert, or take a *more finished* version of an event already here.
    ///
    /// History is append-only with one exception, and `beginPlay`/`finishPlay` is it:
    /// the row is written when playback starts, because iOS kills backgrounded audio
    /// apps during exactly the long plays, and filled in when it ends. A sync landing
    /// between the two is the normal case for a long play, so every other device
    /// receives the 0 ms "started, outcome unknown" version first and the outcome
    /// second. Plain insert-if-absent drops that second op, and the loss is silent and
    /// permanent — the device that did the listening ends up the only one whose play
    /// counts, skip rates and recaps are right.
    ///
    /// `endedAt` decides, rather than a timestamp anybody chose. Only the device that
    /// opened an event ever writes that id, so there is no conflict here to resolve,
    /// only the question of which copy is more complete — and completeness is monotone.
    private mutating func appendEvent(_ op: PulledOp, operation: Op.Kind, in db: Database) throws {
        guard operation == .upsert else {
            try quarantine(op, .appendOnlyDelete, in: db)
            return
        }
        let event: PlayEvent
        do {
            event = try decodeRow(PlayEvent.self, from: op)
        } catch {
            try quarantine(op, .undecodablePayload("\(error)"), in: db)
            return
        }
        // Counted but not corrected. A play event has no `updatedAt` and wins no
        // conflicts, so a wrong clock here cannot capture anybody else's row — and
        // `startedAt` is a claim about when listening happened, which is not ours to
        // rewrite on the strength of one arithmetic comparison.
        noteSkew(op.createdAt, receivedAt: op.receivedAt)

        if let existing = try PlayEvent.fetchOne(db, key: event.id) {
            guard Self.isMoreFinished(event, than: existing) else {
                report.ignoredDuplicate += 1
                return
            }
            // `save` rather than `update`, matching every other merge here: the row was
            // fetched inside this transaction so it cannot have gone, and a throw would
            // abandon the rest of the batch over a case that cannot happen.
            try event.save(db)
            report.applied += 1
            return
        }
        try event.insert(db)
        report.applied += 1
    }

    /// Whether `incoming` is a later stage of the same listen than `existing`.
    ///
    /// Deliberately strict on the equal case: two copies that ended at the same instant
    /// are the same copy, and treating them as an update would make every replayed
    /// batch report work it did not do.
    static func isMoreFinished(_ incoming: PlayEvent, than existing: PlayEvent) -> Bool {
        guard let incomingEnd = incoming.endedAt else { return false }
        guard let existingEnd = existing.endedAt else { return true }
        return incomingEnd > existingEnd
    }

    // MARK: - Merge mechanics

    /// Decodes the payload, corrects a broken clock, and resolves last-writer-wins.
    /// `nil` means there is nothing to store — the op was stale, or it was
    /// quarantined on the way through.
    /// The row-level winner, then each content field taken from whichever side
    /// changed it more recently.
    ///
    /// The row-level comparison still decides the metadata — `deleted`, `updatedAt`,
    /// `originDevice` — because those describe the write rather than any one field.
    /// The content is then merged on the individual stamps, so a rename on one device
    /// and a description edit on another both survive instead of the later sync
    /// erasing the earlier.
    ///
    /// Note the losing side still contributes: an incoming row that loses the row
    /// comparison may hold the newer copy of one field, and dropping it because the
    /// row as a whole is older is exactly the loss this exists to stop. So the stale
    /// path returns the merge rather than nothing whenever the merge differs from
    /// what is already stored.
    private mutating func fieldMergedWinner<R>(
        _ type: R.Type,
        _ op: PulledOp,
        existing: R?,
        in db: Database
    ) throws -> R? where R: Codable & FieldStamped & Equatable {
        var incoming: R
        do {
            incoming = try decodeRow(R.self, from: op)
        } catch {
            try quarantine(op, .undecodablePayload("\(error)"), in: db)
            return nil
        }

        correctSkew(&incoming.updatedAt, receivedAt: op.receivedAt)
        if var stamps = incoming.fieldUpdatedAt {
            let corrected = stamps.correctingSkew(
                credible: { isDatable($0, receivedAt: op.receivedAt) },
                to: op.receivedAt
            )
            if corrected { incoming.fieldUpdatedAt = stamps }
        }

        guard let existing else { return incoming }

        // A local row this device can no longer place in time forfeits whole. Its
        // field stamps come from the same unbelievable clock as its row timestamp, so
        // merging against them would let the broken row keep individual fields — and
        // the recovery this exists for is precisely that it stops keeping anything.
        let datable = isDatable(existing.updatedAt, receivedAt: op.receivedAt)
        guard datable else { return incoming }

        let incomingLeads = Self.incomingWins(
            incoming: (incoming.updatedAt, incoming.originDevice),
            existing: (existing.updatedAt, existing.originDevice),
            existingIsDatable: true
        )

        let merged = try FieldMerge.merged(
            incoming: incoming,
            existing: existing,
            metadataFrom: incomingLeads ? incoming : existing
        )

        // Nothing changed, so nothing is written — which is what keeps re-applying an
        // op idempotent, and keeps our own ops coming back down from touching a row.
        guard merged != existing else {
            report.ignoredStale += 1
            return nil
        }
        return merged
    }

    private mutating func winner<R: Syncable & Decodable>(
        _ type: R.Type,
        _ op: PulledOp,
        existing: R?,
        in db: Database
    ) throws -> R? {
        var incoming: R
        do {
            incoming = try decodeRow(R.self, from: op)
        } catch {
            // Two causes, and quarantine is right for both. A genuinely corrupt row
            // is unapplicable by definition. A newer client's row is *usually* fine —
            // unknown keys are ignored, so an added column decodes and is simply
            // dropped from this device's copy — and only lands here when a column
            // this build requires has gone missing or changed type, which is a real
            // incompatibility and not something to paper over with a default.
            try quarantine(op, .undecodablePayload("\(error)"), in: db)
            return nil
        }

        correctSkew(&incoming.updatedAt, receivedAt: op.receivedAt)

        guard let existing else { return incoming }
        guard Self.incomingWins(
            incoming: (incoming.updatedAt, incoming.originDevice),
            existing: (existing.updatedAt, existing.originDevice),
            existingIsDatable: isDatable(existing.updatedAt, receivedAt: op.receivedAt)
        ) else {
            report.ignoredStale += 1
            return nil
        }
        return incoming
    }

    /// Strictly greater, which is what makes the whole path idempotent: an op
    /// applied a second time compares equal to the row it wrote and loses, so it
    /// changes nothing. Same for our own ops coming back down.
    ///
    /// `originDevice` breaks a tie rather than the arrival order doing it, because
    /// every device must reach the same answer independently or they diverge and
    /// stay diverged. Which device wins is arbitrary; that it is the same one
    /// everywhere is not.
    ///
    /// `existingIsDatable` is false only for a local row this device can no longer
    /// place in time — see `isCredible`. There is no ordering to compute against a
    /// row with no usable date, and the inbound copy at least has a time the server
    /// witnessed, so it takes the row. This is what lets a device recover after its
    /// clock is fixed rather than sitting on a poisoned timestamp forever.
    static func incomingWins(
        incoming: (Millis, String),
        existing: (Millis, String),
        existingIsDatable: Bool = true
    ) -> Bool {
        guard existingIsDatable else { return true }
        return incoming.0 == existing.0 ? incoming.1 > existing.1 : incoming.0 > existing.0
    }

    /// Whether a timestamp is one this device can believe at all.
    ///
    /// A device with a badly wrong clock would otherwise win every conflict it ever
    /// entered, forever, and no amount of editing anywhere else could take a row back
    /// from it. So a timestamp far enough in the future is treated as a broken clock
    /// rather than a genuinely newer write.
    ///
    /// **Two references, and both must agree, because one of them is not trustworthy
    /// either.** Checking only against the server's `receivedAt` — which is what the
    /// contract suggests and what this used to do — asks "is the writer's clock ahead
    /// of the server's". That question cannot tell a fast client from a *slow server*,
    /// and the two need opposite treatment. A Jellyfin box on a NAS with no RTC, or a
    /// VM resumed from a snapshot, can sit hours behind: every device is then "ahead"
    /// of it, every inbound row gets dragged back to a receipt time older than the
    /// local copy it is being compared with, and every device rejects every other
    /// device's edits — permanently, silently, with the rows living in two different
    /// clock domains and nothing on screen to say so. That is a far likelier and far
    /// worse failure than the one the correction exists to prevent.
    ///
    /// Requiring the timestamp to be ahead of this device's own clock as well settles
    /// it. A slow server moves `receivedAt` and nothing else, so the second test fails
    /// and nothing is corrected; normal operation never reaches this code at all. A
    /// client genuinely stamping the year 2096 is ahead of both, on every device that
    /// receives it, so it is still caught.
    ///
    /// The offending device is the one case that cannot be fixed from here: its own
    /// clock is the second reference, so its own writes look fine to it and it keeps
    /// them. It stays out of step until the clock is corrected — and then its rows
    /// stop being datable by *its* new clock, `incomingWins` hands them to the next
    /// inbound copy, and it rejoins without anybody editing anything.
    static func isCredible(
        _ timestamp: Millis,
        receivedAt: Millis,
        now: Millis,
        tolerance: Millis
    ) -> Bool {
        !(isAhead(timestamp, of: receivedAt, by: tolerance) && isAhead(timestamp, of: now, by: tolerance))
    }

    /// Overflow is "not ahead": a reference near the end of `Int64` puts the ceiling
    /// past anything representable, and wrapping would invert the comparison.
    private static func isAhead(_ timestamp: Millis, of reference: Millis, by tolerance: Millis) -> Bool {
        let (ceiling, overflowed) = reference.addingReportingOverflow(tolerance)
        return !overflowed && timestamp > ceiling
    }

    /// Pulls an inbound timestamp back to the server's receipt time when it is not
    /// credible.
    ///
    /// `receivedAt` rather than this device's `now`, and that choice is what keeps the
    /// system convergent through a broken clock: it is a property of the op, identical
    /// on every device that pulls it, so every device corrects to the same number and
    /// they still agree afterwards. The corrected value is what gets *stored*, so the
    /// row leaves the broken clock's domain for good instead of being re-judged
    /// against a different op's receipt time on every future merge.
    private mutating func correctSkew(_ timestamp: inout Millis, receivedAt: Millis) {
        guard !isDatable(timestamp, receivedAt: receivedAt) else { return }
        timestamp = receivedAt
        report.clockSkewed += 1
    }

    private mutating func noteSkew(_ timestamp: Millis, receivedAt: Millis) {
        if !isDatable(timestamp, receivedAt: receivedAt) { report.clockSkewed += 1 }
    }

    private func isDatable(_ timestamp: Millis, receivedAt: Millis) -> Bool {
        Self.isCredible(
            timestamp,
            receivedAt: receivedAt,
            now: now,
            tolerance: policy.clockSkewToleranceMs
        )
    }

    /// Decodes a payload into a local row, tolerating flags spelled `1`/`0`.
    ///
    /// The tolerance is owed rather than generosity. `JSONValue.isFlagSet` reads both
    /// spellings on purpose — the contract writes the delete invariant as
    /// `deleted = 1`, after the SQLite column — so a payload from a peer that
    /// serialises its rows straight out of SQLite clears the delete gate above and
    /// then hits Foundation, which refuses a `Bool` from a JSON number. Without this
    /// the op is quarantined as undecodable *after* the flag check confirmed it was a
    /// delete, with the cursor already past it: the row stays alive here forever and
    /// the server never offers the deletion again. Same shape for `isSmart`, `liked`,
    /// `completed` and `skipped`, which lose the whole row rather than a flag.
    ///
    /// The mismatch names the key it choked on, so exactly that key is coerced —
    /// rather than a hardcoded list of flag columns, which would go stale the first
    /// time one is added and is wrong for a payload from a build that has more of them
    /// than this one. Top level only, since every syncable row is flat; a nested
    /// `deleted` belongs to something this build does not model. Each key is retried
    /// once, so the loop is bounded by the number of fields.
    private func decodeRow<R: Decodable>(_ type: R.Type, from op: PulledOp) throws -> R {
        var payload = op.payload
        var coerced: Set<String> = []
        while true {
            do {
                return try decoder.decode(R.self, from: encoder.encode(payload))
            } catch let error as DecodingError {
                guard
                    case .typeMismatch(let expected, let context) = error,
                    expected == Bool.self,
                    context.codingPath.count == 1,
                    var fields = payload.objectValue
                else { throw error }
                let key = context.codingPath[0].stringValue
                guard coerced.insert(key).inserted, case .int(let number)? = fields[key] else {
                    throw error
                }
                fields[key] = .bool(number != 0)
                payload = .object(fields)
            }
        }
    }

    private mutating func quarantine(_ op: PulledOp, _ fault: SyncFault, in db: Database) throws {
        let payload = (try? encoder.encode(op.payload)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        try QuarantinedOp(
            opId: op.opId,
            entity: op.entity,
            entityId: op.entityId,
            direction: .inbound,
            reason: fault.reason,
            payload: payload,
            quarantinedAt: now
        ).save(db)
        report.quarantinedInbound += 1
    }
}

// MARK: - Store

extension CurationStore {
    /// Applies a pulled batch and advances the pull cursor, in **one** transaction.
    ///
    /// The contract asks for the cursor to be stored after the batch has been
    /// applied, so that an interrupted sync replays rather than skips. Doing both in
    /// one transaction is the stronger version of that and costs nothing here: with
    /// two writes there is still a window — crash between them and the cursor names
    /// a batch that was never applied, which is precisely the ordering the rule
    /// exists to prevent, just narrower. Either the whole batch and its cursor land
    /// or neither does, and a replayed batch is harmless because every merge above
    /// is idempotent.
    func apply(
        _ ops: [PulledOp],
        advancingTo cursor: PullCursor,
        policy: SyncPolicy,
        now: Millis
    ) throws -> SyncReport {
        try writeLocal { db in
            #if DEBUG
            let opsBefore = try Op.fetchCount(db)
            #endif

            var applier = InboundApplier(policy: policy, now: now)
            for op in ops {
                try applier.apply(op, in: db)
            }
            try Self.writePullCursor(cursor, to: db)

            #if DEBUG
            // The ping-pong guard. If applying an inbound change ever queues an
            // outbound one, two devices trade the same row until one is switched
            // off, and the symptom — a playlist that keeps changing on its own — is
            // a long way from the cause. Cheap to check once per batch, and it fails
            // during development rather than in someone's library.
            let opsAfter = try Op.fetchCount(db)
            assert(
                opsAfter == opsBefore,
                "applying \(ops.count) inbound ops queued \(opsAfter - opsBefore) outbound ops"
            )
            #endif

            var report = applier.report
            report.pulled = ops.count
            report.cursor = cursor
            return report
        }
    }
}
