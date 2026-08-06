import CurationKit
import Foundation
import os

/// The app's single curation store.
///
/// Lives in Application Support rather than Caches: this is the only copy of the
/// listener's playlists and history until the sidecar exists, and the system may
/// evict Caches whenever it likes.
enum CurationDatabase {
    private static let log = Logger(subsystem: "com.example.aoide", category: "curation")

    // `AppSession.deviceId` is main-actor isolated, so this can't be a lazy global
    // initialised from whichever thread touches it first. Built explicitly on the
    // main actor at launch instead.
    @MainActor private(set) static var shared: CurationStore?

    /// Idempotent: called at launch, before anything can play. Reopening would hand out
    /// a second connection to the same file behind the recorder's back.
    @MainActor
    static func open() {
        guard shared == nil else { return }
        do {
            let directory = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("curation.sqlite")
            let store = try CurationStore(url: url, deviceId: AppSession.deviceId)
            log.info("Curation store opened at \(url.lastPathComponent, privacy: .public)")
            shared = store
        } catch {
            // Left nil rather than trapping: a corrupt store must not stop the app
            // playing music, which still works entirely from Jellyfin.
            log.error("Couldn't open the curation store: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Hands the store to a Jellyfin account, erasing it first if it belonged to
    /// somebody else.
    ///
    /// Called before the session is announced as signed in, so nothing has read a row
    /// or queued an op against the wrong account's data. The erasure itself, and why
    /// it happens on the way in rather than on sign-out, is in
    /// `CurationStore.adoptAccount`.
    /// Set when the store predates account claims and already holds data, so only a
    /// person can say whose it is. `RootView` presents the question.
    @MainActor private(set) static var unclaimedStoreOwner: String?

    @MainActor
    static func adopt(accountId: String) {
        guard let store = shared else { return }
        do {
            switch try store.adoptAccount(accountId) {
            case .unchanged:
                return
            case .erased:
                // The sync status is the account's too — "last synced 5 minutes ago"
                // would be describing a library this account has never seen.
                SyncCoordinator.shared.forgetAccountStatus()
                log.notice("Curation store belonged to another account; erased it.")
            case .unknownOwner:
                // Deliberately left unclaimed until answered. Claiming it now and
                // asking afterwards would let a sync push one person's library into
                // another person's log before they had a chance to say no.
                unclaimedStoreOwner = accountId
                log.notice("Curation store predates account claims and holds data; asking.")
            }
        } catch {
            log.error("Couldn't claim the curation store: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The person says the existing playlists and history are theirs.
    @MainActor
    static func keepUnclaimedStore() {
        guard let store = shared, let accountId = unclaimedStoreOwner else { return }
        try? store.keepAndClaim(accountId: accountId)
        unclaimedStoreOwner = nil
    }

    /// The person says it is somebody else's.
    @MainActor
    static func eraseUnclaimedStore() {
        guard let store = shared, let accountId = unclaimedStoreOwner else { return }
        try? store.eraseAndClaim(accountId: accountId)
        SyncCoordinator.shared.forgetAccountStatus()
        unclaimedStoreOwner = nil
    }
}
