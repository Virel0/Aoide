import CurationKit
import JellyfinKit
import PhotosUI
import SwiftUI

/// A local playlist's cover.
///
/// Resolved rather than stored, in this order:
///
/// 1. A cover chosen by hand.
/// 2. For an imported playlist, the Jellyfin playlist it came from — so a playlist
///    copied off the server keeps the image it had there, which is the whole point of
///    a copy looking like the original.
/// 3. A mosaic of up to four albums it holds, which is what Jellyfin and Apple Music
///    both do and costs nothing to keep true as the playlist changes.
/// 4. The lettered gradient, for a playlist that is empty or whose albums have no art.
///
/// Only *ids* are ever stored, never image bytes. The op log replays in full onto
/// every new device and payloads are capped at 256 KB, so a cover held as data would
/// be the largest thing in the system and would be copied forever — while an id is a
/// few bytes and resolves against a server both devices already talk to.
struct PlaylistArtwork: View {
    let playlist: Playlist
    /// Albums the playlist holds, most-played-order, for the mosaic. Supplied by the
    /// caller because one query answers it for a whole screen; asking per tile would
    /// be a query per row.
    var albumIds: [String] = []
    var cornerRadius: CGFloat = Design.Radius.thumbnail

    @Environment(LibraryStore.self) private var library

    var body: some View {
        Group {
            if let hash = playlist.imageHash {
                // A picked photo beats everything: it is the one cover somebody chose
                // deliberately rather than the app inferring one.
                SyncedImage(hash: hash, cornerRadius: cornerRadius)
            } else if let single = chosenItemId {
                ArtworkView(url: url(for: single), cornerRadius: cornerRadius)
            } else if albumIds.count >= 4 {
                mosaic
            } else if let first = albumIds.first {
                // One or two albums is not a mosaic — a quarter-filled grid reads as a
                // failure to load rather than as a design.
                ArtworkView(url: url(for: first), cornerRadius: cornerRadius)
            } else {
                LocalPlaylistTile(name: playlist.name, isSmart: playlist.isSmart, cornerRadius: cornerRadius)
            }
        }
        .accessibilityHidden(true)
    }

    private var chosenItemId: String? {
        playlist.artworkItemId ?? playlist.sourceJellyfinId
    }

    private var mosaic: some View {
        // Fixed 2×2 rather than a LazyVGrid: the count is known and four cells do not
        // need a layout engine, and a lazy grid inside a 44pt row measures badly.
        VStack(spacing: 0) {
            ForEach(0..<2, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(0..<2, id: \.self) { column in
                        ArtworkView(url: url(for: albumIds[row * 2 + column]), cornerRadius: 0)
                    }
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(.rect(cornerRadius: cornerRadius))
    }

    private func url(for itemId: String) -> URL? {
        // No image tag, which only exists to bust caches when a cover changes — and
        // the ids here come from our own store rather than from a fetched item, so we
        // do not have one to pass. A cover that changes on the server therefore
        // updates on the next cache eviction rather than instantly, which for a
        // playlist thumbnail is a trade worth taking over storing tags we would have
        // to keep fresh.
        library.artworkURL(itemId: itemId, maxWidth: Design.ArtworkWidth.thumbnail)
    }
}

/// Picks a playlist's cover from the albums it holds.
///
/// Its own contents rather than the whole library, and no photo library at all. A
/// picture from the camera roll would have to reach the other devices somehow, and
/// the sidecar stores ops, not blobs — so it would either not sync, which is worse
/// than no feature, or become the largest thing in an op log that replays in full
/// onto every new device.
struct CoverPicker: View {
    let playlist: Playlist
    let albums: [JellyfinItem]

    @Environment(LibraryStore.self) private var library
    @Environment(LocalPlaylistStore.self) private var playlists
    @Environment(\.dismiss) private var dismiss

    @State private var picked: PhotosPickerItem?

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: Design.Spacing.card)]

    var body: some View {
        NavigationStack {
            ScrollView {
                PhotosPicker(selection: $picked, matching: .images) {
                    Label("Choose a Photo", systemImage: "photo.on.rectangle")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                .pageMargin()
                .padding(.top, 12)

                Text("Photos are shared with your other devices through your server.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .pageMargin()
                    .padding(.top, 4)

                if !albums.isEmpty {
                    PlainShelfHeader(title: "Or an album in this playlist")
                        .pageMargin()
                        .padding(.top, 18)
                }

                LazyVGrid(columns: columns, spacing: Design.Spacing.card) {
                    ForEach(albums) { album in
                        Button {
                            Task {
                                await playlists.setArtwork(album.albumId ?? album.id, on: playlist)
                                dismiss()
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                ArtworkView(
                                    url: library.artworkURL(for: album, width: Design.ArtworkWidth.card),
                                    cornerRadius: Design.Radius.thumbnail
                                )
                                Text(album.album ?? album.name)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .pageMargin()
                .padding(.vertical, 12)
            }
            .appBackground()
            .navigationTitle("Choose Cover")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task(id: picked) {
                guard let picked,
                      let data = try? await picked.loadTransferable(type: Data.self)
                else { return }
                if await playlists.setPhotoArtwork(data, on: playlist) { dismiss() }
            }
        }
    }
}

/// A cover held behind a content hash, from disk if this device has it and from the
/// sidecar if it does not.
///
/// Fetched lazily rather than during sync. A device joining an account could
/// otherwise be made to download every cover in the library before it finished
/// syncing, most of which it will never draw.
struct SyncedImage: View {
    let hash: String
    var cornerRadius: CGFloat = Design.Radius.thumbnail

    @State private var image: UIImage?

    var body: some View {
        Rectangle()
            .fill(.fill.tertiary)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                }
            }
            .clipped()
            .clipShape(.rect(cornerRadius: cornerRadius))
            .task(id: hash) { await load() }
    }

    private func load() async {
        if let local = await PlaylistImageStore.shared.bytes(for: hash) {
            image = UIImage(data: local)
            return
        }
        // Bytes behind a hash cannot change, so a fetched copy is kept forever
        // rather than re-fetched — there is no invalidation problem to have.
        // The singleton rather than the environment: nothing injects the coordinator,
        // and a missing `@Environment` observable is a trap rather than a nil — this
        // view is drawn inside sheets, which is exactly where that has crashed before.
        guard let fetched = await SyncCoordinator.shared.fetchImage(hash: hash) else { return }
        await PlaylistImageStore.shared.store(fetched, hash: hash)
        image = UIImage(data: fetched)
    }
}
