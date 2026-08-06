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
    @MainActor
    static func adopt(accountId: String) {
        guard let store = shared else { return }
        do {
            guard try store.adoptAccount(accountId) else { return }
            // The sync status is the account's too — "last synced 5 minutes ago" would
            // be describing a library this account has never seen.
            SyncCoordinator.shared.forgetAccountStatus()
            log.notice("Curation store belonged to another account; erased it.")
        } catch {
            log.error("Couldn't claim the curation store: \(error.localizedDescription, privacy: .public)")
        }
    }
}
