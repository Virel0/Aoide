import MeleteKit
import PlaybackKit
import SwiftUI

/// The Library tab: Apple Music's list of categories, then recently added.
struct LibraryView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(AppSession.self) private var session

    /// Owned by `MainTabView` so a Spotlight result can push a detail screen onto
    /// this tab before it has ever been shown.
    @Binding var path: NavigationPath

    var body: some View {
        NavigationStack(path: $path) {
            // A ScrollView rather than a List: the shelf below is a horizontal
            // carousel, and a NavigationLink inside a List row draws a disclosure
            // chevron on every album cell.
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(spacing: 0) {
                        // One row, two kinds behind it — the ones made here and the ones
                        // on the server. See `PlaylistsHomeView` for why they share a
                        // destination rather than getting a Library row each.
                        categoryRow("Playlists", "music.note.list") { PlaylistsHomeView() }
                        // Above the rest of the library on purpose: a mix is
                        // something you ask for, not something you browse to.
                        categoryRow("Mixes", "wand.and.stars") { MixView() }
                        categoryRow("Replay", "chart.bar") { ReplayView() }
                        categoryRow("Artists", "music.microphone") { ArtistsListView() }
                        categoryRow("Albums", "square.stack") { AlbumsGridView() }
                        categoryRow("Liked Albums", "heart") { LikedAlbumsView() }
                        categoryRow("Songs", "music.note") { SongsListView() }
                        categoryRow("Genres", "guitars") { GenresListView() }
                    }
                    .pageMargin()

                    if let recent = store.recentlyAdded.value, !recent.isEmpty {
                        AlbumShelf(title: "Recently Added", albums: recent)
                            .padding(.top, 26)
                    }
                }
                .padding(.vertical, 8)
            }
            .miniPlayerInset()
            .appBackground()
            .navigationTitle("Library")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .refreshable { await store.refresh() }
            .task { await store.loadRecentlyAddedIfNeeded() }
            .navigationDestination(for: LibraryRoute.self) { route in
                switch route {
                case .item(let id): SpotlightDestination(id: id)
                }
            }
        }
    }

    private func categoryRow<Destination: View>(
        _ title: String,
        _ symbol: String,
        @ViewBuilder destination: @escaping () -> Destination
    ) -> some View {
        row {
            NavigationLink(destination: destination) { categoryLabel(title, symbol) }
        }
    }

    private func row(@ViewBuilder link: () -> some View) -> some View {
        VStack(spacing: 0) {
            link().buttonStyle(.plain)
            Divider().padding(.leading, 40)
        }
    }

    private func categoryLabel(_ title: String, _ symbol: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 19))
                .foregroundStyle(.tint)
                .frame(width: 26)
            Text(title)
                .font(.title3.weight(.medium))
                .foregroundStyle(.primary)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 13)
        .contentShape(.rect)
    }
}

/// Two columns of covers, used in Library and behind every "See All".
struct AlbumGrid: View {
    let albums: [MusicItem]
    var onAppearItem: ((MusicItem) -> Void)?

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: Design.Spacing.card)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 22) {
            ForEach(albums) { album in
                NavigationLink {
                    AlbumDetailView(album: album)
                } label: {
                    AlbumCard(album: album, width: nil)
                }
                .buttonStyle(.plain)
                .albumContextMenu(album)
                .onAppear { onAppearItem?(album) }
            }
        }
    }
}

// MARK: - Albums

struct AlbumsGridView: View {
    @Environment(LibraryStore.self) private var store

    @State private var paged: PagedItems?
    @State private var sort: ItemSort = .name

    var body: some View {
        ScrollView {
            if let paged {
                // First, deliberately: `reload()` clears items and the error before
                // raising the flag, so any other order flashes "No Albums" on retry.
                if paged.isLoadingFirstPage {
                    ProgressView().padding(.top, 60)
                } else if paged.isEmpty {
                    ContentUnavailableView("No Albums", systemImage: "square.stack")
                        .padding(.top, 60)
                } else if let message = paged.errorMessage {
                    ErrorRow(message: message) { Task { await paged.reload() } }
                } else {
                    AlbumGrid(albums: paged.items) { album in
                        Task { await paged.loadMoreIfNeeded(currentItem: album) }
                    }
                    .pageMargin()
                    .padding(.vertical, 12)

                    if paged.isLoadingMore {
                        ProgressView().padding(.bottom, 24)
                    }
                }
            } else {
                ProgressView().padding(.top, 60)
            }
        }
        .miniPlayerInset()
        .appBackground()
        .navigationTitle("Albums")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { SortMenu(sort: $sort) }
        .task(id: sort) { await rebuild() }
    }

    private func rebuild() async {
        let list = store.albumsPage(sort: sort)
        paged = list
        await list.loadFirstPageIfNeeded()
    }
}

// MARK: - Artists

struct ArtistsListView: View {
    @Environment(LibraryStore.self) private var store
    @State private var paged: PagedItems?

    var body: some View {
        Group {
            if let paged {
                if paged.isLoadingFirstPage {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let message = paged.errorMessage {
                    ErrorRow(message: message) { Task { await paged.reload() } }
                } else if paged.isEmpty {
                    ContentUnavailableView("No Artists", systemImage: "music.microphone")
                } else {
                    AlphabetIndexedList(sections: AlphabetSections.group(paged.items)) { artist in
                        NavigationLink {
                            ArtistDetailView(artist: artist)
                        } label: {
                            HStack(spacing: 12) {
                                ArtworkView(
                                    url: store.artworkURL(for: artist, width: Design.ArtworkWidth.thumbnail),
                                    cornerRadius: Design.Radius.round
                                )
                                .frame(width: Design.Size.listThumbnail, height: Design.Size.listThumbnail)
                                Text(artist.name)
                            }
                        }
                        .onAppear {
                            Task { await paged.loadMoreIfNeeded(currentItem: artist) }
                        }
                    }
                }
            } else {
                ProgressView()
            }
        }
        .miniPlayerInset()
        .appBackground()
        .navigationTitle("Artists")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let list = store.artistsPage()
            paged = list
            await list.loadFirstPageIfNeeded()
        }
    }
}

// MARK: - Songs

struct SongsListView: View {
    @Environment(LibraryStore.self) private var store
    @State private var paged: PagedItems?
    @State private var sort: ItemSort = .name

    var body: some View {
        Group {
            if let paged {
                if paged.isLoadingFirstPage {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let message = paged.errorMessage {
                    ErrorRow(message: message) { Task { await paged.reload() } }
                } else if paged.isEmpty {
                    ContentUnavailableView("No Songs", systemImage: "music.note")
                } else if sort == .name {
                    AlphabetIndexedList(sections: AlphabetSections.group(paged.items)) { song in
                        songRow(song, in: paged)
                    }
                } else {
                    // Only an alphabetical sort has meaningful letter sections.
                    List(paged.items) { song in
                        songRow(song, in: paged)
                    }
                    .listStyle(.plain)
                }
            } else {
                ProgressView()
            }
        }
        .miniPlayerInset()
        .appBackground()
        .navigationTitle("Songs")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { SortMenu(sort: $sort) }
        .task(id: sort) {
            let list = store.songsPage(sort: sort)
            paged = list
            await list.loadFirstPageIfNeeded()
        }
    }

    /// Play from here through the rest of what's loaded, which is what tapping a
    /// song in a long list is understood to mean — unless Infinity is on. Then
    /// the song plays alone and Infinity chooses what follows: the rest of this
    /// list is every song in the library in whatever order it is sorted, and
    /// queued it reads as a search for the song's name, not as a set.
    ///
    /// The play source stays `.unknown`: every song in the library is in this list, so
    /// it says nothing about what the listener chose. Calling it `.album` because the
    /// songs happen to have albums would fill a recap with albums nobody opened.
    private func play(_ song: MusicItem, in paged: PagedItems) {
        if InfinityQueue.shared.isOn {
            store.play([song])
            return
        }
        guard let index = paged.items.firstIndex(where: { $0.id == song.id }) else { return }
        store.play(paged.items, startingAt: index)
    }

    private func songRow(_ song: MusicItem, in paged: PagedItems) -> some View {
        SongRow(song: song)
            .contentShape(.rect)
            .onTapGesture { play(song, in: paged) }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { play(song, in: paged) }
            .trackContextMenu(song)
            .onAppear { Task { await paged.loadMoreIfNeeded(currentItem: song) } }
    }
}

/// A song row carrying its own artwork — needed anywhere songs from different
/// albums are mixed together.
struct SongRow: View {
    let song: MusicItem

    @Environment(LibraryStore.self) private var store
    @State private var engine = PlaybackEngine.shared

    private var isCurrent: Bool { engine.currentTrack?.id == song.id }

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(
                url: store.artworkURL(for: song, width: Design.ArtworkWidth.thumbnail),
                cornerRadius: Design.Radius.thumbnail
            )
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 1) {
                Text(song.name)
                    .lineLimit(1)
                    .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                if !song.subtitle.isEmpty {
                    Text(song.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            if isCurrent {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.caption)
                    .foregroundStyle(.tint)
            }
        }
    }
}

// MARK: - Sorting

struct SortMenu: ToolbarContent {
    @Binding var sort: ItemSort

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Picker("Sort By", selection: $sort) {
                    ForEach(ItemSort.browsable) { option in
                        Text(option.displayName).tag(option)
                    }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
            }
            .accessibilityLabel("Sort")
        }
    }
}

// MARK: - Small shared rows

struct LoadingRow: View {
    var body: some View {
        HStack {
            Spacer()
            ProgressView()
            Spacer()
        }
        .padding(.vertical, 24)
        .listRowSeparator(.hidden)
    }
}

struct ErrorRow: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Try Again", action: retry)
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .listRowSeparator(.hidden)
    }
}
