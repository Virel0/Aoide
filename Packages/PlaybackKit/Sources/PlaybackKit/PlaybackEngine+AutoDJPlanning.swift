#if os(iOS)

import Foundation

// MARK: - Auto DJ: what the set does with a record

extension PlaybackEngine {
    /// Everything the decks need about a track, or nothing if it cannot be one.
    func djItem(for track: Track) -> DJItem? {
        guard let url = localFileResolver?(track) else { return nil }
        return DJItem(
            url: url,
            sound: track.sound ?? soundResolver?(track),
            gainDb: loudnessResolver?(track),
            grid: beatGridResolver?(track),
            exitSeconds: programmedExit(for: track).map { $0 / 1_000 }
        )
    }

    /// Where the set leaves a record, in milliseconds, when one is being
    /// programmed — which is whenever Auto DJ has the record.
    ///
    /// Not only how one record becomes the next, but when: a room hears the
    /// first hook and moves on, and a record played to its last chorus and
    /// fade-out is the tell of a playlist rather than a set. See
    /// ``SetProgrammer``. Somebody who wants whole songs has Crossfade.
    func programmedExit(for track: Track) -> Double? {
        guard isAutoDJing,
              let grid = beatGridResolver?(track),
              let arrangement = arrangementResolver?(track),
              let duration = (track.sound ?? soundResolver?(track))?.soundEnd ?? track.duration
        else { return nil }
        let durationMs = duration.seconds * 1_000
        let early = SetProgrammer.exitMs(grid: grid, arrangement: arrangement, durationMs: durationMs)
        // The early exit is for a mix. When what follows cannot be mixed in
        // — an echo-out, an escape — the set plays to the end of the last
        // hook instead: nothing arrives under this record, so nothing is
        // gained by leaving it early. Decided against the record actually
        // queued next, and remembered per pair: this is asked sixty times a
        // second.
        guard let next = nextTrack(after: track), let early else { return early }
        let pairKey = "\(track.id)>\(next.id)"
        if let known = exitDecisions[pairKey] { return known }
        // Undecided until the next record can be read: its grid and
        // arrangement may still be on their way, and "unread" is not "cannot
        // be mixed".
        guard let nextGrid = beatGridResolver?(next), let nextArrangement = arrangementResolver?(next) else { return early }
        let mixable = DJPlanner.plan(
            outgoing: grid, incoming: nextGrid,
            outgoingArrangement: arrangement, incomingArrangement: nextArrangement,
            outgoingExitMs: early
        ) != nil
        let decided = mixable ? early : (SetProgrammer.lateExitMs(grid: grid, arrangement: arrangement, durationMs: durationMs) ?? early)
        exitDecisions[pairKey] = decided
        return decided
    }

    private func nextTrack(after track: Track) -> Track? {
        let window = queue.renderWindow(count: 2)
        guard window.count == 2, window[0].track.id == track.id, window[1].entryId != window[0].entryId else { return nil }
        return window[1].track
    }

    /// The mix from one record into another, if there is one.
    func plannedMix(from outgoing: Track, to incoming: Track, position: Duration) -> DJTransition? {
        guard isAutoDJing,
              let outgoingGrid = beatGridResolver?(outgoing),
              let incomingGrid = beatGridResolver?(incoming),
              localFileResolver?(incoming) != nil
        else { return nil }
        // Nothing may be booked behind the playhead, and the booking itself needs
        // a moment: the file has to be opened and the deck spun up.
        return DJPlanner.plan(
            outgoing: outgoingGrid,
            incoming: incomingGrid,
            notBeforeMs: position.seconds * 1000 + 1_000,
            outgoingArrangement: arrangementResolver?(outgoing),
            incomingArrangement: arrangementResolver?(incoming),
            outgoingExitsMs: programmedExits(for: outgoing)
        )
    }

    /// Every place the set would accept leaving `track`, best first — the
    /// planner chooses among them for the pair. Empty when no set is being
    /// programmed, which the planner reads as the record's own mix-out.
    private func programmedExits(for track: Track) -> [Double] {
        guard isAutoDJing,
              let grid = beatGridResolver?(track),
              let arrangement = arrangementResolver?(track),
              let duration = (track.sound ?? soundResolver?(track))?.soundEnd ?? track.duration
        else { return [] }
        return SetProgrammer.exitCandidatesMs(grid: grid, arrangement: arrangement, durationMs: duration.seconds * 1_000)
    }

    /// The cut from one record into another, for a pair that has been read but
    /// cannot be mixed.
    func plannedCut(from outgoing: Track, to incoming: Track, position: Duration) -> DJTransition? {
        guard isAutoDJing,
              let outgoingGrid = beatGridResolver?(outgoing),
              let incomingGrid = beatGridResolver?(incoming),
              localFileResolver?(incoming) != nil
        else { return nil }
        return DJPlanner.planCut(
            outgoing: outgoingGrid,
            incoming: incomingGrid,
            notBeforeMs: position.seconds * 1000 + 1_000,
            outgoingArrangement: arrangementResolver?(outgoing),
            incomingArrangement: arrangementResolver?(incoming),
            outgoingExitMs: programmedExit(for: outgoing),
            outgoingLyricLinesMs: lyricLinesResolver?(outgoing),
            incomingLyricLinesMs: lyricLinesResolver?(incoming)
        )
    }
}

#endif
