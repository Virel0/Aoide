import Foundation

// MARK: - Wire format

/// `GET /api/v1/music/tracks/{id}/lyrics`: lines with their starts for synced
/// lyrics (an `.lrc` beside the track, its tags, or LRCLIB on the server), without
/// for plain ones. Melete has no per-word timings.
struct LyricsDocument: Decodable, Sendable {
    struct Line: Decodable, Sendable {
        let startSeconds: Double?
        let text: String
    }
    let lines: [Line]
}

// MARK: - Domain model

/// One timed word within a line. Only present for enhanced-LRC sources.
public struct LyricWord: Hashable, Sendable, Codable, Identifiable {
    public let id: Int
    public let text: String
    public let start: Duration
    /// When this word's highlight should finish sweeping.
    public let sweepEnd: Duration
}

public struct LyricLine: Hashable, Sendable, Codable, Identifiable {
    public let id: Int
    public let text: String
    /// `nil` when the source carried no timings — the line can still be displayed,
    /// just not followed.
    public let start: Duration?
    /// Empty unless the source was enhanced LRC with per-word timestamps.
    public let words: [LyricWord]
}

public struct LyricsTrack: Hashable, Sendable, Codable {
    public let lines: [LyricLine]

    /// Whether the lines can be followed along with the music. A plain `.lrc` is
    /// synced; a `.txt` dump is not.
    public var isSynced: Bool { lines.contains { $0.start != nil } }

    /// True only for enhanced LRC. A plain `.lrc` records one timestamp per line and
    /// simply does not contain the information to highlight individual words — no
    /// client can recover it, and interpolating it is a guess that falls apart on a
    /// held note.
    public var hasWordTiming: Bool { lines.contains { !$0.words.isEmpty } }

    public var isEmpty: Bool { lines.isEmpty }

    public var plainText: String {
        lines.map(\.text).joined(separator: "\n")
    }

    /// The last line that has started by `time`, or `nil` before the first one.
    ///
    /// Binary search: a long song can run to several hundred lines and this is
    /// called on every clock sample.
    public func index(at time: Duration) -> Int? {
        var low = 0
        var high = lines.count - 1
        var found: Int?
        while low <= high {
            let mid = (low + high) / 2
            guard let start = lines[mid].start else {
                // Untimed lines can't anchor a search; walk past them.
                low = mid + 1
                continue
            }
            if start <= time {
                found = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return found
    }
}

// MARK: - Offline storage

/// The domain model is `Codable` so a downloaded track's lyrics can be written to
/// disk and read back verbatim. It is deliberately the same type the UI renders
/// rather than a parallel storage struct: two shapes for one concept drift, and the
/// bug that follows is lyrics that are subtly wrong only when offline.

// MARK: - Resolution

extension LyricsTrack {
    init(_ document: LyricsDocument) {
        lines = document.lines.enumerated().map { index, wire in
            LyricLine(
                id: index,
                text: wire.text,
                start: wire.startSeconds.flatMap { seconds in
                    seconds.isFinite && seconds >= 0 ? .milliseconds(Int64((seconds * 1000).rounded())) : nil
                },
                words: []
            )
        }
    }
}
