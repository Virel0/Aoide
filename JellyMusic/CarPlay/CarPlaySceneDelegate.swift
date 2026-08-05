import CarPlay
import os

/// The car screen.
///
/// CarPlay is a *second live scene*, not a mirror of the phone: it has its own
/// delegate, its own lifecycle, and it can connect while the phone UI has never
/// been shown. Everything it displays therefore has to come from shared state
/// (`AppSession`, and later the playback engine) rather than from anything the
/// phone's view hierarchy happens to be holding.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private static let log = Logger(subsystem: "com.example.jellymusic", category: "carplay")

    private var interfaceController: CPInterfaceController?

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        Self.log.info("CarPlay connected")
        self.interfaceController = interfaceController

        MainActor.assumeIsolated {
            AudioSessionController.activate()
            // The car may well have connected before the phone UI ever ran.
            AppSession.shared.restore()
            interfaceController.setRootTemplate(rootTemplate(), animated: false)
        }
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        Self.log.info("CarPlay disconnected")
        self.interfaceController = nil
    }

    // MARK: - Templates

    @MainActor
    private func rootTemplate() -> CPTemplate {
        guard case .signedIn = AppSession.shared.state else {
            return signedOutTemplate()
        }
        // Replaced by the real browse hierarchy in the CarPlay milestone; this
        // proves the scene wiring end to end in the meantime.
        let item = CPListItem(text: "Library", detailText: "Coming next")
        let section = CPListSection(items: [item])
        return CPListTemplate(title: "JellyMusic", sections: [section])
    }

    @MainActor
    private func signedOutTemplate() -> CPTemplate {
        // CarPlay forbids text entry while driving, so signing in can only happen
        // on the phone. Say so plainly instead of showing an empty list.
        CPInformationTemplate(
            title: "JellyMusic",
            layout: .leading,
            items: [
                CPInformationItem(
                    title: "Not signed in",
                    detail: "Open JellyMusic on your iPhone to connect to your Jellyfin server."
                )
            ],
            actions: []
        )
    }
}
