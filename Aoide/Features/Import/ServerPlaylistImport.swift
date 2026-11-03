import CurationKit
import Foundation
import MeleteKit
import os

/// A playlist handed whole to Melete, which makes it in the sync log with every
/// song: the ones the library has as they are, the rest waiting until they arrive.
///
/// Melete makes the playlist at once and fills it as the import runs, so this
/// follows the import and syncs as it goes, until the playlist is here and done.
/// A server before 0.4.0 refuses the request, and the caller falls back to saving
/// what was found and asking for the rest.
@MainActor
@Observable
final class ServerPlaylistImport {
    enum Phase: Equatable {
        case sending
        /// Melete is working through the songs.
        case filling(PlaylistImportSummary)
        case done(PlaylistImportSummary)
        /// This server can't make the playlist: older than 0.4.0, or the user may
        /// see only some music libraries. The two-step flow still works there.
        case unsupported
        case failed(String)
    }

    private(set) var phase: Phase = .sending
    /// The playlist, once a sync has brought it to this device.
    private(set) var playlist: Playlist?

    private let log = Logger(subsystem: AppIdentity.bundle, category: "import")
    /// How often to look at the import while it runs.
    private static let interval: Duration = .seconds(3)
    /// How long to wait for the playlist to sync in after the import is done.
    private static let syncAttempts = 10

    /// Sends every track and follows the import until the playlist is here.
    func run(name: String, tracks: [ImportedTrack], client: MeleteClient) async {
        phase = .sending
        let started: PlaylistImportSummary
        do {
            started = try await client.importPlaylist(name: name, csv: PlaylistCSV.make(tracks), makePlaylist: true)
        } catch let error as MeleteError {
            phase = Self.phase(for: error)
            return
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }
        // A server that took the import and made no playlist didn't know the field.
        guard let playlistId = started.playlistId else {
            phase = .unsupported
            return
        }
        await follow(started, playlistId: playlistId, client: client)
    }

    static func phase(for error: MeleteError) -> Phase {
        switch error {
        case .http(status: 400, _, _), .http(status: 403, _, _), .http(status: 422, _, _):
            .unsupported
        case .http(status: 409, _, _):
            .failed("Your server can't look music up: MusicBrainz is off in its settings.")
        default:
            .failed(error.errorDescription ?? "The playlist couldn't be sent to your server.")
        }
    }

    private func follow(_ started: PlaylistImportSummary, playlistId: String, client: MeleteClient) async {
        var current = started
        phase = current.isRunning ? .filling(current) : .done(current)
        SyncCoordinator.shared.syncNow()
        var attemptsLeft = Self.syncAttempts
        while !Task.isCancelled {
            try? await Task.sleep(for: Self.interval)
            if current.isRunning, let read = try? await client.playlistImports().first(where: { $0.id == current.id }) {
                if read != current { SyncCoordinator.shared.syncNow() }
                current = read
                phase = read.isRunning ? .filling(read) : .done(read)
            }
            playlist = try? CurationDatabase.shared?.playlist(playlistId)
            guard !current.isRunning else { continue }
            // Done on the server: a sync started from here on brings its last songs.
            // Stop once one has and the playlist is here, or after a while if
            // syncing can't bring it.
            if SyncCoordinator.shared.syncSoon(.manual), playlist != nil { return }
            attemptsLeft -= 1
            if attemptsLeft <= 0 {
                log.warning("Imported playlist \(playlistId, privacy: .public) hasn't synced in yet")
                return
            }
        }
    }
}
