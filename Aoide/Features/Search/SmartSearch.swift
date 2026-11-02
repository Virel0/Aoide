import Foundation
import MeleteKit
import os

/// Turns a phrase like "upbeat rock from the nineties" into a `MusicQuery`.
///
/// Melete's model does the translating, through OpenRouter: words in, filters
/// out. It never chooses tracks. That split is not stylistic — measured against
/// this library, a model picked the right songs for a named genre 2–5 times out
/// of 8, which is worse than useless when the server can answer the same question
/// exactly. Mapping a phrase onto a genre name
/// and a year range is the part it is reliably good at, and Melete does the
/// selecting afterwards. Melete tells the model the library's genres and keeps
/// only those, so an invented "Chill" never empties a search.
@MainActor
@Observable
final class SmartSearch {
    private let log = Logger(subsystem: AppIdentity.bundle, category: "smart-search")
    private let client: MeleteClient

    /// Whether the server has its AI features on, once it has said. Off, the
    /// plain search is the whole feature and nothing says otherwise.
    private var serverAI: Bool?

    init(client: MeleteClient) {
        self.client = client
    }

    /// Worth offering the smart path at all.
    ///
    /// One or two words is a name, and the plain search already handles names better
    /// than any interpretation of them would.
    static func looksLikeAPhrase(_ text: String) -> Bool {
        text.split(whereSeparator: \.isWhitespace).count >= 3
    }

    /// Whether the server offers AI. Asked once; an answer that can't be had
    /// (no signal) is a no for now and asked again next time.
    func isAvailable() async -> Bool {
        if let serverAI { return serverAI }
        do {
            let enabled = try await client.aiEnabled()
            serverAI = enabled
            return enabled
        } catch let error as MeleteError where error.meansAIOff {
            serverAI = false
            return false
        } catch {
            return false
        }
    }

    /// Parses a phrase, or returns nil when nothing usable came back.
    ///
    /// Never reports a failure: a phrase the server couldn't read leaves the plain
    /// results to stand on their own.
    func interpret(_ text: String) async -> MusicQuery? {
        do {
            let query = try await client.musicFilters(describing: text).query.grounded(in: text)
            // An empty query means the phrase was understood as nothing at all. Running
            // it would return the library in alphabetical order dressed up as an answer.
            return query.isEmpty ? nil : query
        } catch let error as MeleteError where error.meansAIOff {
            // Off, or a Melete older than the music AI (404): the plain search
            // carries on alone, and the next launch asks again.
            serverAI = false
            return nil
        } catch is CancellationError {
            return nil
        } catch {
            log.error("Smart search failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
