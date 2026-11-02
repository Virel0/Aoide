import CurationKit
import Foundation
import MeleteKit
import os

/// Turns "something calm I haven't heard in months" into smart playlist rules.
///
/// **The model writes rules; the rules pick the songs.** That split is the same one
/// `SmartSearch` makes and for the same measured reason — asked to choose tracks for a
/// named genre a model was right two to five times out of eight, which is worse
/// than useless when a SQL query over the local store answers exactly. Here it is
/// worth even more than it is there: a mix built from rules re-evaluates every time it
/// is opened, works with no signal, and cannot contain a song this library does not
/// have.
///
/// Melete writes the rules, through OpenRouter, in the `SmartRules` JSON this app
/// and the Linux one both keep — which is what makes a mix made on one appear on the
/// other as an ordinary smart playlist.
@MainActor
@Observable
final class MixComposer {
    enum Readiness: Equatable {
        case ready
        /// Not a failure to report loudly: the server simply doesn't offer this.
        case unavailable(String)
    }

    static let aiOff = "Your server has AI features off."
    /// A Melete older than its music AI answers 404 to it.
    static let aiMissing = "Your server doesn't have AI mixes yet."

    private let log = Logger(subsystem: AppIdentity.bundle, category: "mixes")
    private let client: MeleteClient

    /// Ready until the server says it has AI off.
    private(set) var readiness: Readiness = .ready

    init(client: MeleteClient) {
        self.client = client
    }

    /// Asks the server whether it has AI on. An answer that can't be had leaves
    /// the button, and making a mix then says what went wrong.
    func checkServer() async {
        do {
            if try await !client.aiEnabled() { readiness = .unavailable(Self.aiOff) }
        } catch let error as MeleteError where error.meansAIOff {
            readiness = .unavailable(Self.unavailable(error))
        } catch {
            log.info("AI check failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// What to say when a failure means the server has no AI mixes.
    private static func unavailable(_ error: MeleteError) -> String {
        if case .notFound = error { aiMissing } else { aiOff }
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

    /// Why the last `compose` produced nothing.
    private(set) var lastProblem: String?

    /// A plan for a description, or nil when nothing usable came back.
    ///
    /// Never throws at the caller: a mix that cannot be described is a screen that says
    /// so, not an error dialog over a music player.
    func compose(_ description: String) async -> Plan? {
        let mix: MusicMix
        do {
            mix = try await client.musicMix(describing: description)
        } catch let error as MeleteError where error.meansAIOff {
            readiness = .unavailable(Self.unavailable(error))
            lastProblem = Self.unavailable(error)
            return nil
        } catch {
            log.error("Mix compose failed: \(error.localizedDescription, privacy: .public)")
            lastProblem = Self.problem(error)
            return nil
        }
        if !mix.rejected.isEmpty {
            log.info("Rules left out: \(mix.rejected.joined(separator: "; "), privacy: .public)")
        }
        let plan = Self.plan(from: mix)
        lastProblem = plan.isEmpty && !mix.rejected.isEmpty ? mix.rejected.joined(separator: " ") : nil
        return plan.isEmpty ? nil : plan
    }

    /// What went wrong, in Melete's words where it gave some: "that's 30 searches
    /// this hour; try again later".
    private static func problem(_ error: any Error) -> String {
        guard case .http(_, _, let detail?) = error as? MeleteError else { return error.localizedDescription }
        let sentence = detail.prefix(1).uppercased() + detail.dropFirst()
        return sentence.hasSuffix(".") ? sentence : sentence + "."
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

    /// Melete's answer as a plan.
    ///
    /// Every rule is built through `SmartRule.init`, which refuses an illegal
    /// field/operator pair, so a rule this app can't evaluate loses that clause rather
    /// than producing a playlist that is silently empty. Melete refuses those too;
    /// this is the app not taking its word for it.
    static func plan(from mix: MusicMix) -> Plan {
        // A description that was only names gets no rules at all, or the entire
        // library would be poured in beside the search.
        guard let set = mix.rules else { return Plan(rules: [], names: mix.names) }
        let rules = set.rules.compactMap(rule(from:))
        guard !rules.isEmpty else { return Plan(rules: [], names: mix.names) }
        let limit = max(10, min(set.limit ?? 40, 200))

        let genres = rules.compactMap { rule -> String? in
            guard rule.field == .genre, rule.op == .is, case .text(let genre) = rule.value else { return nil }
            return genre
        }
        // "All" of several genres asks for a track tagged with every one of them,
        // which is next to none: one set per genre instead, each with the shared
        // rules, so genres are *or* and the rest *and*. Each set takes its share,
        // so a three-genre mix is not forty of the first.
        guard set.match == "all", genres.count > 1 else {
            let match: SmartRules.Match = set.match == "any" ? .any : .all
            let only = try? SmartRules(match: match, rules: rules, limit: limit)
            return Plan(rules: [only].compactMap { $0 }, names: mix.names, genres: genres)
        }
        let shared = rules.filter { !($0.field == .genre && $0.op == .is) }
        let sets = genres.compactMap { genre -> SmartRules? in
            guard let genreRule = try? SmartRule(field: .genre, op: .is, value: .text(genre)) else { return nil }
            return try? SmartRules(match: .all, rules: [genreRule] + shared, limit: max(10, limit / genres.count + 1))
        }
        return Plan(rules: sets, names: mix.names, genres: genres)
    }

    private static func rule(from wire: MusicMix.Rule) -> SmartRule? {
        guard let field = SmartRule.Field(rawValue: wire.field),
              let op = SmartRule.Operator(rawValue: wire.op)
        else { return nil }
        let value: SmartRule.Value = switch wire.value {
        case .text(let text): .text(text)
        case .number(let number): .number(number)
        case .flag(let flag): .flag(flag)
        }
        return try? SmartRule(field: field, op: op, value: value)
    }
}
