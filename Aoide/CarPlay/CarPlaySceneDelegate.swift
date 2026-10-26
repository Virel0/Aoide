import CarPlay
import os

/// The car screen.
///
/// CarPlay is a *second live scene*, not a mirror of the phone: it has its own
/// delegate, its own lifecycle, and it can connect while the phone UI has never
/// been shown. Everything it displays therefore comes from shared state — the
/// session and the playback engine — rather than from anything the phone's view
/// hierarchy happens to be holding.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private static let log = Logger(subsystem: AppIdentity.bundle, category: "carplay")

    private var browser: CarPlayBrowser?

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        Self.log.info("CarPlay connected")

        MainActor.assumeIsolated {
            AudioSessionController.activate()
            // The car may well have connected before the phone UI ever ran.
            AppSession.shared.restore()

            CarPlayNowPlaying.shared.attach(interfaceController)

            let browser = CarPlayBrowser()
            self.browser = browser
            CarPlayNowPlaying.shared.browser = browser
            interfaceController.setRootTemplate(browser.makeRootTemplate(), animated: false, completion: nil)
        }
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        Self.log.info("CarPlay disconnected")
        MainActor.assumeIsolated {
            CarPlayNowPlaying.shared.detach()
            browser = nil
        }
    }
}
