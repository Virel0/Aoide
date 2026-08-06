import SwiftUI

/// In-memory cover art cache.
///
/// `AsyncImage` refetches every time a cell scrolls back into view, which on a grid
/// of albums means visible flicker and a lot of pointless traffic. Artwork URLs
/// include Jellyfin's image tag, so a URL is a safe cache key: different cover,
/// different URL.
actor ArtworkCache {
    static let shared = ArtworkCache()

    private let cache = NSCache<NSURL, UIImage>()
    /// Tracks loads already running so ten cells appearing at once don't each
    /// fire their own request for the same album cover.
    private var inFlight: [URL: Task<UIImage?, Never>] = [:]

    private init() {
        cache.countLimit = 300
        // A count limit alone is not a memory limit: requested widths span 160 to
        // 1000, so 300 hero covers is several hundred megabytes of decoded backing
        // store. NSCache does evict under pressure, but only best-effort and late —
        // on a phone already holding an AVQueuePlayer buffer that is a jetsam.
        cache.totalCostLimit = 64 * 1024 * 1024
    }

    func image(for url: URL) async -> UIImage? {
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        if let existing = inFlight[url] { return await existing.value }

        let task = Task<UIImage?, Never> {
            // A downloaded track's cover is on disk under this exact URL. Checking
            // first is what makes a download look like a download with the radio
            // off, and it costs one stat on the miss path.
            if let data = OfflineAssets.artworkData(for: url), let image = UIImage(data: data) {
                return image
            }
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let image = UIImage(data: data)
            else { return nil }
            return image
        }
        inFlight[url] = task

        let image = await task.value
        inFlight[url] = nil
        if let image {
            let bytes = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
            cache.setObject(image, forKey: url as NSURL, cost: bytes)
        }
        return image
    }
}

/// Album art with a placeholder that matches Apple Music's — a music note on a
/// neutral fill, rather than an empty grey box.
struct ArtworkView: View {
    let url: URL?
    var cornerRadius: CGFloat = 6
    /// Covers are square, but a hero banner crops to a wider frame so it doesn't
    /// swallow the whole first screen.
    var aspectRatio: CGFloat = 1

    @State private var image: UIImage?
    @State private var didFail = false

    var body: some View {
        Rectangle()
            .fill(.fill.tertiary)
            .aspectRatio(aspectRatio, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else if didFail || url == nil {
                    Image(systemName: "music.note")
                        .font(.system(size: 24))
                        .foregroundStyle(.secondary)
                }
            }
            .clipped()
            .clipShape(.rect(cornerRadius: cornerRadius))
            .accessibilityHidden(true)
            .overlay {
                // A hairline keeps pale covers from bleeding into a light background.
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(.separator.opacity(0.5), lineWidth: 0.5)
            }
            .task(id: url) {
                guard let url else { return }
                image = await ArtworkCache.shared.image(for: url)
                didFail = image == nil
            }
    }
}
