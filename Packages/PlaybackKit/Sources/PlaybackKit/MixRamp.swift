import AVFoundation
import Foundation

/// Turns a crossfade into something `AVFoundation` will perform.
///
/// The fade is applied by the audio pipeline through `AVAudioMix`, not by a timer
/// nudging `player.volume`. A timer on the main actor is at the mercy of whatever
/// else the app is doing — a slow frame during the handover is an audible step in
/// the level — while a mix is sample-accurate, keeps running while the app is in
/// the background, and survives the process being busy.
///
/// `setVolumeRamp` interpolates linearly, so the equal-power shape from
/// ``MixCurve`` is laid down as a run of short straight segments. Sixteen of them
/// across a fade puts the worst error under a fifth of a decibel, which is well
/// below what anyone can hear, and costs nothing to schedule.
///
/// Only the track coming *in* is faded this way. AVFoundation honours a mix
/// attached before an item has played; the track on its way out has, by
/// definition, already played, so its half of the crossfade is ridden down on its
/// deck's own fader instead. See `PlaybackEngine.startBlend()`.
public enum MixRamp {
    /// How many straight segments approximate the curve.
    public static let steps = 16

    /// One straight piece of a fade: play from `start` to `end` seconds (relative
    /// to the beginning of the fade) taking the level from `from` to `to`.
    public struct Segment: Equatable, Sendable {
        public let start: Double
        public let end: Double
        public let from: Double
        public let to: Double
    }

    /// The segments of a fade of `seconds`, using `curve` to read the level at a
    /// progress between 0 and 1.
    ///
    /// Returns nothing for a fade with no length — there is no such thing as an
    /// instantaneous ramp, and asking for one is a sign a transition was planned
    /// that should have been a cut.
    public static func segments(
        seconds: Double,
        steps: Int = steps,
        curve: (Double) -> Double
    ) -> [Segment] {
        guard seconds > 0, seconds.isFinite, steps > 0 else { return [] }
        return (0..<steps).map { step in
            let from = Double(step) / Double(steps)
            let to = Double(step + 1) / Double(steps)
            return Segment(
                start: from * seconds,
                end: to * seconds,
                from: curve(from),
                to: curve(to)
            )
        }
    }

    /// The mix that brings a track in from silence over its first `seconds` of
    /// sound.
    public static func fadeIn(
        track: AVAssetTrack,
        startingAt start: CMTime,
        seconds: Double
    ) -> AVAudioMix? {
        mix(track: track, startingAt: start, seconds: seconds, curve: MixCurve.incoming(progress:))
    }

    private static func mix(
        track: AVAssetTrack,
        startingAt start: CMTime,
        seconds: Double,
        curve: (Double) -> Double
    ) -> AVAudioMix? {
        let segments = segments(seconds: seconds, curve: curve)
        guard !segments.isEmpty else { return nil }

        let parameters = AVMutableAudioMixInputParameters(track: track)
        // Nail down the level before the fade as well. Without it the first ramp's
        // starting value is only reached *at* the ramp, and the item plays at
        // whatever the pipeline's default is until then.
        parameters.setVolume(Float(segments[0].from), at: .zero)
        for segment in segments {
            parameters.setVolumeRamp(
                fromStartVolume: Float(segment.from),
                toEndVolume: Float(segment.to),
                timeRange: CMTimeRange(
                    start: CMTimeAdd(start, CMTime(seconds: segment.start, preferredTimescale: 600)),
                    end: CMTimeAdd(start, CMTime(seconds: segment.end, preferredTimescale: 600))
                )
            )
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        return mix
    }
}
