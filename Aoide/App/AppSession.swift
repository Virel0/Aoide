import Foundation
import MeleteKit
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
        case signedIn(MeleteUser)
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

    private static let log = Logger(subsystem: AppIdentity.bundle, category: "session")

    private(set) var state: State = .loading
    private(set) var client: MeleteClient?

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

    /// A stable per-install identifier: what sync names this device by, so it must
    /// survive app launches.
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

        let credentials = MeleteCredentials(
            serverURL: serverURL,
            userId: userId,
            username: username,
            accessToken: token
        )
        let restored = MeleteClient(serverURL: serverURL, device: Self.deviceProfile)
            .authenticated(as: credentials)
        client = restored
        // Before anything can read a row or queue an op, so a store left behind by a
        // different account is gone rather than being pushed into this one's log.
        CurationDatabase.adopt(accountId: Self.storeOwner(userId: userId, serverURL: serverURL))
        MeletePlaybackBridge.connect(client: restored)
        SyncCoordinator.shared.connect(client: restored)
        state = .signedIn(MeleteUser(id: userId, name: username))
    }

    /// Whose the local store is: one per user per server, since Melete numbers
    /// its users from 1 on every server.
    static func storeOwner(userId: String, serverURL: URL) -> String {
        "\(userId)@\(serverURL.absoluteString)"
    }

    func signIn(serverAddress: String, username: String, password: String) async throws {
        let serverURL = try MeleteClient.normalizeServerURL(serverAddress)
        let anonymous = MeleteClient(serverURL: serverURL, device: Self.deviceProfile)

        // Probe first: a wrong address should say "that isn't a Melete server"
        // rather than "your password was rejected".
        _ = try await anonymous.serverInfo()

        let (credentials, user) = try await anonymous.signIn(username: username, password: password)
        try keep(credentials, user, from: anonymous)
    }

    /// Finishes a sign-in that ``signIn(serverAddress:username:password:)`` left
    /// waiting with `.secondFactorNeeded`: the challenge, and the code from the
    /// user's authenticator app. The challenge isn't tied to a client, so a new
    /// one for the same server finishes it.
    func finishSignIn(serverAddress: String, challenge: String, code: String) async throws {
        let serverURL = try MeleteClient.normalizeServerURL(serverAddress)
        let anonymous = MeleteClient(serverURL: serverURL, device: Self.deviceProfile)
        let (credentials, user) = try await anonymous.finishSignIn(challenge: challenge, code: code)
        try keep(credentials, user, from: anonymous)
    }

    /// Quick Connect's first half: the address is checked and a code made for this
    /// device, to show until someone approves it in Melete's web UI.
    func startQuickConnect(serverAddress: String) async throws -> (client: MeleteClient, code: QuickConnectCode) {
        let serverURL = try MeleteClient.normalizeServerURL(serverAddress)
        let anonymous = MeleteClient(serverURL: serverURL, device: Self.deviceProfile)
        _ = try await anonymous.serverInfo()
        return (anonymous, try await anonymous.startQuickConnect())
    }

    /// Quick Connect's second half, asked every few seconds: false while the code
    /// waits; once approved, signs in as signing in with a password does.
    func pollQuickConnect(client anonymous: MeleteClient, secret: String) async throws -> Bool {
        guard let (credentials, user) = try await anonymous.pollQuickConnect(secret: secret) else { return false }
        try keep(credentials, user, from: anonymous)
        return true
    }

    /// Keeps a new session: the token in the keychain, the profile on disk, and the
    /// app connected to it.
    private func keep(_ credentials: MeleteCredentials, _ user: MeleteUser, from anonymous: MeleteClient) throws {
        let serverURL = anonymous.serverURL
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
        CurationDatabase.adopt(accountId: Self.storeOwner(userId: credentials.userId, serverURL: serverURL))
        MeletePlaybackBridge.connect(client: authenticated)
        SyncCoordinator.shared.connect(client: authenticated)
        state = .signedIn(user)
    }

    /// The stored token is no longer accepted — the password changed, or the session
    /// was signed out from Melete's web UI.
    ///
    /// Without this the app sat on a signed-in shell showing "Your username or
    /// password wasn't accepted" on every screen, with no route back to the login
    /// form. Idempotent because several requests 401 at once.
    func invalidateSession() {
        guard case .signedIn = state else { return }
        Self.log.error("Access token rejected; signing out.")

        // Disconnect first, exactly as signOut does: otherwise the engine keeps a
        // queue of 401ing streams, with the mini player gone and no way to stop it.
        MeletePlaybackBridge.disconnect()
        SyncCoordinator.shared.disconnect()
        DiscoverStore.shared.clear()
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
        Self.log.info("Signing out")
        // Stop the music before the token goes away.
        MeletePlaybackBridge.disconnect()

        // Not "sync one last time first". Signing out must never block on the
        // network, and it does not need to: unpushed ops stay in the queue, and
        // signing back in as the same person sends them. Only signing in as somebody
        // *else* discards them, which is the one case where they are no longer this
        // device's business.
        SyncCoordinator.shared.disconnect()

        // The screen leaves *now*. The server is told afterwards, on its own,
        // with a few seconds to answer: a logout that waited for the request
        // first sat on the settings screen for as long as an unreachable server
        // took to time out, which read as the button doing nothing.
        let departing = client
        DiscoverStore.shared.clear()
        clearStoredCredentials()
        clearSpotlightIndex()
        client = nil
        state = .signedOut

        Task.detached {
            try? await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await departing?.signOut() }
                group.addTask {
                    try await Task.sleep(for: .seconds(5))
                    throw CancellationError()
                }
                try await group.next()
                group.cancelAll()
            }
        }
    }
}
