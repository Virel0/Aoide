import Foundation

extension JellyfinClient {
    /// Lyrics for a track, or `nil` when the server has none.
    ///
    /// A 404 here means "this track has no lyrics", which is the common case and not
    /// an error worth surfacing. Every other failure still throws.
    ///
    /// Reading needs only a signed-in user; no special policy permission is
    /// required. (Uploading lyrics would need the lyric-management permission, which
    /// this app doesn't do.)
    public func lyrics(forItem itemId: String) async throws -> LyricsTrack? {
        do {
            // The type is passed explicitly. Inferring it from a `LyricsTrack?`
            // return would bind the generic to `Optional<…>` and decode an optional
            // at the top level — which happens to work, but only by accident.
            let document = try await get(LyricsDocument.self, path: "Audio/\(itemId)/Lyrics")
            let track = LyricsTrack(document)
            return track.isEmpty ? nil : track
        } catch JellyfinError.notFound {
            return nil
        }
    }
}
