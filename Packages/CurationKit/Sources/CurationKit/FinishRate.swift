import Foundation
import GRDB

/// How often a listen actually reaches the end.
///
/// The number a music server cannot produce. Jellyfin counts a play the moment
/// audio starts, so a four-second skip counts there exactly as much as an album
/// side; this counts only the listens that finished, against the listens that
/// were decided either way.
///
/// The rules below are shared with the desktop app, which carries the same
/// arithmetic in `src/shared/aoide/finish-rate.ts`, and are the reason the two
/// can show one figure for one library.
public struct FinishCounts: Equatable, Sendable {
    /// Listens that reached a verdict — played through, or skipped. An event
    /// still open, or abandoned without an outcome, counts for nothing.
    public var starts: Int
    /// Of those, the ones that reached the end.
    public var completed: Int

    public init(starts: Int = 0, completed: Int = 0) {
        self.starts = starts
        self.completed = completed
    }

    public static func + (lhs: FinishCounts, rhs: FinishCounts) -> FinishCounts {
        FinishCounts(starts: lhs.starts + rhs.starts, completed: lhs.completed + rhs.completed)
    }
}

public enum FinishRate {
    /// Below this many decided listens the figure is noise and is not shown at
    /// all — one play out of one is not "100% finished".
    public static let minimumSample = 3

    /// The fraction finished, or nil when there is not enough to say.
    public static func rate(_ counts: FinishCounts) -> Double? {
        guard counts.starts >= minimumSample else { return nil }
        return Double(counts.completed) / Double(counts.starts)
    }

    /// The rate over a set of tracks.
    ///
    /// Sums the counts and then divides, rather than averaging each track's own
    /// rate: the mean over-weights a track heard once against one heard fifty
    /// times, and an album is one thing rather than twelve equal ones.
    public static func rate(over counts: some Sequence<FinishCounts>) -> Double? {
        rate(counts.reduce(FinishCounts(), +))
    }

    /// "78%", or nil when there is not enough history.
    public static func percentDescription(_ counts: FinishCounts) -> String? {
        guard let rate = rate(counts) else { return nil }
        return "\(Int((rate * 100).rounded()))%"
    }
}

public extension CurationStore {
    /// Finish counts per track. Every requested id comes back, at zero if it has
    /// no history, so a caller can sum without checking for gaps.
    func finishCounts(jellyfinIds: [String]) throws -> [String: FinishCounts] {
        guard !jellyfinIds.isEmpty else { return [:] }
        var found = Dictionary(uniqueKeysWithValues: jellyfinIds.map { ($0, FinishCounts()) })

        // Read out of the closure and merge here: the read body is `@Sendable`,
        // so it may not write to anything it captured.
        let measured: [(String, FinishCounts)] = try read { db in
            var rows: [(String, FinishCounts)] = []
            for chunk in stride(from: 0, to: jellyfinIds.count, by: HistorySQL.maxParameters) {
                let ids = Array(jellyfinIds[chunk..<min(chunk + HistorySQL.maxParameters, jellyfinIds.count)])
                let fetched = try Row.fetchAll(db, sql: """
                    SELECT jellyfinId,
                           COUNT(*) AS starts,
                           SUM(CASE WHEN completed = 1 THEN 1 ELSE 0 END) AS completed
                    FROM playEvent
                    WHERE endedAt IS NOT NULL
                      AND (completed = 1 OR skipped = 1)
                      AND jellyfinId IN (\(Self.placeholders(ids.count)))
                    GROUP BY jellyfinId
                    """, arguments: StatementArguments(ids))
                for row in fetched {
                    rows.append((row["jellyfinId"], FinishCounts(starts: row["starts"], completed: row["completed"])))
                }
            }
            return rows
        }
        for (id, counts) in measured { found[id] = counts }
        return found
    }

    /// The finish rate over a set of tracks, in one pass.
    func finishRate(jellyfinIds: [String]) throws -> Double? {
        FinishRate.rate(over: try finishCounts(jellyfinIds: jellyfinIds).values)
    }
}
