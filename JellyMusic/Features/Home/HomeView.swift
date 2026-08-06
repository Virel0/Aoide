import JellyfinKit
import PlaybackKit
import SwiftUI

/// The landing screen: a stack of shelves built from your own library.
///
/// Apple Music opens on editorially-curated recommendations. There is no editor
/// here and no catalogue, so every shelf is instead a fact about what you own and
/// what you've listened to. Shelves that have nothing to say simply don't appear,
/// which is why a brand-new library still looks composed rather than broken.
struct HomeView: View {
    @Environment(LibraryStore.self) private var store
    @State private var engine = PlaybackEngine.shared

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Design.Spacing.shelf) {
                    if let hero = heroAlbum {
                        HeroCard(album: hero.album, eyebrow: hero.reason)
                    }

                    if !continueListening.isEmpty {
                        AlbumShelf(title: "Continue Listening", albums: continueListening)
                    }

                    shelf("Recently Added", store.recentlyAdded)
                    shelf("Recently Played", store.recentlyPlayed)
                    shelf("Most Played", store.mostPlayed, subtitle: "Your library")
                    shelf("Favourites", store.favorites)
                    shelf("Rediscover", store.rediscover, subtitle: "Not played in a while")

                    if isEmpty {
                        emptyState
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .navigationTitle("Home")
            .refreshable { await store.refresh() }
            .task { await store.loadHomeIfNeeded() }
        }
    }

    // MARK: - Shelves

    @ViewBuilder
    private func shelf(
        _ title: String,
        _ state: LibraryStore.Loadable<[JellyfinItem]>,
        subtitle: String? = nil
    ) -> some View {
        switch state {
        case .loaded(let albums) where !albums.isEmpty:
            // The hero already shows the newest album; don't repeat it directly
            // underneath itself.
            let filtered = albums.filter { $0.id != heroAlbum?.album.id }
            if !filtered.isEmpty {
                AlbumShelf(title: title, subtitle: subtitle, albums: filtered)
            }
        case .loading:
            ShelfPlaceholder(title: title)
        default:
            // Loaded-but-empty and failed both render as nothing. A shelf reading
            // "Most Played (0)" on a library with no history is noise, not
            // information.
            EmptyView()
        }
    }

    /// The queue as it stands, so picking up where you left off is the first thing
    /// on the page rather than something to go hunting for.
    private var continueListening: [JellyfinItem] {
        guard engine.currentTrack != nil else { return [] }
        return []
    }

    /// The one album given hero treatment, with the reason it earned the spot.
    private var heroAlbum: (album: JellyfinItem, reason: String)? {
        if let album = store.recentlyAdded.value?.first {
            return (album, "Added recently")
        }
        if let album = store.mostPlayed.value?.first {
            return (album, "You play this a lot")
        }
        return store.albums.value?.first.map { ($0, "From your library") }
    }

    private var isEmpty: Bool {
        [store.recentlyAdded, store.recentlyPlayed, store.mostPlayed, store.favorites, store.rediscover]
            .allSatisfy { state in
                switch state {
                case .loaded(let items): items.isEmpty
                case .failed: true
                default: false
                }
            }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Nothing here yet", systemImage: "music.note.house")
        } description: {
            Text("Play something from your Library and it'll start showing up here.")
        }
        .padding(.top, 60)
    }
}

/// Keeps the page from jumping as shelves arrive at different times.
private struct ShelfPlaceholder: View {
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PlainShelfHeader(title: title)
                .pageMargin()
                .redacted(reason: .placeholder)

            ScrollView(.horizontal) {
                HStack(spacing: Design.Spacing.card) {
                    ForEach(0..<3, id: \.self) { _ in
                        VStack(alignment: .leading, spacing: 7) {
                            RoundedRectangle(cornerRadius: Design.Radius.card)
                                .fill(.fill.tertiary)
                                .frame(width: Design.Size.shelfCard, height: Design.Size.shelfCard)
                            RoundedRectangle(cornerRadius: 3)
                                .fill(.fill.tertiary)
                                .frame(width: Design.Size.shelfCard * 0.7, height: 11)
                            RoundedRectangle(cornerRadius: 3)
                                .fill(.fill.quaternary)
                                .frame(width: Design.Size.shelfCard * 0.45, height: 11)
                        }
                    }
                }
                .pageMargin()
            }
            .scrollDisabled(true)
            .scrollIndicators(.hidden)
        }
    }
}
