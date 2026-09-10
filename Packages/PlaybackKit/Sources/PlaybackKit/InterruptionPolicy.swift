import Foundation

/// What to do when a phone call, an alarm or another app's audio ends.
///
/// Kept apart from the engine, and free of `AVAudioSession`, so the decision can
/// be tested on any machine — the engine itself only builds for iOS.
public enum InterruptionPolicy {
    /// Whether playback should start again once the interruption is over.
    ///
    /// The system sets `shouldResume` when it thinks the interrupted app ought to
    /// carry on, and trusting only that flag is what made a phone call end a
    /// listening session: iOS routinely omits it for calls, so the music simply
    /// never came back. Anything that was *playing* when it was interrupted is
    /// resumed, which is what a listener means by taking a call in the middle of
    /// an album. Something already paused stays paused.
    public static func shouldResume(systemSaysResume: Bool, wasPlayingWhenInterrupted: Bool) -> Bool {
        systemSaysResume || wasPlayingWhenInterrupted
    }
}
