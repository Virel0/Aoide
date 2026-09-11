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

    /// The phrase boundary at or before `ms`, when the track counts phrases.
    public func phraseStart(atOrBefore ms: Double, barMs: Double) -> Double? {
        guard let phraseBars, let phraseAnchorMs, barMs > 0 else { return nil }
        let phraseMs = barMs * Double(phraseBars)
        let phrases = ((ms - phraseAnchorMs) / phraseMs).rounded(.down)
        return phraseAnchorMs + phrases * phraseMs
    }
}
