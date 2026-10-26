import CurationKit
import JellyfinKit
import SwiftUI
import os

/// This week's Discover list, from the sidecar.
///
/// Fetched when Home first appears, and again whenever the UTC week has moved
/// past the one held — the server fixes the list for the week, so asking more
/// often only asks for the same thing. A 404 is an older sidecar, remembered
/// for the session, and the tile is not shown.
@MainActor
@Observable
final class DiscoverStore {
    static let shared = DiscoverStore()

    enum State: Equatable {
        case unknown
        case unavailable
        case loaded(week: String, items: [JellyfinItem])
    }

    private(set) var state: State = .unknown
    private var isLoading = false
    private let log = Logger(subsystem: AppIdentity.bundle, category: "discover")

    private init() {}

    var items: [JellyfinItem] {
        if case .loaded(_, let items) = state { return items }
        return []
    }

    func loadIfNeeded(client: JellyfinClient) async {
        switch state {
        case .unavailable: return
        case .loaded(let week, _) where week == Discover.week(of: Date()): return
        default: break
        }
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let response = try Discover.decode(try await client.discover(limit: Discover.limit))
            // Items come back in the order asked for, which is the server's.
            let items = try await client.items(ids: response.candidates.map(\.id))
            state = .loaded(week: response.week, items: items)
        } catch JellyfinError.notFound {
            state = .unavailable
            log.info("This server has no /aoide/discover; the tile is hidden")
        } catch {
            log.warning("Couldn't fetch Discover: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Forgets the list, for a sign-out: it is one account's.
    func clear() { state = .unknown }
}

/// The tile on Home.
struct DiscoverCard: View {
    let count: Int

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "sparkles")
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 44, height: 44)
                .background(.tint.opacity(0.15), in: .rect(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text("Discover")
                    .font(.headline)
                Text("\(count) songs you own and haven't heard, new each Monday")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .background(.fill.quaternary, in: .rect(cornerRadius: 14))
        .contentShape(.rect)
        .pageMargin()
    }
}

/// The week's list: play it, shuffle it, or start from any song.
struct DiscoverView: View {
    @Environment(LibraryStore.self) private var library
    @State private var discover = DiscoverStore.shared

    var body: some View {
        let tracks = discover.items
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Songs from your library you haven't heard all the way through, chosen by what you do listen to. The list holds still for the week.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .pageMargin()

                HStack(spacing: 12) {
                    Button {
                        library.play(tracks, from: .smart)
                    } label: {
                        Label("Play", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    Button {
                        library.play(tracks, shuffled: true, from: .smart)
                    } label: {
                        Label("Shuffle", systemImage: "shuffle")
                    }
                    .buttonStyle(.bordered)
                }
                .pageMargin()

                LazyVStack(spacing: 0) {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                        SongRow(song: track)
                            .contentShape(.rect)
                            .onTapGesture { library.play(tracks, startingAt: index, from: .smart) }
                            .trackContextMenu(track, from: .smart)
                            .padding(.vertical, 4)
                    }
                }
                .pageMargin()
            }
            .padding(.vertical, 12)
        }
        .miniPlayerInset()
        .appBackground()
        .navigationTitle("Discover")
    }
}
