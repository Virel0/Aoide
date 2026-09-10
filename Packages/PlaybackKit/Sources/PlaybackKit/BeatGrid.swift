import Foundation

/// Where the beats and the bars are, as the sidecar measured them.
///
/// The thing a tempo is not. `/aoide/audio-analysis` says how fast a track is;
/// this says *when* each beat happens, which is the difference between choosing
/// a crossfade's length and actually mixing two records together. See
/// `docs/beat-grid.md` for the ask and `docs/crossfade.md` for what is built on
/// the tempo alone.
///
/// Every field can be absent. A grid that could not be fitted, a meter that could
/// not be established and mix points that depend on that meter are all normal
/// answers about real music, and each of them means the same thing here: this is
/// not a track to mix, so crossfade it instead.
public struct BeatGrid: Equatable, Sendable {
    /// A stretch of the track at one steady tempo. Contiguous, covering the track
    /// end to end, so "which segment holds this moment" always has an answer.
    public struct Segment: Equatable, Sendable {
        public let startMs: Double
        public let endMs: Double
        /// The position of beat zero, which the server puts on a downbeat.
        public let anchorMs: Double
        public let bpm: Double
        /// RMS distance between the fitted beats and the ones actually detected.
        /// The field that decides whether anything may lock to this.
        public let residualMs: Double
        public let beats: Int

        public init(startMs: Double, endMs: Double, anchorMs: Double, bpm: Double, residualMs: Double, beats: Int) {
            self.startMs = startMs
            self.endMs = endMs
            self.anchorMs = anchorMs
            self.bpm = bpm
            self.residualMs = residualMs
            self.beats = beats
        }

        public var beatMs: Double { 60_000 / bpm }

        /// `beat(n) = anchor + n × 60000 / bpm`, within this segment.
        public func beat(_ n: Int) -> Double { anchorMs + Double(n) * beatMs }

        /// The number of the last beat at or before `ms`.
        public func beatIndex(at ms: Double) -> Int {
            Int(((ms - anchorMs) / beatMs).rounded(.down))
        }
    }

    public let segments: [Segment]
    /// 4 for nearly everything, 3 for a waltz, `nil` when the meter could not be
    /// established — in which case nothing bar-aligned may be offered.
    public let beatsPerBar: Int?
    /// Which beat of a segment starts a bar. The server promises 0 whenever the
    /// meter is known; the field exists because the contract has it and a future
    /// grid might not be able to promise that.
    public let downbeatIndex: Int?
    /// Where a blend may bring this track in, past an intro that is only
    /// atmosphere. A downbeat, and `nil` with the meter.
    public let mixInMs: Double?
    /// Where a blend may take this track out. A downbeat, and `nil` with the meter.
    public let mixOutMs: Double?
    /// Camelot: `8A` is A minor, `8B` is C major. Used to *prefer* a pair, never
    /// to refuse one — the estimator is weakest between a key and its relative
    /// major or minor, which is exactly the pair a listener would forgive.
    public let key: String?
    public let keyConfidence: Double?

    public init(
        segments: [Segment],
        beatsPerBar: Int? = nil,
        downbeatIndex: Int? = nil,
        mixInMs: Double? = nil,
        mixOutMs: Double? = nil,
        key: String? = nil,
        keyConfidence: Double? = nil
    ) {
        self.segments = segments
        self.beatsPerBar = beatsPerBar
        self.downbeatIndex = downbeatIndex
        self.mixInMs = mixInMs
        self.mixOutMs = mixOutMs
        self.key = key
        self.keyConfidence = keyConfidence
    }

    /// The segment holding a moment, or the nearest one if the moment falls
    /// outside every segment.
    public func segment(at ms: Double) -> Segment? {
        segments.first { ms >= $0.startMs && ms < $0.endMs } ?? segments.last { $0.startMs <= ms } ?? segments.first
    }

    /// The length of one bar at a moment, when the meter is known.
    public func barMs(at ms: Double) -> Double? {
        guard let beatsPerBar, let segment = segment(at: ms) else { return nil }
        return segment.beatMs * Double(beatsPerBar)
    }

    /// The downbeat at or before `ms`, when the meter is known.
    ///
    /// Every segment's beat zero is a downbeat, so this is arithmetic within one
    /// segment and needs no phase carried across a tempo change.
    public func downbeat(atOrBefore ms: Double) -> Double? {
        guard let beatsPerBar, let segment = segment(at: ms) else { return nil }
        let barMs = segment.beatMs * Double(beatsPerBar)
        let bars = ((ms - segment.anchorMs) / barMs).rounded(.down)
        return segment.anchorMs + bars * barMs
    }

    /// How far off its own grid a track may sit and still be worth locking to,
    /// for a blend of this many seconds.
    ///
    /// Sixteen bars at 128 BPM is thirty seconds, and holding a twentieth of a
    /// beat across that wants a grid good to about 20 ms — the number the spec was
    /// written around. A shorter blend forgives proportionally more, because there
    /// is less of it for an error to accumulate across, and the tolerance is
    /// capped so that a two-bar blend does not accept a grid that is nonsense.
    public static func maximumResidualMs(forBlendSeconds seconds: Double) -> Double {
        guard seconds > 0 else { return 0 }
        return min(40, 20 * (30 / seconds))
    }

    /// Whether a blend of this length may be locked to this grid at this moment.
    public func canLock(at ms: Double, blendSeconds: Double) -> Bool {
        guard beatsPerBar != nil, let segment = segment(at: ms) else { return false }
        guard segment.residualMs <= Self.maximumResidualMs(forBlendSeconds: blendSeconds) else { return false }
        // The blend must finish inside the segment it started in: crossing a
        // boundary is crossing a tempo change, and a grid fitted either side of
        // one describes neither half of the blend.
        return ms + blendSeconds * 1000 <= segment.endMs
    }
}

/// The Camelot wheel, as far as anything here needs it.
///
/// Only ever used to prefer one pair over another. Never to refuse a pair: the
/// estimator is weakest between a key and its relative major or minor, which
/// share all seven notes and which a listener would not have objected to anyway.
public enum CamelotKey {
    /// A key as its number (1…12) and letter (A minor, B major).
    public static func parse(_ key: String?) -> (number: Int, isMinor: Bool)? {
        guard let key, key.count >= 2 else { return nil }
        let letter = key.suffix(1).uppercased()
        guard letter == "A" || letter == "B" else { return nil }
        guard let number = Int(key.dropLast()), (1...12).contains(number) else { return nil }
        return (number, letter == "A")
    }

    /// The compatible moves: the same key, one step either way around the wheel,
    /// or the same number in the other letter.
    public static func areCompatible(_ a: String?, _ b: String?) -> Bool {
        guard let a = parse(a), let b = parse(b) else { return false }
        if a.number == b.number { return true }
        let distance = abs(a.number - b.number)
        let around = min(distance, 12 - distance)
        return around == 1 && a.isMinor == b.isMinor
    }
}
