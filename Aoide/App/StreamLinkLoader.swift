import AVFoundation
import MeleteKit
import os

/// Asks Melete for a track's stream link only when the player starts loading it.
///
/// The player is handed a `melete-stream://track/…` URL for every streamed track
/// (``MeleteClient/streamURL(for:quality:)``), so queueing a long list asks the
/// server nothing. When AVFoundation opens one, this resource loader asks for the
/// real link (`POST …/play`) and redirects the request to it; AVFoundation then
/// loads the file itself, byte ranges and all. One link serves every request for
/// the same track until it is a minute from running out.
final class StreamLinkLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    static let shared = StreamLinkLoader()

    /// The queue AVFoundation calls this on.
    let queue = DispatchQueue(label: "aoide.stream-links")

    private let lock = NSLock()
    private var client: MeleteClient?
    /// Links in hand, by the URL they stand for.
    private var links: [URL: StreamLink] = [:]
    /// Links being asked for, so a track's several loading requests ask once.
    private var asking: [URL: Task<StreamLink, any Error>] = [:]
    private let log = Logger(subsystem: AppIdentity.bundle, category: "streams")

    /// Who to ask, from sign-in until sign-out; links from another session are
    /// forgotten, since they stop working when it signs out.
    func use(_ client: MeleteClient?) {
        lock.withLock {
            self.client = client
            asking.values.forEach { $0.cancel() }
            asking = [:]
            links = [:]
        }
    }

    /// An asset for `url`, with this loader attached when the URL stands for a
    /// stream still to be asked for.
    func asset(for url: URL) -> AVURLAsset {
        let asset = AVURLAsset(url: url)
        if url.scheme == MeleteClient.lazyStreamScheme {
            asset.resourceLoader.setDelegate(self, queue: queue)
        }
        return asset
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard let url = loadingRequest.request.url, url.scheme == MeleteClient.lazyStreamScheme,
              let link = link(for: url)
        else { return false }
        Task {
            do {
                let target = try await link().url
                loadingRequest.redirect = URLRequest(url: target)
                loadingRequest.response = HTTPURLResponse(
                    url: target, statusCode: 302, httpVersion: nil, headerFields: ["Location": target.absoluteString]
                )
                loadingRequest.finishLoading()
            } catch {
                // Never the link: it carries a token.
                log.error("No stream link: \(error.localizedDescription, privacy: .public)")
                forget(url)
                loadingRequest.finishLoading(with: error)
            }
        }
        return true
    }

    /// How to get the link for `url`: the one in hand while it has more than a
    /// minute left, the request already out for it, or a new request.
    private func link(for url: URL) -> (@Sendable () async throws -> StreamLink)? {
        lock.withLock { () -> (@Sendable () async throws -> StreamLink)? in
            guard let client else { return nil }
            if let held = links[url], held.expiresAt.timeIntervalSinceNow > 60 {
                return { held }
            }
            if let out = asking[url] { return { try await out.value } }
            let out = Task { [weak self] in
                let link = try await client.streamLink(forLazyURL: url)
                self?.keep(link, for: url)
                return link
            }
            asking[url] = out
            return { try await out.value }
        }
    }

    private func keep(_ link: StreamLink, for url: URL) {
        lock.withLock {
            links[url] = link
            asking[url] = nil
        }
    }

    private func forget(_ url: URL) {
        lock.withLock {
            links[url] = nil
            asking[url] = nil
        }
    }
}
