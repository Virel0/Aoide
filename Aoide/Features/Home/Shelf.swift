import JellyfinKit
import SwiftUI

/// A horizontally scrolling row of albums, the unit Home is built from.
///
/// Cards snap to the page margin rather than scrolling freely: the alignment
/// between a card's left edge and the heading above it is most of what makes a
/// shelf read as deliberate rather than as an overflowing row.
struct AlbumShelf: View {
    let title: String
    var subtitle: String?
    let albums: [JellyfinItem]
    var cardSize: CGFloat = Design.Size.shelfCard

    @Environment(LibraryStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ShelfHeader(title: title, subtitle: subtitle) {
                ShelfDetailView(title: title, albums: albums)
            }
            .pageMargin()

            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: Design.Spacing.card) {
                    ForEach(albums) { album in
                        NavigationLink {
                            AlbumDetailView(album: album)
                        } label: {
                            AlbumCard(album: album, width: cardSize)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .scrollTargetLayout()
                .pageMargin()
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollIndicators(.hidden)
        }
    }
}

/// Square cover, title, subtitle. The workhorse.
///
/// `width` of `nil` means "fill whatever you're given", which is what a grid cell
/// needs; a fixed value is what a horizontal shelf needs.
struct AlbumCard: View {
    let album: JellyfinItem
    var width: CGFloat? = Design.Size.shelfCard

    @Environment(LibraryStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ArtworkView(
                url: store.artworkURL(for: album, width: Design.ArtworkWidth.card),
                cornerRadius: Design.Radius.card
            )
            .frame(width: width, height: width)

            VStack(alignment: .leading, spacing: 1) {
                Text(album.name)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if !album.subtitle.isEmpty {
                    Text(album.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(width: width, alignment: .leading)
        }
        .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
    }
}

/// The large card that opens Home. One album, given room, with a computed reason
/// for being there — Apple Music's eyebrow line, except ours states a fact about
/// your own library rather than an editor's opinion.
struct HeroCard: View {
    let album: JellyfinItem
    let eyebrow: String

    @Environment(LibraryStore.self) private var store

    var body: some View {
        NavigationLink {
            AlbumDetailView(album: album)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                Text(eyebrow.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tint)
                    .tracking(0.6)

                // Cropped to a banner rather than left square: a full-width square
                // cover is roughly a whole screen tall on a phone, so nothing else
                // on the page is visible until you scroll past it.
                ArtworkView(
                    url: store.artworkURL(for: album, width: Design.ArtworkWidth.hero),
                    cornerRadius: Design.Radius.hero,
                    aspectRatio: 16 / 10
                )
                .frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: 2) {
                    Text(album.name)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                    if !album.subtitle.isEmpty {
                        Text(album.subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .foregroundStyle(.primary)
            .pageMargin()
        }
        .buttonStyle(.plain)
    }
}

/// A shelf of artists, which Apple Music renders as circles to distinguish them
/// from albums at a glance.
struct ArtistShelf: View {
    let title: String
    let artists: [JellyfinItem]

    @Environment(LibraryStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PlainShelfHeader(title: title)
                .pageMargin()

            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: Design.Spacing.card) {
                    ForEach(artists) { artist in
                        NavigationLink {
                            ArtistDetailView(artist: artist)
                        } label: {
                            VStack(spacing: 7) {
                                ArtworkView(
                                    url: store.artworkURL(for: artist, width: Design.ArtworkWidth.card),
                                    cornerRadius: Design.Radius.round
                                )
                                .frame(width: Design.Size.compactCard, height: Design.Size.compactCard)

                                Text(artist.name)
                                    .font(.subheadline)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                    .frame(width: Design.Size.compactCard)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .scrollTargetLayout()
                .pageMargin()
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollIndicators(.hidden)
        }
    }
}

/// "See All" for any shelf.
struct ShelfDetailView: View {
    let title: String
    let albums: [JellyfinItem]

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: Design.Spacing.card)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 22) {
                ForEach(albums) { album in
                    NavigationLink {
                        AlbumDetailView(album: album)
                    } label: {
                        AlbumCard(album: album, width: nil)
                    }
                    .buttonStyle(.plain)
                }
            }
            .pageMargin()
            .padding(.vertical, 12)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
