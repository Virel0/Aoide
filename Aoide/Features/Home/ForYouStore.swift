import MeleteKit
import SwiftUI
import os

/// This listener's For You list, from Melete (songs ListenBrainz suggests from
/// what they finished lately, some in the library and some to ask for).
///
/// Fetched when Home first appears and again on a pull to refresh: the server
/// makes the list in the background, at most once a day, so asking more often
/// only asks for the same thing. A 404 is a server before For You, remembered for
/// the session. Only a ready list with songs is kept; off, no history yet and
/// not made yet all hide the shelf without a word.
@MainActor
@Observable
final class ForYouStore {
    static let shared = ForYouStore()

    enum State: Equatable {
        case unknown
        case unavailable
        case loaded([ForYouItem])
    }

    private(set) var state: State = .unknown
    private var isLoading = false
    private let log = Logger(subsystem: AppIdentity.bundle, category: "for-you")

    private init() {}

    var items: [ForYouItem] {
        if case .loaded(let items) = state { return items }
        return []
    }

    /// The songs to play, in the shelf's order.
    var playable: [MusicItem] { items.compactMap(\.track) }

    func loadIfNeeded(client: MeleteClient) async {
        guard state == .unknown else { return }
        await load(client: client)
    }

    /// Asks again, for a pull to refresh. A failure keeps the list held.
    func reload(client: MeleteClient) async {
        guard state != .unavailable else { return }
        await load(client: client)
    }

    private func load(client: MeleteClient) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let list = try await client.forYou()
            state = .loaded(list.state == .ready ? list.items : [])
            if list.state != .ready {
                log.info("For You is \(list.state.rawValue, privacy: .public); the shelf is hidden")
            }
        } catch MeleteError.notFound {
            state = .unavailable
            log.info("This server has no /music/for-you; the shelf is hidden")
        } catch {
            log.warning("Couldn't fetch For You: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Asks for `song` and, once asked, shows it as asked for. Nil when that
    /// worked; otherwise what to show in its place, as Search's Ask for It does.
    func ask(for song: ForYouSong, client: MeleteClient) async -> String? {
        do {
            let request = try await client.askFor(song)
            markAsked(song, requestId: request.id)
            return nil
        } catch MeleteError.http(status: 409, _, let detail) {
            return detail ?? "Asked for already"
        } catch {
            return (error as? MeleteError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func markAsked(_ song: ForYouSong, requestId: Int64) {
        guard case .loaded(var items) = state,
              let index = items.firstIndex(where: { $0.offer == .requestable(song) })
        else { return }
        items[index].offer = .requested(song, requestId: requestId)
        state = .loaded(items)
    }

    /// Forgets the list, for a sign-out: it is one account's.
    func clear() { state = .unknown }
}
