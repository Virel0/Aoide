import UIKit

/// A photo made into a profile picture on the phone: the middle square, 512
/// points across, as a JPEG. A few tens of kilobytes against Melete's 5 MB, and
/// whatever the library holds (HEIC, a 48-megapixel shot) is sent as one type
/// the server takes.
enum AvatarImage {
    static let side: CGFloat = 512
    static let contentType = "image/jpeg"

    /// `nil` when the bytes aren't an image UIKit can read.
    static func jpeg(from data: Data) -> Data? {
        guard let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else { return nil }
        let crop = min(image.size.width, image.size.height)
        let scale = side / crop
        let drawn = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
        return renderer.jpegData(withCompressionQuality: 0.85) { _ in
            // `draw(in:)` honours the photo's orientation, so a portrait shot
            // isn't sent on its side.
            image.draw(in: CGRect(
                x: (side - drawn.width) / 2,
                y: (side - drawn.height) / 2,
                width: drawn.width,
                height: drawn.height
            ))
        }
    }
}
