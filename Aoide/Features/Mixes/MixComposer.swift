import CurationKit
import Foundation
import FoundationModels
import MeleteKit
import os

/// Turns "something calm I haven't heard in months" into smart playlist rules.
///
/// **The model writes rules; the rules pick the songs.** That split is the same one
/// `SmartSearch` makes and for the same measured reason — asked to choose tracks for a
/// named genre this model was right two to five times out of eight, which is worse
/// than useless when a SQL query over the local store answers exactly. Here it is
/// worth even more than it is there: a mix built from rules re-evaluates every time it
/// is opened, works with no signal, and cannot contain a song this library does not
/// have.
///
/// On-device, so a mix costs nothing and needs no account. The desktop app does the
/// same job through OpenRouter because it has no Apple Intelligence to reach for; both
/// produce the same `SmartRules` JSON, which is what makes a mix made on one appear on
/// the other as an ordinary smart playlist.
@MainActor
@Observable
final class MixComposer {
    enum Readiness: Equatable {
        case ready
        /// Not a failure to report loudly — most devices simply do not have this.
        case unavailable(String)
    }

    private let log = Logger(subsystem: AppIdentity.bundle, category: "mixes")
    private let client: MeleteClient

    /// Genre names the library actually contains, lower-cased for matching.
    ///
    /// The single biggest quality lever, exactly as in search: left to itself the model
    /// invents "Chill" and "Workout", the rules match nothing, and an empty mix reads
    /// as a broken feature rather than as a miss.
    private var knownGenres: [String: String] = [:]

    init(client: MeleteClient) {
        self.client = client
    }

    var readiness: Readiness {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .ready
        case .unavailable(.deviceNotEligible):
            return .unavailable("This iPhone doesn't support Apple Intelligence.")
        case .unavailable(.appleIntelligenceNotEnabled):
            return .unavailable("Turn on Apple Intelligence in Settings to describe a mix.")
        case .unavailable(.modelNotReady):
            return .unavailable("Apple Intelligence is still downloading. Try again shortly.")
        case .unavailable:
            return .unavailable("Describing a mix isn't available right now.")
        }
    }

    /// What a description asked for: rules the store can evaluate, and names the
    /// library can be searched for.
    ///
    /// The names are the half the rules cannot express. "Helldivers 2 session
    /// music" names a game whose soundtrack may well be in the library; no genre
    /// rule will find it, but a search for "Helldivers" will. Both halves are kept,
    /// and the screen unions what each finds.
    struct Plan {
        /// One rule set per genre the mood implied, each carrying the shared
        /// history rules — because a rule set has one match mode, and "rock or
        /// metal, and not played in months" needs *or* for the genres and *and*
        /// for the rest. Evaluated separately and unioned by the screen.
        var rules: [SmartRules]
        var names: [String]
        /// The library genres the mood resolved to, for the screen to say.
        var genres: [String] = []
        var isEmpty: Bool { rules.isEmpty && names.isEmpty }
    }

    /// Why the last `compose` produced nothing, in the model's words.
    private(set) var lastProblem: String?

    /// A plan for a description, or nil when the model produced nothing usable.
    ///
    /// Never throws at the caller: a mix that cannot be described is a screen that says
    /// so, not an error dialog over a music player.
    func compose(_ description: String) async -> Plan? {
        guard readiness == .ready else { return nil }
        await loadGenresIfNeeded()

        // The on-device model's window is small. A long genre list is the usual
        // reason the prompt stops fitting, so it is retried with fewer genres and
        // then with none, rather than failing on a library that happens to be
        // richly tagged.
        var described: DescribedMix?
        var lastError: (any Error)?
        for genreLimit in [80, 30, 0] {
            let session = LanguageModelSession(instructions: instructions(genreLimit: genreLimit))
            do {
                described = try await session.respond(to: description, generating: DescribedMix.self).content
                break
            } catch let error as LanguageModelSession.GenerationError {
                lastError = error
                if case .exceededContextWindowSize = error {
                    log.warning("Mix prompt too long with \(genreLimit) genres; retrying smaller")
                    continue
                }
                break
            } catch {
                lastError = error
                break
            }
        }
        do {
            guard let described else { throw lastError ?? CancellationError() }
            let (rules, genres) = resolve(described)
            let plan = Plan(
                rules: rules,
                names: described.names.map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.count >= 2 },
                genres: genres
            )
            lastProblem = plan.isEmpty
                ? "The model answered with genres this library doesn't have: \(described.genres.joined(separator: ", "))."
                : nil
            return plan.isEmpty ? nil : plan
        } catch {
            log.error("Mix compose failed: \(error.localizedDescription, privacy: .public)")
            lastProblem = error.localizedDescription
            return nil
        }
    }

    private func loadGenresIfNeeded() async {
        guard knownGenres.isEmpty else { return }
        guard let genres = try? await client.musicGenres(limit: 200) else { return }
        knownGenres = Dictionary(
            genres.map { ($0.name.lowercased(), $0.name) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private func instructions(genreLimit: Int) -> String {
        var text = """
        You turn a description of a mood into rules for selecting music from a personal \
        library. You never choose songs; the rules do.

        Express mood through listening history wherever you can. "Something I haven't \
        heard in ages" is a track not played in the last six months. "My favourites" is \
        a high play count, or liked. "Something new to me" is a play count of zero.

        Decades map to year ranges: "the nineties" is 1990 to 1999.

        When the description names a particular artist, album, band, game, film or \
        show, put that name in "names" exactly as written; the library will be \
        searched for it. Then ALSO describe the mood that thing implies, using \
        genres from the list: a war game or an action film implies driving genres \
        (rock, metal, electronic, soundtrack); a study session, a farming or \
        building game implies calm ones (lo-fi, ambient, jazz, classical, folk). \
        Someone naming a game wants music that fits playing it, not only its \
        soundtrack. Prefer two or three genres to one.

        Leave a field empty when the description says nothing about it. Guessing \
        produces rules that match nothing, which reads as the feature being broken.
        """

        if !knownGenres.isEmpty, genreLimit > 0 {
            // Capped: the instruction shares a context window with the description,
            // and a library with hundreds of genres would crowd out the rules above,
            // which matter more. Long names are the costly ones, so they go last.
            let list = knownGenres.values
                .sorted { ($0.count, $0) < ($1.count, $1) }
                .prefix(genreLimit)
                .joined(separator: ", ")
            text += "\n\nUse only these genres, exactly as spelled, or none: \(list)."
        }
        return text
    }

    /// Turns the model's answer into rules, keeping only what the store can evaluate.
    ///
    /// Every rule is built through `SmartRule.init`, which refuses an illegal
    /// field/operator pair — so a model that asks for a title in the last six months
    /// loses that clause rather than producing a playlist that is silently empty.
    /// Library genres that mean what a described genre means.
    ///
    /// Word-boundary containment, either way: "rock" takes "Rock", "Hard Rock"
    /// and "Alternative Rock" but not "Rockabilly"; "alternative rock" takes
    /// "Rock". Lower-cased, punctuation ignored.
    static func libraryGenres(matching described: String, in library: [String]) -> [String] {
        func words(_ text: String) -> [String] {
            text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        }
        let wanted = words(described)
        guard !wanted.isEmpty else { return [] }
        return library.filter { candidate in
            let have = words(candidate)
            guard !have.isEmpty else { return false }
            return wanted.allSatisfy { have.contains($0) } || have.allSatisfy { wanted.contains($0) }
        }.sorted()
    }

    /// One line saying what the model understood, for the screen to show. A mix
    /// that came back empty is explained by this line or by nothing.
    static func summary(of plan: Plan) -> String {
        var parts: [String] = []
        if !plan.names.isEmpty { parts.append(plan.names.joined(separator: ", ")) }
        if !plan.genres.isEmpty { parts.append(plan.genres.joined(separator: ", ")) }
        let extra = plan.rules.first?.rules.filter { $0.field != .genre } ?? []
        for rule in extra {
            switch (rule.field, rule.op) {
            case (.lastPlayed, .notInTheLast): parts.append("not played lately")
            case (.playCount, .is): parts.append("never played")
            case (.playCount, .greaterThan): parts.append("well played")
            case (.liked, _): parts.append("favourites")
            case (.year, .greaterThan): if case .number(let y) = rule.value { parts.append("after \(y)") }
            case (.year, .lessThan): if case .number(let y) = rule.value { parts.append("before \(y)") }
            default: break
            }
        }
        return parts.isEmpty ? "anything" : parts.joined(separator: " · ")
    }

    private func resolve(_ described: DescribedMix) -> (rules: [SmartRules], genres: [String]) {
        var rules: [SmartRule] = []

        // Matched to the library's own genres by word: the model's "rock" is the
        // library's "Rock", "Hard Rock" and "Alternative Rock", its "soundtrack"
        // is "Video Game Soundtrack". Anything the library does not have in any
        // spelling is dropped — an invented genre matches nothing, and a mix of
        // nothing is indistinguishable from a broken one.
        var genres: [String] = []
        for described in described.genres {
            for match in Self.libraryGenres(matching: described, in: Array(knownGenres.values)) where !genres.contains(match) {
                genres.append(match)
            }
        }

        if let from = described.fromYear, from > 1860 {
            // `greaterThan` is exclusive, and a listener asking for the nineties means
            // 1990 included.
            if let rule = try? SmartRule(field: .year, op: .greaterThan, value: .number(from - 1)) {
                rules.append(rule)
            }
        }
        if let to = described.toYear, to > 1860 {
            if let rule = try? SmartRule(field: .year, op: .lessThan, value: .number(to + 1)) {
                rules.append(rule)
            }
        }

        if described.favouritesOnly,
           let rule = try? SmartRule(field: .liked, op: .is, value: .flag(true)) {
            rules.append(rule)
        }

        if let months = described.notPlayedInMonths, months > 0,
           let rule = try? SmartRule(
               field: .lastPlayed, op: .notInTheLast, value: .text("-\(months)m")
           ) {
            rules.append(rule)
        }

        if described.unheardOnly,
           let rule = try? SmartRule(field: .playCount, op: .is, value: .number(0)) {
            rules.append(rule)
        }

        if let plays = described.minimumPlayCount, plays > 0,
           let rule = try? SmartRule(
               field: .playCount, op: .greaterThan, value: .number(plays - 1)
           ) {
            rules.append(rule)
        }

        let limit = max(10, min(described.length ?? 40, 200))

        // One rule set per genre, each with the shared rules; genres are *or*, the
        // rest *and*. With no genre, one set of the shared rules — "all of nothing"
        // being the whole library, which is a real mix: "anything, forty tracks".
        // A description that was only names gets no rules at all, or the entire
        // library would be poured in beside the search.
        if genres.isEmpty {
            guard !rules.isEmpty || described.length != nil else { return ([], []) }
            return ([try? SmartRules(match: .all, rules: rules, limit: limit)].compactMap { $0 }, [])
        }
        let sets = genres.compactMap { genre -> SmartRules? in
            guard let genreRule = try? SmartRule(field: .genre, op: .is, value: .text(genre)) else { return nil }
            // Each set takes its share, so a three-genre mix is not forty of the first.
            return try? SmartRules(match: .all, rules: [genreRule] + rules, limit: max(10, limit / genres.count + 1))
        }
        return (sets, genres)
    }
}

/// The shape the model fills in.
///
/// Deliberately not `SmartRules` itself. A generable type describing arbitrary
/// field/operator/value triples invites the model to spell combinations that do not
/// exist, and every one of those becomes a clause silently dropped. Naming the handful
/// of things a mood can actually mean keeps the model inside the closed set, and the
/// translation into rules happens here where it can be checked.
@Generable
private struct DescribedMix {
    @Guide(description: "Genres stated or clearly implied, spelled exactly as given in the instructions. Empty if none apply.")
    var genres: [String]

    @Guide(description: "Earliest release year, e.g. 1990 for 'the nineties'. Leave empty if no time period is mentioned.")
    var fromYear: Int?

    @Guide(description: "Latest release year, e.g. 1999 for 'the nineties'. Leave empty if no time period is mentioned.")
    var toYear: Int?

    @Guide(description: "True only if the description asks for favourites, loved or starred music.")
    var favouritesOnly: Bool

    @Guide(description: "Set only when the description asks for music not heard for a while, as a number of months.")
    var notPlayedInMonths: Int?

    @Guide(description: "True only if the description asks for music never listened to before.")
    var unheardOnly: Bool

    @Guide(description: "Set only when the description asks for well-played or familiar music: the fewest plays a track should have.")
    var minimumPlayCount: Int?

    @Guide(description: "How many tracks the mix should hold. Leave empty for a normal-length mix.")
    var length: Int?

    @Guide(description: "Artists, albums, bands, games, films or shows the description names, spelled exactly as written. Empty if it names none.")
    var names: [String]
}
