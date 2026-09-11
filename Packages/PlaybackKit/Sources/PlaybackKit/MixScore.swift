import Foundation

/// How well two records suit each other, as one number and the five it is
/// made of — and, from that, how long they should run together.
///
/// The planner used to refuse on one criterion at a time: a key clash meant
/// eight bars, a tempo gap meant no, and nothing in between was expressible.
/// Real compatibility is graded. Two records a step apart on the wheel, a
/// per cent apart in tempo, both instrumental, coming in on a build at the same
/// energy — that pair earns half a minute together, and a pair that is fine on
/// three counts and poor on two earns a short one. A weighted score says which.
///
/// A few things stay as hard rules, because a score can be outvoted and some
/// mistakes should not be: two records singing at once is refused, a drop
/// dropped onto a drop is capped at eight bars, and the grid rules in
/// ``BeatGrid`` still decide whether anything may lock at all.
public struct MixScore: Equatable, Sendable {
    /// 1 up to a two per cent bend — "close BPM is easy" — falling to 0 at the
    /// six per cent limit, where a record starts to sound like something was
    /// done to it.
    public let tempo: Double
    /// 1 for the same key, a neighbour or the relative; 0 for a clash; 0.5 when
    /// either key is unknown, which is most of a library.
    public let key: Double
    /// 1 when neither sings across the overlap, 0.6 when one does, 0.5 when
    /// nothing is known. Both singing is not a low score; it is a refusal.
    public let vocals: Double
    /// 1 when the outgoing record's exit and the incoming's entry are at the
    /// same energy, falling to 0 as they diverge. 0.5 unknown.
    public let energy: Double
    /// How well the two sections suit a hand-over: coming in on a build or an
    /// intro is what a DJ does; going out on an outro or a breakdown likewise.
    /// A drop at either end is the worst answer. 0.5 unknown.
    public let sections: Double

    public static let weights = (tempo: 0.2, key: 0.2, vocals: 0.15, energy: 0.2, sections: 0.25)

    public var total: Double {
        tempo * Self.weights.tempo
            + key * Self.weights.key
            + vocals * Self.weights.vocals
            + energy * Self.weights.energy
            + sections * Self.weights.sections
    }

    /// How long the pair should run together, from the score alone. The
    /// planner still has to find room for it and may settle for less.
    public var bars: Int? {
        switch total {
        case 0.75...: 32
        case 0.55..<0.75: 16
        case 0.35..<0.55: 8
        default: nil
        }
    }

    public init(tempo: Double, key: Double, vocals: Double, energy: Double, sections: Double) {
        self.tempo = tempo
        self.key = key
        self.vocals = vocals
        self.energy = energy
        self.sections = sections
    }

    // MARK: - The factors

    /// Where a bend stops being free.
    static let easyBend = 0.02

    static func tempo(rate: Double) -> Double {
        let bend = abs(rate - 1)
        guard bend > easyBend + 1e-9 else { return 1 }
        return max(0, 1 - (bend - easyBend) / (DJPlanner.maximumStretch - easyBend))
    }

    static func key(_ a: String?, _ b: String?) -> Double {
        guard a != nil, b != nil else { return 0.5 }
        return CamelotKey.areCompatible(a, b) ? 1 : 0
    }

    static func vocals(outgoingSings: Bool?, incomingSings: Bool?) -> Double {
        switch (outgoingSings, incomingSings) {
        case (nil, _), (_, nil): 0.5
        case (false, false): 1
        default: 0.6
        }
    }

    static func energy(_ exit: Double?, _ entry: Double?) -> Double {
        guard let exit, let entry else { return 0.5 }
        return max(0, 1 - abs(exit - entry))
    }

    static func sections(exit: Arrangement.Kind?, entry: Arrangement.Kind?) -> Double {
        guard let exit, let entry else { return 0.5 }
        let out: Double = switch exit {
        case .outro, .breakdown: 1
        case .build, .verse, .chorus, .intro: 0.7
        case .unknown: 0.6
        case .drop: 0.4
        }
        let into: Double = switch entry {
        case .build, .intro, .breakdown: 1
        case .verse, .chorus, .outro: 0.7
        case .unknown: 0.6
        case .drop: 0.2
        }
        return (out + into) / 2
    }
}
