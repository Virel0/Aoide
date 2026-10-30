import Foundation

extension MeleteClient {
    /// Lyrics for a track, or `nil` when the server has none.
    ///
    /// A 404 here means "this track has no lyrics", which is the common case and not
    /// an error worth surfacing. Every other failure still throws.
    ///
    public func lyrics(forItem itemId: String) async throws -> LyricsTrack? {
        do {
            // The type is passed explicitly. Inferring it from a `LyricsTrack?`
            // return would bind the generic to `Optional<…>` and decode an optional
            // at the top level — which happens to work, but only by accident.
            let document = try await get(LyricsDocument.self, path: "api/v1/music/tracks/\(itemId)/lyrics")
            let track = LyricsTrack(document)
            return track.isEmpty ? nil : track
        } catch MeleteError.notFound {
            return nil
        }
    }
}
