import SwiftUI

/// The app's visual constants.
///
/// Gathered in one place because the alternative — magic numbers spread across
/// twenty view files — is how an interface stops looking like one interface.
enum Design {
    /// Corner radii, matched to what the artwork is sitting in.
    enum Radius {
        /// Album art in a carousel or grid cell.
        static let card: CGFloat = 8
        /// The large hero artwork on a detail page.
        static let hero: CGFloat = 12
        /// Thumbnails in list rows.
        static let thumbnail: CGFloat = 5
        /// Artist artwork, which Apple Music renders as a circle.
        static let round: CGFloat = 999
    }

    enum Size {
        /// Square card in a horizontal shelf. Sized so two and a bit are visible on
        /// a phone, which is what invites the sideways scroll.
        static let shelfCard: CGFloat = 158
        /// The smaller card used for genre and mood tiles.
        static let compactCard: CGFloat = 130
        static let listThumbnail: CGFloat = 52
        static let miniPlayerArtwork: CGFloat = 32
    }

    enum Spacing {
        /// Gap between shelves down the Home page.
        static let shelf: CGFloat = 30
        /// Gap between cards within a shelf.
        static let card: CGFloat = 14
        /// The page's horizontal margin. Everything aligns to this.
        static let margin: CGFloat = 16
    }

    /// Artwork request widths. Asking for exactly what will be drawn keeps a large
    /// library's scrolling cheap over a home connection.
    enum ArtworkWidth {
        static let thumbnail = 160
        static let card = 400
        static let hero = 800
        static let nowPlaying = 1000
    }
}

extension View {
    /// The standard page margin, so a shelf's cards line up with the headings above
    /// them and with every other screen.
    func pageMargin() -> some View {
        padding(.horizontal, Design.Spacing.margin)
    }
}

// MARK: - Section headings

/// A shelf heading, with the chevron affordance Apple Music uses to mean
/// "there is more of this".
struct ShelfHeader<Destination: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var destination: () -> Destination

    var body: some View {
        NavigationLink(destination: destination) {
            VStack(alignment: .leading, spacing: 1) {
                if let subtitle {
                    Text(subtitle.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tint)
                        .tracking(0.6)
                }
                // The chevron belongs beside the title, not the eyebrow above it.
                HStack(spacing: 4) {
                    Text(title)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.primary)
                    Image(systemName: "chevron.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// The same heading where there's nothing more to navigate to.
struct PlainShelfHeader: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let subtitle {
                Text(subtitle.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tint)
                    .tracking(0.6)
            }
            Text(title)
                .font(.title2.weight(.bold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
