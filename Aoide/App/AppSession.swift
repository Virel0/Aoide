import Foundation
import JellyfinKit
import UIKit
import os

/// Owns "who are we signed in as, and against which server".
///
/// Deliberately a singleton: the CarPlay scene and the phone UI are separate scenes
/// that must resolve to the *same* session and the same playback engine, so a car
/// screen and a phone screen never disagree about what's playing.
@MainActor
@Observable
final class AppSession {
    static let shared = AppSession()

    enum State: Equatable {
        case loading
        case signedOut
        case signedIn(JellyfinUser)
    }

    enum SessionError: LocalizedError {
        case couldNotStoreCredentials

        var errorDescription: String? {
            switch self {
            case .couldNotStoreCredentials:
                "Signed in, but this device wouldn't save the login securely. Check Console for a keychain error."
            }
        }
    }

    private static let log = Logger(subsystem: "com.example.aoide", category: "session")

    private(set) var state: State = .loading
    private(set) var client: JellyfinClient?

    /// The address this device last signed in to. Deliberately not among `Keys`:
    /// signing out clears the session, but the sign-in screen should still offer the
    /// server somebody is about to type again.
    static let lastServerAddressKey = "aoide.lastServerAddress"

    private enum Keys {
        static let deviceId = "aoide.deviceId"
        static let serverURL = "aoide.serverURL"
        static let userId = "aoide.userId"
        static let username = "aoide.username"
        static let token = "aoide.accessToken"
    }

    private init() {}

    /// A stable per-install identifier. Jellyfin keys playback sessions off this, so
    /// it must survive app launches — regenerating it every launch would litter the
    /// server's dashboard with a new "device" each time.
    static var deviceId: String {
        if let existing = UserDefaults.standard.string(forKey: Keys.deviceId) {
            return existing
        }
        let generated = UUID().uuidString
        UserDefaults.standard.set(generated, forKey: Keys.deviceId)
        return generated
    }

    static var deviceProfile: DeviceProfile {
        DeviceProfile(
            client: "Aoide",
            device: UIDevice.current.name,
            deviceId: deviceId,
            version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        )
    }

    // MARK: - Lifecycle

    /// Restores a previous session from disk + keychain. Called once at launch, and
    /// again by the CarPlay scene in case the car connected before the phone UI ran.
    func restore() {
        guard case .loading = state else { return }

        let urlString = UserDefaults.standard.string(forKey: Keys.serverURL)
        let userId = UserDefaults.standard.string(forKey: Keys.userId)
        let username = UserDefaults.standard.string(forKey: Keys.username)
        let token = KeychainStore.get(forKey: Keys.token)

        guard
            let urlString, let serverURL = URL(string: urlString),
            let userId, let username, let token
        else {
            // Having the profile but not the token means the keychain lost the
            // secret — worth saying out loud, because it looks identical to a
            // normal first launch from the outside.
            if urlString != nil, token == nil {
                let who = username ?? "?"
                Self.log.error("Stored profile for \(who, privacy: .public) but no keychain token; signing out.")
            }
            state = .signedOut
            return
        }

        let credentials = JellyfinCredentials(
            serverURL: serverURL,
            userId: userId,
            username: username,
            accessToken: token
        )
        let restored = JellyfinClient(serverURL: serverURL, device: Self.deviceProfile)
            .authenticated(as: credentials)
        client = restored
        // Before anything can read a row or queue an op, so a store left behind by a
        // different account is gone rather than being pushed into this one's log.
        CurationDatabase.adopt(accountId: userId)
        JellyfinPlaybackBridge.connect(client: restored)
        SyncCoordinator.shared.connect(client: restored)
        state = .signedIn(JellyfinUser(id: userId, name: username, serverId: nil))
    }

    func signIn(serverAddress: String, username: String, password: String) async throws {
        let serverURL = try JellyfinClient.normalizeServerURL(serverAddress)
        let anonymous = JellyfinClient(serverURL: serverURL, device: Self.deviceProfile)

        // Probe first: a wrong address should say "that isn't a Jellyfin server"
        // rather than "your password was rejected".
        _ = try await anonymous.systemInfo()

        let (credentials, user) = try await anonymous.signIn(username: username, password: password)

        // The token goes in first and its failure is fatal to signing in. Writing
        // the other three and then discovering we can't keep the secret would leave
        // a half-signed-in state that looks fine until the next launch.
        guard KeychainStore.set(credentials.accessToken, forKey: Keys.token) else {
            throw SessionError.couldNotStoreCredentials
        }
        UserDefaults.standard.set(serverURL.absoluteString, forKey: Keys.serverURL)
        UserDefaults.standard.set(serverURL.absoluteString, forKey: Self.lastServerAddressKey)
        UserDefaults.standard.set(credentials.userId, forKey: Keys.userId)
        UserDefaults.standard.set(credentials.username, forKey: Keys.username)

        let authenticated = anonymous.authenticated(as: credentials)
        client = authenticated
        CurationDatabase.adopt(accountId: credentials.userId)
        JellyfinPlaybackBridge.connect(client: authenticated)
        SyncCoordinator.shared.connect(client: authenticated)
        state = .signedIn(user)
    }

    /// The stored token is no longer accepted — the password changed, or the device
    /// was removed from Jellyfin's dashboard, which is how a shared TestFlight build
    /// gets de-authorised.
    ///
    /// Without this the app sat on a signed-in shell showing "Your username or
    /// password wasn't accepted" on every screen, with no route back to the login
    /// form. Idempotent because several requests 401 at once.
    func invalidateSession() {
        guard case .signedIn = state else { return }
        Self.log.error("Access token rejected; signing out.")

        // Disconnect first, exactly as signOut does: otherwise the engine keeps a
        // queue of 401ing URLs and a reporter posting to a session that no longer
        // exists, with the mini player gone and no way to stop it.
        JellyfinPlaybackBridge.disconnect()
        SyncCoordinator.shared.disconnect()
        clearStoredCredentials()
        clearSpotlightIndex()
        client = nil
        state = .signedOut
    }

    /// Spotlight entries outlive the session that published them, so they have to
    /// be withdrawn explicitly — otherwise one account's albums stay searchable from
    /// the Home Screen after somebody else signs in.
    private func clearSpotlightIndex() {
        Task { await SpotlightIndexer.shared.clear() }
    }

    private func clearStoredCredentials() {
        KeychainStore.remove(forKey: Keys.token)
        UserDefaults.standard.removeObject(forKey: Keys.serverURL)
        UserDefaults.standard.removeObject(forKey: Keys.userId)
        UserDefaults.standard.removeObject(forKey: Keys.username)
    }

    func signOut() async {
        // Stop the music and drop the reporter before the token goes away, so the
        // server doesn't keep showing a session that no longer exists.
        JellyfinPlaybackBridge.disconnect()

        // Not "sync one last time first". Signing out must never block on the
        // network, and it does not need to: unpushed ops stay in the queue, and
        // signing back in as the same person sends them. Only signing in as somebody
        // *else* discards them, which is the one case where they are no longer this
        // device's business.
        SyncCoordinator.shared.disconnect()

        // Tell the server if we can, but never let a network failure trap someone
        // in a signed-in state they're trying to leave.
        try? await client?.signOut()

        clearStoredCredentials()
        clearSpotlightIndex()
        client = nil
        state = .signedOut
    }
}
