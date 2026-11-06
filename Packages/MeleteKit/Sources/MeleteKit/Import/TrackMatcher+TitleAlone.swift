import Foundation

/// A song whose artist is only a guess, found in the library by its title alone.
///
/// A YouTube video whose title doesn't name its artist is credited to its channel,
/// which may be a label's ("Ubisoft Music") rather than the artist's. The library's
/// copy, credited to the real artist, then fails the artist test, and the song
/// would be reported missing and asked for again. So a track marked
/// `artistFromChannel` that nothing matched is looked up once more by title: when
/// every library song with exactly that title (as `normalize` spells it) is by the
/// same artist, that song is it, and the track takes the library's artists, so the
/// server's own match, when the playlist is saved, finds the same song. Songs of
/// that title by different artists are no answer: which one the video is can't be
/// told. Aoide for Linux's `import/title_alone.rs` follows the same rule.
extension TrackMatcher {
    /// The candidate `track` is by its title alone, when its artist is only a guess
    /// and every candidate with exactly its title is by the same (first) artist.
    public static func byTitleAlone(for track: ImportedTrack, among candidates: [Candidate]) -> Int? {
        guard track.artistFromChannel else { return nil }
        let title = normalize(track.title)
        let same = candidates.indices.filter { normalize(candidates[$0].title) == title }
        guard let first = same.first else { return nil }
        let artist = { (index: Int) in candidates[index].artists.first.map(normalize) }
        return same.allSatisfy { artist($0) == artist(first) } ? first : nil
    }

    /// `track` looked up by its title alone through `search` (the library's song
    /// search, nil when it fails), each of `searchTerms` in turn: the song found and
    /// the track with the song's artists, or nil.
    public static func findByTitleAlone<Item: Sendable>(
        _ track: ImportedTrack,
        search: @Sendable (String) async -> [Item]?,
        candidate: @Sendable (Item) -> Candidate
    ) async -> (track: ImportedTrack, item: Item)? {
        guard track.artistFromChannel else { return nil }
        for term in searchTerms(for: track.title) {
            guard let items = await search(String(term.prefix(60))) else { continue }
            let candidates = items.map(candidate)
            guard let index = byTitleAlone(for: track, among: candidates) else { continue }
            var found = track
            found.artists = candidates[index].artists
            found.artistFromChannel = false
            return (found, items[index])
        }
        return nil
    }
}
