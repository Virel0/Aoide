import Foundation

extension MusicQuery {
    /// Only the parts of this query the listener's own words say.
    ///
    /// A model asked to turn "Karma Police Radiohead" into filters may skip the
    /// name and answer with a genre it associates with the band; run, that lists
    /// every song in the genre, which reads as random results for a song that
    /// simply isn't in the library. So a genre is kept only when the phrase names
    /// it, years only when it has a number or a decade, "liked only" only when it
    /// says so, and a search term only when it's in the phrase.
    public func grounded(in phrase: String) -> MusicQuery {
        let words = Self.words(phrase)
        let padded = " \(words.joined(separator: " ")) "
        func said(_ text: String) -> Bool {
            let wanted = Self.words(text)
            guard !wanted.isEmpty else { return false }
            // "Hip-Hop" is said by "hip hop" and by "hiphop".
            return padded.contains(" \(wanted.joined(separator: " ")) ") || words.contains(wanted.joined())
        }
        var grounded = self
        grounded.searchTerm = searchTerm.flatMap { said($0) ? $0 : nil }
        grounded.genres = genres.filter(said)
        if !phrase.contains(where: \.isNumber), words.allSatisfy({ !Self.decadeWords.contains($0) }) {
            grounded.years = []
        }
        grounded.favoritesOnly = favoritesOnly && words.contains { Self.likeWords.contains($0) }
        return grounded
    }

    private static let decadeWords: Set<String> = [
        "twenties", "thirties", "forties", "fifties", "sixties", "seventies", "eighties", "nineties",
        "noughties", "decade", "century",
    ]

    private static let likeWords: Set<String> = [
        "favourite", "favourites", "favorite", "favorites", "loved", "liked", "likes", "starred", "hearted",
    ]

    /// Lowercased words without accents or punctuation.
    private static func words(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }
}
