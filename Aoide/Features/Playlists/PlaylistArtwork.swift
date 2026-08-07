import CurationKit
import JellyfinKit
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
            if let single = chosenItemId {
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

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: Design.Spacing.card)]

    var body: some View {
        NavigationStack {
            ScrollView {
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
        }
    }
}
