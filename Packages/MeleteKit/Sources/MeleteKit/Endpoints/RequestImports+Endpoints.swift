import Foundation

extension MeleteClient {
    // MARK: - Playlist imports

    /// Asks for every song of a playlist: Melete matches each to a MusicBrainz
    /// recording and asks for it as this user, in the background. HTTP 400 for a
    /// file that isn't a playlist, 409 when MusicBrainz is off, 413 past 8 MB.
    public func importPlaylist(name: String, csv: String) async throws -> PlaylistImportSummary {
        struct Body: Encodable { let name: String; let csv: String }
        return try await post(path: "api/v1/requests/imports", body: Body(name: name, csv: csv))
    }

    /// This user's playlist imports, newest first (100 at most).
    public func playlistImports() async throws -> [PlaylistImportSummary] {
        try await get(path: "api/v1/requests/imports")
    }

    /// One playlist import, song by song.
    public func playlistImport(id: Int64) async throws -> PlaylistImport {
        try await get(path: "api/v1/requests/imports/\(id)")
    }

    /// Removes a playlist import, taking back its songs still waiting for an
    /// admin; approved ones still come.
    public func removePlaylistImport(id: Int64) async throws {
        try await sendIgnoringResponse("DELETE", path: "api/v1/requests/imports/\(id)")
    }
}
