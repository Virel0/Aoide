import Foundation

// MARK: - Wire format

/// `GET /Audio/{itemId}/Lyrics`.
///
/// Every field is optional because Jellyfin omits nulls rather than serialising
/// them, and because the same endpoint serves three quite different shapes:
///
/// - **Enhanced LRC** — `start` set, `cues` populated with per-word timings.
/// - **Plain LRC** — `start` set, `cues` present but empty.
/// - **Plain text or unparseable** — neither present; the lyrics exist but have no
///   timing at all and can only be shown as a static block.
///
/// `Metadata` is deliberately not modelled: Jellyfin's LRC parser never assigns it,
/// so `IsSynced` and `Offset` are always null and reading them would be misleading.
/// An `[offset:]` tag in the user's own `.lrc` is silently dropped server-side.
// These declare `CodingKeys` explicitly. A hand-written `init(from:)` on a
// `Decodable`-only type means the compiler never needs to synthesise them, so
// referring to `CodingKeys.self` without declaring them doesn't compile. The
// decoder lowercases each key's first character, so these stay camelCase.
struct LyricsDocument: Decodable, Sendable {
    let lyrics: [WireLine]

    enum CodingKeys: String, CodingKey { case lyrics }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lyrics = try c.decodeIfPresent([WireLine].self, forKey: .lyrics) ?? []
    }
}

struct WireLine: Decodable, Sendable {
    let text: String
    let start: Int64?
    let cues: [WireCue]?

    enum CodingKeys: String, CodingKey { case text, start, cues }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        start = try c.decodeIfPresent(Int64.self, forKey: .start)
        cues = try c.decodeIfPresent([WireCue].self, forKey: .cues)
    }
}

struct WireCue: Decodable, Sendable {
    let position: Int
    let endPosition: Int?
    let start: Int64
    let end: Int64?

    enum CodingKeys: String, CodingKey { case position, endPosition, start, end }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        position = try c.decodeIfPresent(Int.self, forKey: .position) ?? 0
        endPosition = try c.decodeIfPresent(Int.self, forKey: .endPosition)
        start = try c.decodeIfPresent(Int64.self, forKey: .start) ?? 0
        end = try c.decodeIfPresent(Int64.self, forKey: .end)
    }
}

// MARK: - Domain model

extension Duration {
    /// Jellyfin measures time in .NET ticks: 10,000,000 per second.
    static func jellyfinTicks(_ ticks: Int64) -> Duration {
        .nanoseconds(ticks * 100)
    }
}

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
    /// The longest a single word's highlight may take to sweep. Without this a word
    /// before a long instrumental break oozes across the screen for the whole gap.
    private static let maxSweep: Duration = .milliseconds(1200)

    init(_ document: LyricsDocument) {
        lines = document.lyrics.enumerated().map { index, wire in
            LyricLine(
                id: index,
                text: wire.text,
                start: wire.start.map(Duration.jellyfinTicks),
                words: Self.words(in: wire)
            )
        }
    }

    private static func words(in line: WireLine) -> [LyricWord] {
        guard let cues = line.cues, !cues.isEmpty else { return [] }

        // `position` / `endPosition` are .NET UTF-16 code-unit offsets. Swift's
        // String.Index is grapheme-based, so slicing directly with them would be
        // wrong the moment a line contains an emoji or a combining accent.
        let units = Array(line.text.utf16)

        var result: [LyricWord] = []
        for (i, cue) in cues.enumerated() {
            let lo = min(max(cue.position, 0), units.count)
            let hi = min(max(cue.endPosition ?? units.count, lo), units.count)
            guard let slice = String(utf16CodeUnits: Array(units[lo..<hi]), count: hi - lo)
                .trimmingCharacters(in: .whitespaces)
                .nilIfEmpty
            else { continue }

            // Cue ranges are contiguous in ordinary enhanced LRC, so each slice
            // carries its own trailing space — trimmed above, or a flow layout shows
            // doubled gaps.
            let start = Duration.jellyfinTicks(cue.start)
            // The next cue's start is a better end than the cue's own `end`, which
            // is often absent; fall back only for the last word on the line.
            let naturalEnd = i + 1 < cues.count
                ? Duration.jellyfinTicks(cues[i + 1].start)
                : cue.end.map(Duration.jellyfinTicks) ?? (start + maxSweep)

            result.append(
                LyricWord(
                    id: i,
                    text: slice,
                    start: start,
                    sweepEnd: min(naturalEnd, start + maxSweep)
                )
            )
        }
        return result
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
