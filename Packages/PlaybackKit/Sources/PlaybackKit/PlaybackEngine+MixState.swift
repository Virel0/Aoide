#if os(iOS)

extension PlaybackEngine {
    /// What one record becomes the next by.
    public enum HandOver: Equatable, Sendable {
        /// Beat-matched on the decks: a blend, a filter fade, a cut, or an
        /// echo-out, over this many bars (none for the last two).
        case mix(DJTransition.Style, bars: Int)
        /// A plain crossfade of this many seconds, on the decks or the player.
        case crossfade(seconds: Double)
        /// One record ending exactly as the next begins.
        case join
    }

    /// What Auto DJ is doing right now, for a screen to show.
    ///
    /// A listener cannot tell a mix from a long crossfade by looking at a
    /// scrubber, and the difference is the whole feature — so the player says
    /// so, the way Apple's own does. `booked` also answers the question people
    /// actually have, which is not "is it mixing" but "is it *going* to".
    public enum MixState: Equatable, Sendable {
        /// Nothing is being mixed or crossfaded, and nothing is booked.
        case off
        /// The decks have this record but nothing is planned after it.
        case ready
        /// A hand-over into the next record is booked, and this is what it is.
        case booked(HandOver)
        /// Two records are playing, and this is how far through it is — enough
        /// for a screen to draw a crossfader that means something.
        case mixing(HandOver, progress: Double)
    }
}

#endif
