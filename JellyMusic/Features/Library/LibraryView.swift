import JellyfinKit
import PlaybackKit
import SwiftUI

/// The Library tab: Apple Music's list of categories, then recently added.
struct LibraryView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(AppSession.self) private var session

    var body: some View {
        NavigationStack {
            List {
                Section {
                    categoryRow("Playlists", "music.note.list") { PlaylistsView() }
                    categoryRow("Artists", "music.microphone") { ArtistsListView() }
                    categoryRow("Albums", "square.stack") { AlbumsGridView() }
                    categoryRow("Songs", "music.note") { SongsListView() }
                    categoryRow("Genres", "guitars") { GenresListView() }
                }

                if let recent = store.recentlyAdded.value, !recent.isEmpty {
                    Section("Recently Added") {
                        AlbumGrid(albums: Array(recent.prefix(10)))
                            .listRowInsets(EdgeInsets(top: 8, leading: Design.Spacing.margin, bottom: 8, trailing: Design.Spacing.margin))
                            .listRowSeparator(.hidden)
                    }
                }
            }
            .listStyle(.plain)
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
        }
    }

    private func categoryRow<Destination: View>(
        _ title: String,
        _ symbol: String,
        @ViewBuilder destination: @escaping () -> Destination
    ) -> some View {
        NavigationLink(destination: destination) {
            Label {
                Text(title).font(.title3.weight(.medium))
            } icon: {
                Image(systemName: symbol).foregroundStyle(.tint)
            }
            .padding(.vertical, 3)
        }
    }
}

/// Two columns of covers, used in Library and behind every "See All".
struct AlbumGrid: View {
    let albums: [JellyfinItem]
    var onAppearItem: ((JellyfinItem) -> Void)?

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
                if paged.isEmpty {
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
        .navigationTitle("Songs")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { SortMenu(sort: $sort) }
        .task(id: sort) {
            let list = store.songsPage(sort: sort)
            paged = list
            await list.loadFirstPageIfNeeded()
        }
    }

    private func songRow(_ song: JellyfinItem, in paged: PagedItems) -> some View {
        SongRow(song: song)
            .contentShape(.rect)
            .onTapGesture {
                // Play from here through the rest of what's loaded, which is what
                // tapping a song in a long list is understood to mean.
                if let index = paged.items.firstIndex(where: { $0.id == song.id }) {
                    store.play(paged.items, startingAt: index)
                }
            }
            .trackContextMenu(song)
            .onAppear { Task { await paged.loadMoreIfNeeded(currentItem: song) } }
    }
}

/// A song row carrying its own artwork — needed anywhere songs from different
/// albums are mixed together.
struct SongRow: View {
    let song: JellyfinItem

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
