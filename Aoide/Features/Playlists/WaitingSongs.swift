import CurationKit
import MeleteKit
import os

/// Where the songs waiting in a playlist stand, in the words Requests uses.
///
/// A waiting song names its request by id, and this user's music requests say how
/// each is getting on: one read of them answers every waiting row on screen.
enum WaitingSongs {
    private static let log = Logger(subsystem: AppIdentity.bundle, category: "curation")

    /// This user's music requests by id, when any of `songs` waits on one; `nil` when
    /// none does or the server couldn't say.
    static func requests(for songs: [PendingSong], client: MeleteClient) async -> [Int64: MusicRequest]? {
        guard songs.contains(where: { $0.requestId != nil }) else { return nil }
        do {
            let requests = try await client.musicRequests()
            return Dictionary(requests.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        } catch {
            log.debug("Couldn't read requests for waiting songs: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// "Waiting for approval", "Downloading, 40%", or "Not found: why" for a song
    /// nothing could be asked for. "Asked for" when the request can't be read.
    static func standing(of song: PendingSong, in requests: [Int64: MusicRequest]?) -> String {
        guard let requestId = song.requestId else {
            return song.why.map { "Not found: \($0)" } ?? "Not found"
        }
        return requests?[requestId]?.standing ?? "Asked for"
    }
}
