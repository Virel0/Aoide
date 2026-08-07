import CurationKit
import Foundation
import UIKit
import os

/// Cover bytes on disk, named by their own SHA-256.
///
/// Application Support rather than Caches: a cover chosen on this device is the only
/// copy until it has been uploaded, and the system may evict Caches whenever it
/// likes. Once uploaded it is recoverable from the server, but "once uploaded" is
/// exactly the window this has to survive.
///
/// Content addressing makes the whole thing simple: a file either is the bytes behind
/// a hash or does not exist, nothing is ever updated in place, and two playlists
/// sharing a cover share a file.
actor PlaylistImageStore: ImageByteSource {
    static let shared = PlaylistImageStore()

    private let log = Logger(subsystem: "com.example.aoide", category: "curation")

    private static let directory: URL = {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PlaylistImages", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// The longest side a cover is stored at, and the reason there is a limit at all:
    /// these are drawn at 160pt in a list and 800pt on a detail page, they cross a
    /// phone connection twice, and the sidecar refuses anything over 256 KB. A
    /// twelve-megapixel photo would fail that check having already cost the upload.
    private static let maxDimension: CGFloat = 1000
    private static let jpegQuality: CGFloat = 0.8

    nonisolated static func file(for hash: String) -> URL {
        directory.appendingPathComponent(hash, isDirectory: false)
    }

    func bytes(for hash: String) async -> Data? {
        try? Data(contentsOf: Self.file(for: hash))
    }

    func store(_ data: Data, hash: String) async {
        try? data.write(to: Self.file(for: hash), options: .atomic)
    }

    func has(_ hash: String) -> Bool {
        FileManager.default.fileExists(atPath: Self.file(for: hash).path)
    }

    /// Turns a picked photo into something worth uploading, and returns what the
    /// server will address it by.
    ///
    /// Re-encoded rather than sent as chosen. A photo out of the library is routinely
    /// several megabytes of HEIC, which is both far more than a thumbnail needs and a
    /// format the sidecar does not accept.
    func prepare(_ data: Data) -> (hash: String, mime: String, bytes: Data)? {
        guard let image = UIImage(data: data) else { return nil }
        let scaled = Self.scaled(image)
        guard let jpeg = scaled.jpegData(compressionQuality: Self.jpegQuality) else { return nil }

        let hash = CurationStore.imageHash(of: jpeg)
        try? jpeg.write(to: Self.file(for: hash), options: .atomic)
        return (hash, "image/jpeg", jpeg)
    }

    private static func scaled(_ image: UIImage) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > maxDimension else { return image }
        let scale = maxDimension / longest
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        return UIGraphicsImageRenderer(size: size).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
