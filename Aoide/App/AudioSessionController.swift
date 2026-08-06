import AVFoundation
import os

/// Configures the one shared `AVAudioSession`.
///
/// This is the difference between an app that plays music and an app that goes
/// silent the moment the screen locks, another app makes a sound, or the car
/// hands the audio route back.
@MainActor
enum AudioSessionController {
    private static let log = Logger(subsystem: "com.example.aoide", category: "audio")

    static func activate() {
        let session = AVAudioSession.sharedInstance()
        do {
            // `.playback` is what keeps audio alive when the screen locks and
            // silences the ringer switch — the correct category for a music app.
            // `.longFormAudio` tells AirPlay 2 and CarPlay this is music, not a
            // notification blip, which is what makes route handoff behave.
            try session.setCategory(.playback, mode: .default, policy: .longFormAudio)
            try session.setActive(true)
        } catch {
            log.error("Could not activate audio session: \(error.localizedDescription, privacy: .public)")
        }
    }
}
