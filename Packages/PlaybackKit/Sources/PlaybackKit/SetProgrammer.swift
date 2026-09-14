import Foundation

/// How much of a record a set plays, and where it leaves.
///
/// A radio edit is rarely used start to finish. On a dance floor the room hears
/// the first hook, often a verse and a chorus, a second chorus if it is landing
/// — forty to seventy per cent of a three-and-a-half-minute record, not fifteen
/// and not a hundred. A club track is ridden longer because the drop is the
/// point. What is trimmed is intros, last choruses and fade-outs.
///
/// This is what separates Auto DJ from Crossfade-plus-Infinity: not only *how*
/// one record becomes the next, but *when*. Somebody who wants the whole song
/// has the other two features; this one is for a room.
public enum SetProgrammer {
    /// Never leave before this much of a record has played. Under it the
    /// listener has not heard the song, only its beginning.
    public static let earliestExit = 0.4

    /// The share of a record a set aims to play.
    public static let targetShare = 0.6

    /// The least a set plays of anything, so a short record is not a montage.
    public static let minimumMs = 90_000.0

    /// And the most, so a long club record is ridden for its groove rather than
    /// for all eight minutes of it.
    public static let maximumMs = 300_000.0

    /// How much of a record of this length a set aims to play.
    public static func targetMs(durationMs: Double) -> Double {
        guard durationMs.isFinite, durationMs > 0 else { return 0 }
        return min(durationMs, min(maximumMs, max(minimumMs, durationMs * targetShare)))
    }

    /// Where to leave: the closest section boundary to the target at which a
    /// loud part *ends* — a drop into a breakdown or an outro — on a phrase
    /// line, no earlier than ``earliestExit`` and no later than the record's
    /// own mix-out point.
    ///
    /// Leaving out of a drop rather than into one is the whole craft of it:
    /// the room got the hook, and the next record arrives before the song
    /// starts winding itself down. When the arrangement offers no such
    /// boundary, the record's mix-out point stands and the set plays it out —
    /// which is what a record with no drop deserves.
    public static func exitMs(grid: BeatGrid, arrangement: Arrangement, durationMs: Double) -> Double? {
        exit(grid: grid, arrangement: arrangement, durationMs: durationMs, late: false)
    }

    /// Where to leave when the next record cannot be mixed in — an echo-out,
    /// which is an escape and not a mix. The play window exists for mixing:
    /// the room got the hook, and the next record arrives *under* this one
    /// before it winds down. An escape brings nothing in under anything, so
    /// there is no reason to leave early; the set plays to the end of the
    /// *last* hook instead, and escapes from there.
    public static func lateExitMs(grid: BeatGrid, arrangement: Arrangement, durationMs: Double) -> Double? {
        exit(grid: grid, arrangement: arrangement, durationMs: durationMs, late: true)
    }

    /// Every place the set could leave, best first: each end of a hook
    /// inside the window, on its line, ordered by closeness to the target.
    /// The planner tries them all against the next record and takes the one
    /// that mixes best — but only when it is clearly better than the first,
    /// which is the set's own choice. See ``DJPlanner/plan``.
    public static func exitCandidatesMs(grid: BeatGrid, arrangement: Arrangement, durationMs: Double) -> [Double] {
        guard let mixOut = grid.mixOutMs else { return [] }
        let target = targetMs(durationMs: durationMs)
        return hookEnds(grid: grid, arrangement: arrangement, durationMs: durationMs, mixOut: mixOut)
            .sorted { abs($0 - target) < abs($1 - target) }
    }

    private static func exit(grid: BeatGrid, arrangement: Arrangement, durationMs: Double, late: Bool) -> Double? {
        guard let mixOut = grid.mixOutMs else { return nil }
        let target = targetMs(durationMs: durationMs)
        let ends = hookEnds(grid: grid, arrangement: arrangement, durationMs: durationMs, mixOut: mixOut)
        return late ? ends.max() : ends.min(by: { abs($0 - target) < abs($1 - target) })
    }

    /// Each boundary where a drop ends into something quieter — the end of a
    /// hook — inside the window, on the phrase line if one is close and the
    /// bar line otherwise. Distinct, in record order.
    private static func hookEnds(grid: BeatGrid, arrangement: Arrangement, durationMs: Double, mixOut: Double) -> [Double] {
        let floor = durationMs * earliestExit
        var ends: [Double] = []
        for (before, after) in zip(arrangement.sections, arrangement.sections.dropFirst()) {
            guard before.kind == .drop, [.breakdown, .outro, .build, .unknown].contains(after.kind),
                  after.energy < before.energy,
                  after.startMs >= floor, after.startMs <= mixOut
            else { continue }
            // Onto the phrase line at or before it if one is close, else the
            // bar line. The boundary is where the hook ends; a phrase line
            // seven bars back is inside the hook, and leaving there is
            // leaving early.
            let barMs = grid.barMs(at: after.startMs) ?? 0
            let lined = arrangement.phraseLine(atOrBefore: after.startMs, barMs: barMs)
                ?? grid.downbeat(atOrBefore: after.startMs)
                ?? after.startMs
            if !ends.contains(lined) { ends.append(lined) }
        }
        return ends
    }
}
