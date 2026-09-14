import Foundation

/// What a record is made of, section by section, as the sidecar measured it.
///
/// The [beat grid](../../../../docs/beat-grid.md) says *when*; this says *what*.
/// Where the intro is, where the drop is, how loud each part is relative to the
/// rest, how the track counts its phrases, and where somebody is singing. See
/// `docs/arrangement.md` for the ask and the reasoning.
///
/// Every part of it is a measurement of the file, not a judgement about the
/// song. `verse` and `chorus` are in the contract and never returned, because
/// telling one from the other is a judgement, and `unknown` is a real and
/// frequent answer.
public struct Arrangement: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case intro, build, drop, breakdown, outro, verse, chorus, unknown
    }

    public struct Section: Equatable, Sendable {
        public let startMs: Double
        public let endMs: Double
        public let kind: Kind
        /// Level and onset density together, normalised within the track so a
        /// quiet record's loudest part still reads as 1. Ordering is trustworthy;
        /// the figures only mean anything within one track.
        public let energy: Double

        public init(startMs: Double, endMs: Double, kind: Kind, energy: Double) {
            self.startMs = startMs
            self.endMs = endMs
            self.kind = kind
            self.energy = energy
        }
    }

    public struct Span: Equatable, Sendable {
        public let startMs: Double
        public let endMs: Double

        public init(startMs: Double, endMs: Double) {
            self.startMs = startMs
            self.endMs = endMs
        }

        func overlaps(_ from: Double, _ to: Double) -> Bool {
            startMs < to && endMs > from
        }
    }

    /// Contiguous, covering the track end to end.
    public let sections: [Section]
    /// 8, 16 or 32; nil where the structure would not commit.
    public let phraseBars: Int?
    /// A downbeat that begins a phrase.
    public let phraseAnchorMs: Double?
    /// Three states and they are not interchangeable: spans where singing was
    /// found; empty, meaning looked and found none; **nil, meaning it could not
    /// be told** — which is not an instrumental, and is treated as "may be
    /// singing throughout".
    public let vocals: [Span]?

    public init(sections: [Section], phraseBars: Int? = nil, phraseAnchorMs: Double? = nil, vocals: [Span]? = nil) {
        self.sections = sections
        self.phraseBars = phraseBars
        self.phraseAnchorMs = phraseAnchorMs
        self.vocals = vocals
    }

    public func section(at ms: Double) -> Section? {
        sections.first { ms >= $0.startMs && ms < $0.endMs } ?? sections.last { $0.startMs <= ms }
    }

    /// Whether anybody might be singing anywhere in this stretch.
    ///
    /// Biased towards yes, deliberately: a false positive costs a mix, and a
    /// false negative — two voices over each other — is the exact mistake this
    /// exists to prevent. Unknown is therefore yes.
    public func maySing(from: Double, to: Double) -> Bool {
        guard let vocals else { return true }
        return vocals.contains { $0.overlaps(from, to) }
    }

    /// How far before a line somebody has to have stopped singing for the
    /// line to be a clean place to stop the record: a syllable's worth.
    public static let lineClearanceMs = 150.0

    /// How many phrases back a cut will look for a line nobody is singing
    /// across, before giving up and cutting on the one it was given.
    public static let lineSearchPhrases = 4

    /// The longest a sung line runs before a gap between two line starts is
    /// taken to be a rest rather than a line still being sung. LRC gives
    /// line starts, not ends; a line that started eight seconds ago is over.
    public static let longestLineMs = 8_000.0

    /// How long after a line starts a cut may not fall: the line is being
    /// sung. A cut lands *before* a line starts — the last word of the
    /// previous line is done — or in a rest.
    public static let lineLeadMs = 400.0

    /// Whether `ms` is a clean place to stop the record according to its
    /// synced lyrics: within ``lineLeadMs`` before a line starts (the line
    /// before it has ended), or in a rest longer than ``longestLineMs``, or
    /// after the last line. Everything else is mid-line.
    public static func isLyricClean(_ ms: Double, lineStartsMs: [Double]) -> Bool {
        guard let last = lineStartsMs.last else { return true }
        if ms >= last + longestLineMs { return true }
        var previous: Double?
        for start in lineStartsMs {
            if start >= ms {
                if start - ms <= lineLeadMs { return true }
                break
            }
            previous = start
        }
        guard let previous else { return true }
        return ms - previous >= longestLineMs
    }

    /// The latest phrase line at or before `ms` that is not mid-word.
    ///
    /// A cut on a phrase line is on the grid, but the grid does not know
    /// where the words are: a line that falls in the middle of a sung
    /// phrase leaves the tail repeating half a syllable — "-er-er-er". When
    /// the vocal spans are known, the line is moved back, a phrase at a
    /// time, to the latest one with ``lineClearanceMs`` of nobody singing
    /// before it. Unknown vocals, or no clean line within
    /// ``lineSearchPhrases``, and the line stands where it was.
    public func cleanLine(atOrBefore ms: Double, barMs: Double, lyricLinesMs: [Double]? = nil, downbeat: (Double) -> Double?) -> Double? {
        cleanLineJudged(atOrBefore: ms, barMs: barMs, lyricLinesMs: lyricLinesMs, downbeat: downbeat)?.ms
    }

    /// The same, saying whether the line found is actually clean or merely
    /// the one it was given because nothing clean was in reach. A cut can
    /// fall on an unclean line; an echo should not repeat it.
    public func cleanLineJudged(atOrBefore ms: Double, barMs: Double, lyricLinesMs: [Double]? = nil, downbeat: (Double) -> Double?) -> (ms: Double, clean: Bool)? {
        guard let line = phraseLine(atOrBefore: ms, barMs: barMs) ?? downbeat(ms) else { return nil }
        // Unknown vocals mean "may be singing throughout", so every line
        // reads as sung and the given one stands — no separate case needed.
        guard let phraseBars, barMs > 0 else { return (line, vocals != nil && !maySing(from: line - Self.lineClearanceMs, to: line)) }
        let phraseMs = barMs * Double(phraseBars)
        // Never back out of the part the exit was chosen in. The exit is the
        // end of a hook; the cleanest rest anywhere near it is the breath
        // *before* the hook, and a search that could reach it would leave
        // the record on the brink of its chorus — the one place to stay.
        let part = section(at: max(0, line - 1))
        let earliest = part.map { $0.startMs } ?? 0
        // Synced lyrics, when the record has them, are the finer map: the
        // server's vocal spans say where *somebody* is singing, the lyrics
        // say where each line starts, and a cut between two words of one
        // line is exactly what the spans cannot see. With lyrics, the
        // phrase line is moved back to the latest one that is not mid-line;
        // the spans decide only when there are no lyrics to read.
        let isClean: (Double) -> Bool = { candidate in
            if let lyricLinesMs { return Self.isLyricClean(candidate, lineStartsMs: lyricLinesMs) }
            return !self.maySing(from: candidate - Self.lineClearanceMs, to: candidate)
        }
        for back in 0..<Self.lineSearchPhrases {
            let candidate = line - Double(back) * phraseMs
            guard candidate >= 0, back == 0 || candidate > earliest else { break }
            if isClean(candidate) { return (candidate, true) }
        }
        return (line, false)
    }

    /// How far into a record its first line may be for that line to be the
    /// record's landmark — the moment a listener recognises it. Sixteen bars:
    /// past that the record has an instrumental opening of its own, and the
    /// mix-in point is the place to come in.
    public static let landmarkReachBars = 16.0

    /// Where a record coming in after a cut should land: the downbeat the
    /// first line of its lyrics sits on, when that line comes within
    /// ``landmarkReachBars`` of `mixInMs`. "I want you to stay" is the
    /// record; the new record should not begin, it should answer the echo,
    /// and the line that answers is the first one. Nil when there are no
    /// lyrics to read or the first line is too far in.
    public static func landmarkMs(lyricLinesMs: [Double]?, mixInMs: Double, barMs: Double, downbeat: (Double) -> Double?) -> Double? {
        guard let first = lyricLinesMs?.first, barMs > 0 else { return nil }
        guard first >= mixInMs - barMs, first <= mixInMs + Self.landmarkReachBars * barMs else { return nil }
        return downbeat(first)
    }

    /// How far a moment may be moved to sit on a phrase line: two bars, the
    /// server's own rule for its section boundaries. Further than that and
    /// the line is not where the music changes — a section boundary five
    /// bars past a phrase line is on a bar line for a reason, and dragging
    /// it back seven bars puts the exit inside the hook it was meant to end.
    public static let phraseReachBars = 2.0

    /// The phrase line at or before `ms` if one is within ``phraseReachBars``,
    /// else nil. For moments that must not move later: an exit.
    public func phraseLine(atOrBefore ms: Double, barMs: Double) -> Double? {
        guard let line = phraseStart(atOrBefore: ms, barMs: barMs) else { return nil }
        return ms - line <= Self.phraseReachBars * barMs + 0.5 ? line : nil
    }

    /// The nearest phrase line to `ms`, either side, if one is within
    /// ``phraseReachBars``; else nil. For moments that may move either way:
    /// an entry.
    public func phraseLine(near ms: Double, barMs: Double) -> Double? {
        guard let phraseBars, barMs > 0, let before = phraseStart(atOrBefore: ms, barMs: barMs) else { return nil }
        let after = before + barMs * Double(phraseBars)
        let nearest = ms - before <= after - ms ? before : after
        return abs(ms - nearest) <= Self.phraseReachBars * barMs + 0.5 ? nearest : nil
    }

    /// The phrase boundary at or before `ms`, when the track counts phrases.
    public func phraseStart(atOrBefore ms: Double, barMs: Double) -> Double? {
        guard let phraseBars, let phraseAnchorMs, barMs > 0 else { return nil }
        let phraseMs = barMs * Double(phraseBars)
        let phrases = ((ms - phraseAnchorMs) / phraseMs).rounded(.down)
        return phraseAnchorMs + phrases * phraseMs
    }
}
