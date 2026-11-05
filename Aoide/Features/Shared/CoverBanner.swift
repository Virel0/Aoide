import SwiftUI

/// A square cover in a wide banner, whole: the cover as tall as the banner in
/// its middle, the sides filled with the cover's own colours (Melete's palette)
/// or, without one, the cover blurred. Cropping a square cover to a wide frame
/// cut off its top and bottom: a head, a title.
struct CoverBanner: View {
    let url: URL?
    /// The album's palette as `#rrggbb`; nil or empty uses the blurred cover.
    let palette: [String]?
    var cornerRadius: CGFloat = 6
    /// Width over height of the banner.
    var aspectRatio: CGFloat = 16 / 10

    var body: some View {
        Rectangle()
            .fill(.black)
            .aspectRatio(aspectRatio, contentMode: .fit)
            .overlay { ground }
            .overlay { ArtworkView(url: url, cornerRadius: 0).aspectRatio(1, contentMode: .fit) }
            .clipShape(.rect(cornerRadius: cornerRadius))
    }

    private var colours: [Color] {
        (palette ?? []).compactMap(Color.init(hex:))
    }

    @ViewBuilder
    private var ground: some View {
        if colours.isEmpty {
            // Blurred, its crop doesn't show: it's a ground, not the cover.
            ArtworkView(url: url, cornerRadius: 0, aspectRatio: aspectRatio)
                .blur(radius: 30)
                .scaleEffect(1.2)
                .overlay(Color.black.opacity(0.15))
        } else {
            PaletteGround(palette: colours)
        }
    }
}
