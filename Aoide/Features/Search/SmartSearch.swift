import FoundationModels
import Foundation
import JellyfinKit
import os

/// Turns a phrase like "upbeat rock from the nineties" into a `MusicQuery`.
///
/// The model's job is strictly translation: words in, filters out. It never chooses
/// tracks. That split is not stylistic — measured against this library, the on-device
/// model picked the right songs for a named genre 2–5 times out of 8, which is worse
/// than useless when the server can answer the same question exactly. Mapping a
/// phrase onto a genre name and a year range is the part it is reliably good at, and
/// Jellyfin does the selecting afterwards.
@MainActor
@Observable
final class SmartSearch {
    enum Readiness: Equatable {
        case ready
        /// Not a failure to report loudly — most devices simply don't have this.
        /// The plain search must carry on working as though this file didn't exist.
        case unavailable(String)
    }

    private let log = Logger(subsystem: "com.example.aoide", category: "smart-search")
    private let client: JellyfinClient

    /// Genre names the library actually contains, lower-cased for matching.
    ///
    /// The single biggest quality lever here. Left to itself the model invents
    /// plausible genres — "Chill", "Workout" — that match nothing on the server and
    /// return an empty list that reads as a broken feature. Giving it the real
    /// vocabulary, then discarding anything outside it, turns an open-ended guess
    /// into a closed-set choice.
    private var knownGenres: [String: String] = [:]

    init(client: JellyfinClient) {
        self.client = client
    }

    var readiness: Readiness {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .ready
        case .unavailable(.deviceNotEligible):
            return .unavailable("This iPhone doesn't support Apple Intelligence.")
        case .unavailable(.appleIntelligenceNotEnabled):
            return .unavailable("Turn on Apple Intelligence in Settings to search by description.")
        case .unavailable(.modelNotReady):
            return .unavailable("Apple Intelligence is still downloading. Try again shortly.")
        case .unavailable:
            return .unavailable("Searching by description isn't available right now.")
        }
    }

    /// Worth offering the smart path at all.
    ///
    /// One or two words is a name, and the plain search already handles names better
    /// than any interpretation of them would.
    static func looksLikeAPhrase(_ text: String) -> Bool {
        text.split(whereSeparator: \.isWhitespace).count >= 3
    }

    func loadGenresIfNeeded() async {
        guard knownGenres.isEmpty else { return }
        guard let genres = try? await client.musicGenres(limit: 200) else { return }
        knownGenres = Dictionary(
            genres.map { ($0.name.lowercased(), $0.name) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// Parses a phrase, or returns nil when nothing usable came back.
    func interpret(_ text: String) async -> MusicQuery? {
        guard readiness == .ready else { return nil }
        await loadGenresIfNeeded()

        // The on-device model's window is small; a long genre list is what stops a
        // prompt fitting, so it is retried with fewer genres, then with none.
        for genreLimit in [80, 30, 0] {
            let session = LanguageModelSession(instructions: instructions(genreLimit: genreLimit))
            do {
                let response = try await session.respond(to: text, generating: ParsedQuery.self)
                return resolve(response.content)
            } catch let error as LanguageModelSession.GenerationError {
                if case .exceededContextWindowSize = error {
                    log.warning("Search prompt too long with \(genreLimit) genres; retrying smaller")
                    continue
                }
                log.error("Smart search parse failed: \(error.localizedDescription, privacy: .public)")
                return nil
            } catch {
                log.error("Smart search parse failed: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
        return nil
    }

    private func instructions(genreLimit: Int) -> String {
        var text = """
        You convert a listener's description of music into search filters for their \
        personal music library. Extract only what the description actually states or \
        clearly implies. Leave a field empty when the description says nothing about \
        it — guessing produces filters that match nothing.

        Decades map to year ranges: "the nineties" is 1990 to 1999, "early 2000s" is \
        2000 to 2004.

        Put a name in searchTerm only when the description names a specific song, \
        album or performer. A mood or a genre is not a name.
        """

        if !knownGenres.isEmpty {
            // Capped: the whole instruction shares the model's context window with the
            // prompt, and a library with hundreds of genres would crowd out the rules
            // above — which matter more than exhaustive coverage of the tail.
            let list = knownGenres.values
                .sorted { ($0.count, $0) < ($1.count, $1) }
                .prefix(genreLimit)
                .joined(separator: ", ")
            text += "\n\nUse only these genres, exactly as spelled, or none: \(list)."
        }
        return text
    }

    /// Validates the model's output against reality before it becomes a query.
    private func resolve(_ parsed: ParsedQuery) -> MusicQuery? {
        // Genres are matched case-insensitively against the library's own list, and
        // anything unrecognised is dropped rather than passed through: an invented
        // genre doesn't narrow a search, it empties it.
        let genres = parsed.genres.compactMap { knownGenres[$0.lowercased()] }

        let query = MusicQuery(
            searchTerm: parsed.searchTerm?.trimmingCharacters(in: .whitespaces).nilIfEmpty,
            genres: genres,
            years: MusicQuery.years(from: parsed.fromYear, to: parsed.toYear),
            favoritesOnly: parsed.favoritesOnly,
            sort: parsed.ordering.sort,
            direction: parsed.ordering.direction
        )
        // An empty query means the phrase was understood as nothing at all. Running
        // it would return the library in alphabetical order dressed up as an answer.
        return query.isEmpty ? nil : query
    }
}

// MARK: - The model's output shape

@Generable
private struct ParsedQuery {
    @Guide(description: "A song, album or artist name mentioned in the description. Leave empty if it names none.")
    var searchTerm: String?

    @Guide(description: "Genres stated or clearly implied, spelled exactly as given in the instructions. Empty if none apply.")
    var genres: [String]

    @Guide(description: "Earliest release year, e.g. 1990 for 'the nineties'. Leave empty if no time period is mentioned.")
    var fromYear: Int?

    @Guide(description: "Latest release year, e.g. 1999 for 'the nineties'. Leave empty if no time period is mentioned.")
    var toYear: Int?

    @Guide(description: "True only if the description asks for favourites, loved or starred music.")
    var favoritesOnly: Bool

    @Guide(description: "The order the listener asked for, or byName when they didn't say.")
    var ordering: Ordering
}

@Generable
private enum Ordering {
    case byName
    case newestFirst
    case mostPlayed
    case recentlyPlayed
    case random

    var sort: ItemSort {
        switch self {
        case .byName: .name
        case .newestFirst: .releaseDate
        case .mostPlayed: .playCount
        case .recentlyPlayed: .datePlayed
        case .random: .random
        }
    }

    var direction: SortDirection {
        switch self {
        case .byName, .random: .ascending
        // "Newest", "most played" and "recently played" all mean the largest value
        // first; ascending would answer each of them backwards.
        case .newestFirst, .mostPlayed, .recentlyPlayed: .descending
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
