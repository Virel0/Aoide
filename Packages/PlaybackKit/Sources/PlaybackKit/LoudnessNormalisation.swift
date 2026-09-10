import Foundation

/// How much to turn a track down so every record plays at the same level.
///
/// A personal library is mastered across decades: a 1978 pressing and a 2015
/// remaster of the same song can differ by ten decibels, which is a volume
/// lottery on headphones and worse under a game whose own level is fixed.
///
/// The rules here are the contract with the desktop app, which carries the same
/// arithmetic in `src/shared/aoide/loudness.ts`, and with the sidecar, which
/// measures the numbers (`docs/audio-analysis.md`). All three must agree or the
/// same album plays at two levels on two devices.
public enum LoudnessNormalisation {
    /// ReplayGain 2.0's reference level. The one number every side must share.
    public static let referenceLufs = -18.0

    /// Decibels to apply, or nil when there is nothing to do.
    ///
    /// **Attenuation only.** A track quieter than the reference is left alone
    /// rather than amplified: pushing a quiet master up is how you turn its own
    /// peaks into clipping, and the listener's volume control is right there.
    ///
    /// A master whose true peak is already above full scale — the loudness war
    /// left plenty — is turned down until it is not, even when its loudness
    /// alone would have asked for nothing.
    public static func gainDb(loudnessLufs: Double?, truePeakDbfs: Double? = nil) -> Double? {
        guard let loudnessLufs, loudnessLufs.isFinite else { return nil }

        var gain = min(0, referenceLufs - loudnessLufs)
        if let truePeakDbfs, truePeakDbfs.isFinite, truePeakDbfs + gain > 0 {
            gain = -truePeakDbfs
        }
        // Nothing to apply is nil rather than 0, so a caller can tell "measured
        // and already right" from "not measured" without a second flag.
        return gain == 0 ? nil : gain
    }

    /// The same answer as a linear multiplier, for a player whose volume is one.
    public static func volumeFactor(loudnessLufs: Double?, truePeakDbfs: Double? = nil) -> Double? {
        guard let gain = gainDb(loudnessLufs: loudnessLufs, truePeakDbfs: truePeakDbfs) else { return nil }
        return pow(10, gain / 20)
    }
}
