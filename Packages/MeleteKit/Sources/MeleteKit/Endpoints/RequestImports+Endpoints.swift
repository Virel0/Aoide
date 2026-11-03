import Foundation

extension MeleteClient {
    // MARK: - Playlist imports

    /// Asks for every song of a playlist: Melete matches each to a MusicBrainz
    /// recording and asks for it as this user, in the background. HTTP 400 for a
    /// file that isn't a playlist, 409 when MusicBrainz is off, 413 past 8 MB.
    ///
    /// With `makePlaylist`, Melete also makes an Aoide playlist of it, named as the
    /// import is (`playlistId`), holding every song in the file's order: the ones
    /// the library has as they are, the rest waiting until they arrive. Melete 0.4.0
    /// and later; an older one refuses the field (HTTP 400 or 422), and one serving
    /// a user who may see only some music libraries answers 403.
    public func importPlaylist(name: String, csv: String, makePlaylist: Bool = false) async throws -> PlaylistImportSummary {
        struct Body: Encodable {
            let name: String
            let csv: String
            /// Left out unless asked for, so an older server still takes the import.
            let makePlaylist: Bool?
        }
        let body = Body(name: name, csv: csv, makePlaylist: makePlaylist ? true : nil)
        return try await post(path: "api/v1/requests/imports", body: body)
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
