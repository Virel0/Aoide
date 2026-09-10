import Foundation

/// How one song is handed over to the next when crossfading is on.
///
/// Pure arithmetic over numbers the library already holds — where the sound
/// starts and ends (``SilenceBounds``) and the tempo the sidecar measured.
/// Nothing here touches a player, so every rule below is testable without audio.
///
/// **This is not beat-matching, and deliberately so.** Beat-matching needs the
/// position of the beats, not just how many of them there are per minute: two
/// tracks locked to the same tempo but a quarter-beat apart sound worse than
/// two tracks that were never locked at all. The measurement we have is a
/// single BPM figure good to about a beat per minute, with no downbeat and no
/// grid, and its own documentation says not to match on it. So tempo here does
/// one job — deciding whether a long blend is worth attempting — and the
/// crossfade itself is honest about being a crossfade.
public enum MixTransition: Equatable, Sendable {
    /// Straight into the next track with nothing between them. What an album
    /// run gets: the silence between two tracks of one record is part of the
    /// record, and a segue written to run continuously must not be faded across.
    case gapless

    /// The outgoing track finishes, then the next one starts.
    case cut

    /// The two overlap for this long, the outgoing one fading down as the
    /// incoming one fades up.
    case blend(Duration)

    /// Seconds of overlap, zero for the transitions that have none.
    public var overlap: Duration {
        if case let .blend(length) = self { return length }
        return .zero
    }
}

/// What the planner needs to know about one track. A small mirror of the parts
/// of ``Track`` plus the measurements, so the rules can be exercised directly.
public struct MixTrack: Equatable, Sendable {
    public let album: String
    public let trackNumber: Int?
    /// The file's whole length.
    public let duration: Duration?
    /// Where the sound is, when it has been measured.
    public let sound: SilenceBounds?
    /// Beats per minute, when the measurement was confident enough to report one.
    public let bpm: Double?

    public init(
        album: String,
        trackNumber: Int? = nil,
        duration: Duration? = nil,
        sound: SilenceBounds? = nil,
        bpm: Double? = nil
    ) {
        self.album = album
        self.trackNumber = trackNumber
        self.duration = duration
        self.sound = sound
        self.bpm = bpm
    }

    /// How much of this track is actually sound, in seconds. The whole file when
    /// nothing has been measured.
    var soundSeconds: Double? {
        if let sound { return max(0, sound.soundEnd.seconds - sound.soundStart.seconds) }
        return duration?.seconds
    }
}

public enum MixPlanner {
    /// A blend when both tempi agree. Long enough to be a transition rather than
    /// a stumble, short enough that neither track is buried under the other for
    /// a verse.
    public static let matchedBlend = Duration.seconds(8)

    /// A blend when they do not agree, or when nothing was measured. Short,
    /// because an overlap between two unrelated grooves stops sounding like a
    /// transition and starts sounding like two songs at once.
    public static let unmatchedBlend = Duration.seconds(4)

    /// No more than this share of either track may be spent overlapping. A
    /// ninety-second interlude blended for eight seconds either side has lost a
    /// sixth of itself to the mix.
    static let maximumShareOfTrack = 0.25

    /// Below this there is not enough song to fade. Two seconds of overlap on a
    /// twenty-second sound clip is not a transition.
    static let minimumBlend = Duration.seconds(2)

    /// Plans the handover from `outgoing` to `incoming`.
    ///
    /// - Parameters:
    ///   - automix: the Crossfade toggle, off by default. Off means the player
    ///     behaves as it always has.
    ///   - albumLock: keep album runs intact. On, two consecutive tracks of one
    ///     album hand over gaplessly whatever the toggle says — which is what
    ///     makes album lock the crossfader's off-switch for records that need one.
    public static func plan(
        from outgoing: MixTrack,
        to incoming: MixTrack,
        automix: Bool,
        albumLock: Bool = true
    ) -> MixTransition {
        if albumLock, isAlbumRun(from: outgoing, to: incoming) { return .gapless }
        guard automix else { return .cut }

        let wanted = tempiAgree(outgoing.bpm, incoming.bpm) ? matchedBlend : unmatchedBlend

        // Neither track may give up more than its share, and a track whose length
        // is unknown gives up nothing — better a cut than a fade over a guess.
        guard let outgoingSeconds = outgoing.soundSeconds,
              let incomingSeconds = incoming.soundSeconds
        else { return .cut }

        let allowed = min(outgoingSeconds, incomingSeconds) * maximumShareOfTrack
        let overlap = min(wanted.seconds, allowed)
        guard overlap >= minimumBlend.seconds else { return .cut }
        return .blend(.seconds(overlap))
    }

    /// Two tracks of the same album, in order. Both parts matter: an album played
    /// on shuffle is not a run, and neither is track 1 of a record following
    /// track 9 of the same one.
    static func isAlbumRun(from outgoing: MixTrack, to incoming: MixTrack) -> Bool {
        guard !outgoing.album.isEmpty, outgoing.album == incoming.album else { return false }
        guard let from = outgoing.trackNumber, let to = incoming.trackNumber else { return false }
        return to == from + 1
    }

    /// Whether two tempi are near enough for a long blend.
    ///
    /// Compared as a ratio folded into one octave, because 85 and 170 are the
    /// same groove counted differently — and half-or-double is the *expected*
    /// failure of the measurement, so a planner that treated them as unrelated
    /// would refuse the very pairs that fit best.
    static func tempiAgree(_ a: Double?, _ b: Double?) -> Bool {
        guard let a, let b, a > 0, b > 0, a.isFinite, b.isFinite else { return false }
        var ratio = a / b
        while ratio > 1.5 { ratio /= 2 }
        while ratio < 1 / 1.5 { ratio *= 2 }
        return abs(ratio - 1) <= tolerance
    }

    /// Six per cent — about 7 BPM at 120. Wide enough to survive a measurement
    /// good to a beat per minute either way, narrow enough that the two tracks
    /// are recognisably the same speed.
    static let tolerance = 0.06
}

/// The shape of a crossfade.
///
/// Equal-power rather than linear: two uncorrelated recordings at half volume
/// each are not as loud as one at full volume, so a linear fade dips audibly in
/// the middle. Squaring to one keeps the perceived level flat across the
/// handover, which is the whole point of doing this instead of stopping.
public enum MixCurve {
    /// Level for the track on its way out, `progress` running 0 → 1.
    public static func outgoing(progress: Double) -> Double {
        cos(clamp(progress) * .pi / 2)
    }

    /// Level for the track on its way in.
    public static func incoming(progress: Double) -> Double {
        sin(clamp(progress) * .pi / 2)
    }

    private static func clamp(_ progress: Double) -> Double {
        guard progress.isFinite else { return 0 }
        return min(1, max(0, progress))
    }
}
