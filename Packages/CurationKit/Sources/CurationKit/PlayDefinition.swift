import Foundation

// What a play is, and what a skip is — in one place, in both languages this package
// needs them in.
//
// Jellyfin increments its PlayCount the moment playback starts, so a four-second skip
// counts there exactly as much as a full listen. Everything here exists to be honest
// where that is not.
//
// There are two consumers and they must never disagree. `PlayHistory` asks in SQL for
// the count printed beside a track; `SmartPlaylist` asks in SQL for the membership of
// "played more than five times". A threshold that differed between them by a second
// would make those two answers contradict each other on screen, and nothing about
// that presents as a bug worth investigating — it presents as the app being vaguely
// wrong about you. So the Swift classifier that *writes* the flags and the SQL that
// *recomputes* them are derived from the same named constants below, and there is a
// test standing on the exact boundary millisecond of each.

// MARK: - The outcome

/// What a finished play amounted to.
///
/// Three outcomes, not two: a play, a skip, and the middle where somebody listened to
/// a third of a track and moved on. That middle is deliberately counted as neither —
/// inflating it into a play makes play counts meaningless, and calling it a skip
/// slanders a track the listener was not actually rejecting.
public struct PlayOutcome: Hashable, Sendable {
    /// The track reached its end rather than being skipped away from.
    public let completed: Bool
    /// Qualifies as a play for counting purposes. Not a stored column — see
    /// `PlayDefinition` for why it is recomputed instead.
    public let countsAsPlay: Bool
    public let skipped: Bool
}

// MARK: - The Swift side

/// Where the line between a play and a skip falls.
///
/// The play rule is the long-standing scrobbling convention (Last.fm's, and near
/// enough everyone else's since): **half the track, or four minutes, whichever comes
/// first**. It is a pair of numbers rather than one because neither survives a real
/// library alone. A fixed threshold — "30 seconds is a play" — counts a 90-second punk
/// song after a third of it and a 12-minute krautrock track after 4% of it, so the
/// same listener behaviour scores wildly differently depending only on genre. A pure
/// fraction is no better at the long end: nobody sits through six minutes of a
/// twelve-minute track by accident, and demanding it would leave the entire long-form
/// half of a library permanently under-counted.
public enum PlayClassifier {
    /// The ceiling half of the rule. Four minutes of listening is a play however long
    /// the track is.
    public static let scrobbleCeilingMs = 4 * 60 * 1_000

    /// The fractional half of the rule. Both divisors are named because `PlayDefinition`
    /// interpolates them into the SQL that has to reach the same verdict; a literal in
    /// either place would let the two drift apart silently.
    public static let playDivisor = 2

    /// Below a fifth of a track, the listener rejected it. Set well under the play
    /// threshold on purpose: the gap between the two is the "neither" band, and a skip
    /// should mean an unambiguous one.
    public static let skipDivisor = 5

    /// A play needs at least this much listening, in milliseconds.
    ///
    /// Integer division rather than `* 0.5`, so the boundary is an exact millisecond a
    /// test can sit on and the SQL form can reproduce it digit for digit.
    ///
    /// An unknown duration falls back to the ceiling alone — the only half of the rule
    /// that does not need one. It errs towards under-counting rather than inventing a
    /// duration, and it is rare: the duration comes from the same track metadata the
    /// player needed in order to start.
    public static func playThreshold(trackDurationMs: Int?) -> Int {
        guard let duration = trackDurationMs, duration > 0 else { return scrobbleCeilingMs }
        return min(duration / playDivisor, scrobbleCeilingMs)
    }

    /// Below this much listening the track was skipped. With no duration, the same
    /// fifth is taken of the ceiling instead — 48 seconds — so the fallback stays
    /// derived from the rule rather than being a third invented number.
    ///
    /// A duration of zero routes here too. Taken literally it would make `msPlayed >= 0`
    /// a play, so every zero-length or unparsed file would score a play for having been
    /// looked at.
    public static func skipThreshold(trackDurationMs: Int?) -> Int {
        guard let duration = trackDurationMs, duration > 0 else { return scrobbleCeilingMs / skipDivisor }
        return duration / skipDivisor
    }

    /// How far short of the duration the reported elapsed time may land and still count
    /// as reaching the end.
    ///
    /// The player's last elapsed reading routinely stops a beat before the asset
    /// duration — the end-of-item notification fires while the final buffer is still
    /// draining — and treating a 300 ms shortfall as "did not finish" would file most
    /// complete listens under "neither". Generous on purpose: the only thing this costs
    /// is calling a 98%-finished listen finished, which it was.
    public static let completionToleranceMs = 1_500

    /// The smallest number of decided outcomes that makes a skip *rate* mean anything.
    ///
    /// One skip out of one play is not a 100% skip rate in any useful sense; it is a
    /// phone call. Five is the point where a single outcome moves the figure by 20
    /// points rather than 50 or 100, and it is reached inside a couple of sessions for
    /// anything the listener actually plays.
    public static let minimumSkipSample = 5

    /// Classifies a finished play.
    ///
    /// `completed` is an override for the player, which knows things the numbers do
    /// not: a gapless crossfade or trimmed trailing silence ends a track for real while
    /// leaving elapsed time short. Passing `nil` infers it from the figures.
    public static func classify(
        msPlayed: Int,
        trackDurationMs: Int?,
        completed: Bool? = nil
    ) -> PlayOutcome {
        let reachedEnd: Bool
        if let completed {
            reachedEnd = completed
        } else if let duration = trackDurationMs, duration > 0 {
            reachedEnd = msPlayed >= duration - completionToleranceMs
        } else {
            // No duration and no word from the player: there is nothing to have reached
            // the end *of*. Guessing here would invent plays out of silence.
            reachedEnd = false
        }

        let countsAsPlay = reachedEnd || msPlayed >= playThreshold(trackDurationMs: trackDurationMs)
        // The two thresholds cannot overlap — a fifth of a duration is always below half
        // of it, and 48s is below 4 min — so a listen can never satisfy both and the
        // three outcomes stay mutually exclusive without any extra guard.
        let skipped = !reachedEnd && msPlayed < skipThreshold(trackDurationMs: trackDurationMs)

        return PlayOutcome(completed: reachedEnd, countsAsPlay: countsAsPlay, skipped: skipped)
    }
}

// MARK: - The SQL side

/// `PlayClassifier`'s verdicts, expressed for SQLite.
///
/// **Why recompute at all, when the classifier already ran?** Because `playEvent` has
/// room for two booleans and there are three outcomes. `completed` and `skipped` can
/// say "finished" and "rejected", but the pair `(0, 0)` cannot distinguish "played
/// enough to count" from the neither-band from an event that was never finished at
/// all. Adding a third column would change the synced payload of an append-only table
/// to store something derivable from what is already in it.
///
/// **Why consult the stored flags at all, when the thresholds can be recomputed?**
/// Because the classifier ran with the duration the *player* had, and this SQL runs
/// with the duration the *local track cache* has, and those can disagree — a stale
/// cache row, a different encode, a rescan in flight. When they disagree the player
/// was right: it had the actual asset open. So a stored verdict is honoured where it
/// is decisive, and the thresholds only decide the cases the flags leave open.
///
/// That is also what makes these fragments correct for events the classifier never
/// touched — imported history, and rows arriving from a device running an older build
/// — which carry `(0, 0)` and must still be judged on their numbers.
///
/// The duration is read through a LEFT join to the `track` cache, so a missing row
/// falls back to the duration-free half of the rule rather than dropping the event: an
/// uncached track listened to for four minutes still counts, instead of vanishing
/// because the library scan had not run yet.
enum PlayDefinition {
    /// `MIN` here is SQLite's two-argument *scalar* minimum, not the aggregate — the
    /// two are told apart by arity alone, and these fragments are routinely nested
    /// inside a real `SUM(...)` or `MAX(...)`. SQLite divides integers the way Swift
    /// does, so interpolating the same constants reproduces
    /// `PlayClassifier.playThreshold` to the millisecond rather than merely close to it.
    ///
    /// The `CASE` is what keeps NULL out of the arithmetic. Spelling the rule as
    /// `msPlayed * 2 >= durationMs OR msPlayed >= ceiling` is algebraically the same
    /// thing and looks tidier, but it quietly changes the answer for a cached duration
    /// of exactly `0`: `msPlayed * 2 >= 0` is true for every event, so a library of
    /// zero-length or unparsed files would score a play apiece for having been looked
    /// at. `PlayClassifier` routes a zero duration to the ceiling, and so does this.
    static func playThreshold(track: String) -> String {
        """
        CASE WHEN \(track).durationMs IS NULL OR \(track).durationMs <= 0
             THEN \(PlayClassifier.scrobbleCeilingMs)
             ELSE MIN(\(track).durationMs / \(PlayClassifier.playDivisor), \(PlayClassifier.scrobbleCeilingMs)) END
        """
    }

    /// The fallback is `PlayClassifier`'s own — a fifth of the ceiling, computed here
    /// rather than written out, so the number cannot be edited in one language only.
    static func skipThreshold(track: String) -> String {
        """
        CASE WHEN \(track).durationMs IS NULL OR \(track).durationMs <= 0
             THEN \(PlayClassifier.scrobbleCeilingMs / PlayClassifier.skipDivisor)
             ELSE \(track).durationMs / \(PlayClassifier.skipDivisor) END
        """
    }

    /// An event that was opened and never closed: `beginPlay` wrote it, `finishPlay`
    /// never ran, because iOS killed a backgrounded audio app mid-track. It is the
    /// normal way a long listen ends on a phone, and it carries `msPlayed = 0`,
    /// `completed = 0`, `skipped = 0` — figures that describe nothing that happened.
    ///
    /// Judging one by its numbers would read every killed listen as a zero-millisecond
    /// skip, and the tracks it happens to are the *long* ones, so the app would
    /// systematically record the listener rejecting exactly the albums they sat
    /// through. Its outcome is unknown, and unknown is neither. `endedAt` is what says
    /// so: every path that finishes an event sets it, and only `beginPlay` leaves it
    /// null.
    static func hasOutcome(event: String = "e") -> String { "\(event).endedAt IS NOT NULL" }

    /// Counts towards a play count.
    ///
    /// `skipped = 1` vetoes the threshold arm: that flag is the player's verdict, made
    /// with the real duration, and it is the whole reason a stale cache cannot inflate
    /// a rejected track into a played one. A stored `completed = 1` needs no such
    /// guarding and no `endedAt` — it is already an explicit verdict, and the only
    /// thing that could overturn it is arithmetic on a duration this side trusts less.
    static func countsAsPlay(event: String = "e", track: String) -> String {
        """
        (\(event).completed = 1
         OR (\(event).skipped = 0 AND \(hasOutcome(event: event))
             AND \(event).msPlayed >= \(playThreshold(track: track))))
        """
    }

    /// Counts towards a skip count.
    ///
    /// Disjoint from `countsAsPlay` by construction, which is the property that makes
    /// the two counts safe to display side by side. A play arrives either through
    /// `completed = 1`, which this excludes outright, or through a threshold that is
    /// always at or above the skip threshold — half a duration is never below a fifth
    /// of it, and four minutes is never below forty-eight seconds — so no event can
    /// satisfy both.
    static func countsAsSkip(event: String = "e", track: String) -> String {
        """
        (\(event).completed = 0
         AND (\(event).skipped = 1
              OR (\(hasOutcome(event: event)) AND \(event).msPlayed < \(skipThreshold(track: track)))))
        """
    }
}
