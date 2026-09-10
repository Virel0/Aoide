import Intents
import PlaybackKit
import SwiftUI

@main
struct AoideApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

/// Exists so the audio session is configured before any scene — phone *or* car —
/// asks for playback. SwiftUI's `App` lifecycle alone gives us no hook early enough.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        MainActor.assumeIsolated {
            AudioSessionController.activate()
            // Before the session restores, because restoring wires up the playback
            // reporters and CarPlay can start a track before the phone UI has ever
            // appeared. Opened from a view's `.task` instead, a whole drive's listening
            // would go unrecorded.
            CurationDatabase.open()
            AppSession.shared.restore()
        // Bounds that arrive after a queue was built — the server's answer for a
        // streamed track — are read at the moment the player makes the item.
        PlaybackEngine.shared.soundResolver = { track in
            TrimSilencePreference.isOn ? SilenceIndex.shared.bounds(for: track.id) : nil
        }
        PlaybackEngine.shared.loudnessResolver = { track in
            AudioAnalysisSync.shared.gainDb(for: track.id)
        }
        // Tempo decides only how long a crossfade should be. See MixPlanner.
        PlaybackEngine.shared.bpmResolver = { track in
            AudioAnalysisSync.shared.bpm(for: track.id)
        }
        PlaybackEngine.shared.isAutoMixing = AutoMixPreference.isOn
        PlaybackEngine.shared.isAlbumLocked = AlbumLockPreference.isOn
        }
        return true
    }

    /// Media intents are handled in-process rather than by an extension: an
    /// extension could resolve "play Boreas" but not start it, because the queue
    /// and the player live in this process.
    func application(
        _ application: UIApplication,
        handlerFor intent: INIntent
    ) -> Any? {
        guard intent is INPlayMediaIntent || intent is INSearchForMediaIntent else { return nil }
        return Self.mediaIntentHandler
    }

    /// Held for the process lifetime — the system keeps only a weak reference to
    /// whatever `handlerFor` returns.
    private static let mediaIntentHandler = MediaIntentHandler()
}
