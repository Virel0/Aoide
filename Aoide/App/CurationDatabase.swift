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
}
