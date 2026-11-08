import MeleteKit
import PlaybackKit
import SwiftUI

/// A collection's songs, as the library has them now, with Play and Shuffle.
struct CollectionDetailView: View {
    let collection: SongCollection

    @Environment(LibraryStore.self) private var store
    @State private var paged: PagedItems?
    @State private var problem: String?

    /// The most songs Play or Shuffle queues, as a queue holds.
    private static let most = 500

    var body: some View {
        Group {
            if let paged {
                if paged.isLoadingFirstPage {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let message = paged.errorMessage {
                    ErrorRow(message: message) { Task { await paged.reload() } }
                } else if paged.isEmpty {
                    ContentUnavailableView(
                        "No Songs", systemImage: "music.note",
                        description: Text("Nothing in your library fits this collection yet.")
                    )
                } else {
                    List {
                        header(paged)
                        ForEach(paged.items) { songRow($0, in: paged) }
                    }
                    .listStyle(.plain)
                }
            } else {
                ProgressView()
            }
        }
        .miniPlayerInset()
        .appBackground()
        .navigationTitle(collection.name)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: collection.id) {
            let list = PagedItems { start, limit in
                guard let client = AppSession.shared.client else { return .empty }
                return try await client.songs(in: collection, startIndex: start, limit: limit)
            }
            paged = list
            await list.loadFirstPageIfNeeded()
        }
    }

    private func header(_ paged: PagedItems) -> some View {
        VStack(spacing: 12) {
            if !collection.summary.isEmpty {
                Text(collection.summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: 12) {
                button("Play", "play.fill") { await playAll(shuffled: false) }
                button("Shuffle", "shuffle") { await playAll(shuffled: true) }
            }
            if let problem {
                Text(problem).font(.footnote).foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .listRowSeparator(.hidden)
    }

    private func button(_ title: String, _ symbol: String, action: @escaping () async -> Void) -> some View {
        Button { Task { await action() } } label: {
            HStack(spacing: 7) {
                Image(systemName: symbol).accessibilityHidden(true)
                Text(title)
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
    }

    /// Plays the collection from its start, or shuffled over all of it (the
    /// server's shuffle, so a big collection isn't only its first page mixed).
    private func playAll(shuffled: Bool) async {
        guard let client = AppSession.shared.client else { return }
        problem = nil
        do {
            let songs = try await client.songs(in: collection, shuffled: shuffled, limit: Self.most).items
            guard !songs.isEmpty else { return }
            store.play(songs, shuffled: shuffled, repeatsWhole: true)
        } catch {
            problem = (error as? MeleteError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// From the song tapped through the rest of what's loaded, as the Songs list
    /// plays; with Infinity on, the song alone and Infinity chooses what follows.
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
