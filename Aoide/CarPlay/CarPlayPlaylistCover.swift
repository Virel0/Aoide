import CarPlay
import CurationKit
import MeleteKit
import UIKit

/// A playlist's cover for a row in the car: the choice `PlaylistArtwork` makes on
/// the phone, drawn into one image, because a CarPlay row takes a `UIImage`.
@MainActor
enum CarPlayPlaylistCover {
    /// Sets `row`'s image once the cover is in hand, and leaves its symbol otherwise.
    static func load(_ list: Playlist, albumIds: [String], client: MeleteClient, width: Int, into row: CPListItem) {
        Task { [weak row] in
            guard let image = await cover(list, albumIds: albumIds, client: client, width: width) else { return }
            row?.setImage(image)
        }
    }

    /// A picked photo, then a chosen album, then the albums it holds: four make a
    /// mosaic, fewer give the first one's cover.
    private static func cover(_ list: Playlist, albumIds: [String], client: MeleteClient, width: Int) async -> UIImage? {
        if let hash = list.imageHash {
            return await PlaylistImageStore.shared.bytes(for: hash).flatMap(UIImage.init(data:))
        }
        let wanted = list.artworkItemId.map { [$0] } ?? Array(albumIds.prefix(albumIds.count >= 4 ? 4 : 1))
        var covers: [UIImage] = []
        for albumId in wanted {
            let url = client.artworkURL(itemId: albumId, tag: nil, maxWidth: width)
            guard let image = await ArtworkCache.shared.image(for: url) else { break }
            covers.append(image)
        }
        return covers.count == 4 ? mosaic(covers, side: CGFloat(width)) : covers.first
    }

    /// Four covers in a 2×2 grid, each cropped to fill its quarter.
    static func mosaic(_ covers: [UIImage], side: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let half = side / 2
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { context in
            for (index, cover) in covers.prefix(4).enumerated() {
                let cell = CGRect(x: CGFloat(index % 2) * half, y: CGFloat(index / 2) * half, width: half, height: half)
                let scale = max(half / max(cover.size.width, 1), half / max(cover.size.height, 1))
                let size = CGSize(width: cover.size.width * scale, height: cover.size.height * scale)
                context.cgContext.saveGState()
                context.cgContext.clip(to: cell)
                let origin = CGPoint(x: cell.midX - size.width / 2, y: cell.midY - size.height / 2)
                cover.draw(in: CGRect(origin: origin, size: size))
                context.cgContext.restoreGState()
            }
        }
    }
}
