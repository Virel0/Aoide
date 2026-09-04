import CurationKit
import Foundation
import FoundationModels
import JellyfinKit
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

    private let log = Logger(subsystem: "com.example.aoide", category: "mixes")
    private let client: JellyfinClient

    /// Genre names the library actually contains, lower-cased for matching.
    ///
    /// The single biggest quality lever, exactly as in search: left to itself the model
    /// invents "Chill" and "Workout", the rules match nothing, and an empty mix reads
    /// as a broken feature rather than as a miss.
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
        var rules: SmartRules?
        var names: [String]
        var isEmpty: Bool { rules == nil && names.isEmpty }
    }

    /// A plan for a description, or nil when the model produced nothing usable.
    ///
    /// Never throws at the caller: a mix that cannot be described is a screen that says
    /// so, not an error dialog over a music player.
    func compose(_ description: String) async -> Plan? {
        guard readiness == .ready else { return nil }
        await loadGenresIfNeeded()

        let session = LanguageModelSession(instructions: instructions)
        do {
            let response = try await session.respond(to: description, generating: DescribedMix.self)
            let described = response.content
            let plan = Plan(
                rules: resolve(described),
                names: described.names.map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.count >= 2 }
            )
            return plan.isEmpty ? nil : plan
        } catch {
            log.error("Mix compose failed: \(error.localizedDescription, privacy: .public)")
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

    private var instructions: String {
        var text = """
        You turn a description of a mood into rules for selecting music from a personal \
        library. You never choose songs; the rules do.

        Express mood through listening history wherever you can. "Something I haven't \
        heard in ages" is a track not played in the last six months. "My favourites" is \
        a high play count, or liked. "Something new to me" is a play count of zero.

        Decades map to year ranges: "the nineties" is 1990 to 1999.

        When the description names a particular artist, album, band, game, film or \
        show, put that name in "names" exactly as written; the library will be \
        searched for it. Do not turn a name into a genre.

        Leave a field empty when the description says nothing about it. Guessing \
        produces rules that match nothing, which reads as the feature being broken.
        """

        if !knownGenres.isEmpty {
            // Capped for the same reason as search: the instruction shares a context
            // window with the description, and a library with hundreds of genres would
            // crowd out the rules above, which matter more.
            let list = knownGenres.values.sorted().prefix(80).joined(separator: ", ")
            text += "\n\nUse only these genres, exactly as spelled, or none: \(list)."
        }
        return text
    }

    /// Turns the model's answer into rules, keeping only what the store can evaluate.
    ///
    /// Every rule is built through `SmartRule.init`, which refuses an illegal
    /// field/operator pair — so a model that asks for a title in the last six months
    /// loses that clause rather than producing a playlist that is silently empty.
    private func resolve(_ described: DescribedMix) -> SmartRules? {
        var rules: [SmartRule] = []

        for name in described.genres {
            // Discarded unless the library really has it. An invented genre matches
            // nothing, and a mix of nothing is indistinguishable from a broken one.
            guard let genre = knownGenres[name.lowercased()] else { continue }
            if let rule = try? SmartRule(field: .genre, op: .is, value: .text(genre)) {
                rules.append(rule)
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

        // A description that was only names — "the Helldivers soundtrack" — has no
        // rules, and "all of nothing" here would be the entire library poured in
        // beside the search. Rules are only offered when the model set at least one.
        guard !rules.isEmpty || described.length != nil else { return nil }

        // `all` of nothing is the whole library, which is a real mix — "anything, forty
        // tracks". `any` of nothing can only ever be empty, so `SmartRules` refuses it
        // and this never asks for it.
        return try? SmartRules(
            match: .all,
            rules: rules,
            limit: max(10, min(described.length ?? 40, 200))
        )
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
