import SwiftUI

@main
struct JellyMusicApp: App {
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
            AppSession.shared.restore()
        }
        return true
    }
}
