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
        guard let mixOut = grid.mixOutMs else { return nil }
        let target = targetMs(durationMs: durationMs)
        let floor = durationMs * earliestExit

        // A boundary where the section before it was a drop and the one after
        // is quieter — the end of a hook.
        var candidates: [Double] = []
        for (before, after) in zip(arrangement.sections, arrangement.sections.dropFirst()) {
            guard before.kind == .drop, [.breakdown, .outro, .build, .unknown].contains(after.kind),
                  after.energy < before.energy
            else { continue }
            candidates.append(after.startMs)
        }

        let usable = candidates.filter { $0 >= floor && $0 <= mixOut }
        guard let chosen = usable.min(by: { abs($0 - target) < abs($1 - target) }) else { return nil }

        // Onto the phrase line at or before it, then the bar line; the section
        // boundary is already on a bar, but the phrase is what a DJ counts in.
        let barMs = grid.barMs(at: chosen) ?? 0
        return arrangement.phraseStart(atOrBefore: chosen, barMs: barMs)
            ?? grid.downbeat(atOrBefore: chosen)
            ?? chosen
    }
}
