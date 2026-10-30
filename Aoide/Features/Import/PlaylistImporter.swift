import CurationKit
import Foundation
import MeleteKit
import os

/// Turns a Spotify link or a CSV export into "here, and not here".
///
/// Spotify's API stopped answering questions about playlists a developer does not
/// own in early 2026, so there is no key to enter and none is asked for. The embed
/// page still lists a playlist's first hundred tracks in the clear, and the export
/// tools still write CSV; both come in here and leave as the same thing. The
/// matching rules live in `TrackMatcher`, shared with the desktop app.
@MainActor
@Observable
final class PlaylistImporter {
    enum Phase: Equatable {
        case idle
        case reading
        case matching(done: Int, total: Int)
        case finished
        case failed(String)
    }

    struct Match: Identifiable {
        let track: ImportedTrack
        let song: MusicItem?
        var id: String { track.id }
    }

    private(set) var phase: Phase = .idle
    private(set) var playlist: ImportedPlaylist?
    private(set) var matches: [Match] = []

    var found: [MusicItem] { matches.compactMap(\.song) }
    var missing: [ImportedTrack] { matches.filter { $0.song == nil }.map(\.track) }

    private let client: MeleteClient
    private let log = Logger(subsystem: AppIdentity.bundle, category: "import")

    /// Looked up a few at a time. The server answers a search in tens of
    /// milliseconds, but a hundred at once is a burst it need not be asked for.
    private static let lookupsAtOnce = 4

    init(client: MeleteClient) {
        self.client = client
    }

    func importSpotify(link: String) async {
        guard let id = SpotifyLink.playlistId(from: link) else {
            phase = .failed("That doesn't look like a Spotify playlist link.")
            return
        }
        phase = .reading
        do {
            var request = URLRequest(url: SpotifyLink.embedURL(playlistId: id))
            // The page is served to browsers; it says nothing to anything else.
            request.setValue(
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                forHTTPHeaderField: "User-Agent"
            )
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                phase = .failed("Spotify didn't share that playlist. It may be private.")
                return
            }
            let html = String(decoding: data, as: UTF8.self)
            await match(try SpotifyEmbedParser.parse(html: html))
        } catch let failure as SpotifyEmbedParser.Failure {
            log.error("Embed page changed: \(String(describing: failure), privacy: .public)")
            phase = .failed("Spotify has changed its page and the playlist couldn't be read. A CSV export still works.")
        } catch {
            phase = .failed("Couldn't reach Spotify: \(error.localizedDescription)")
        }
    }

    func importCSV(at url: URL, name: String) async {
        phase = .reading
        // A file from the Files app is outside this app's sandbox until asked for.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            await match(try PlaylistCSVParser.parse(text, name: name))
        } catch PlaylistCSVParser.Failure.noTitleColumn {
            phase = .failed("That file has no title column. Exportify's CSV is the expected shape.")
        } catch {
            phase = .failed("Couldn't read that file: \(error.localizedDescription)")
        }
    }

    private func match(_ imported: ImportedPlaylist) async {
        playlist = imported
        matches = []
        let total = imported.tracks.count
        phase = .matching(done: 0, total: total)

        // The sidecar first: one request, answered from inside the library by the
        // same rules this device would apply. A server without it, or one that
        // fails, falls through to the lookups below without a word — the result is
        // the same either way, only slower.
        if let served = await matchOnServer(imported.tracks) {
            matches = served
            phase = .finished
            return
        }

        var results: [Match] = []
        results.reserveCapacity(total)

        for chunk in stride(from: 0, to: total, by: Self.lookupsAtOnce) {
            let slice = Array(imported.tracks[chunk..<min(chunk + Self.lookupsAtOnce, total)])
            let client = client
            let found = await withTaskGroup(of: (Int, MusicItem?).self) { group in
                for (offset, track) in slice.enumerated() {
                    group.addTask { (offset, await Self.lookUp(track, client: client)) }
                }
                var songs = [MusicItem?](repeating: nil, count: slice.count)
                for await (offset, song) in group { songs[offset] = song }
                return songs
            }
            for (track, song) in zip(slice, found) {
                results.append(Match(track: track, song: song))
            }
            phase = .matching(done: results.count, total: total)
        }

        matches = results
        phase = .finished
    }

    private func matchOnServer(_ tracks: [ImportedTrack]) async -> [Match]? {
        guard !tracks.isEmpty else { return [] }
        let answers: [SidecarMatch?]
        do {
            answers = try await client.match(tracks)
        } catch {
            if !MeleteClient.isSidecarAbsent(error) {
                log.warning("Sidecar match failed, matching here instead: \(error.localizedDescription, privacy: .public)")
            }
            return nil
        }
        guard answers.count == tracks.count else { return nil }

        // The sidecar names ids; the rows to show and save are fetched by id, a
        // hundred at a time, which is one request per hundred hits rather than
        // several per track.
        let ids = answers.compactMap { $0?.jellyfinId }
        var byId: [String: MusicItem] = [:]
        for start in stride(from: 0, to: ids.count, by: 100) {
            let slice = Array(ids[start..<min(start + 100, ids.count)])
            guard let items = try? await client.items(ids: slice) else { return nil }
            for item in items { byId[item.id] = item }
        }
        return zip(tracks, answers).map { track, answer in
            Match(track: track, song: answer.flatMap { byId[$0.jellyfinId] })
        }
    }

    /// The library's best answer for one track, or nil.
    ///
    /// Searched by the *normalised* title so the server is not asked for
    /// "(Remastered 2009)"; the matcher then judges what comes back. Never
    /// throws: a search that fails is a track reported missing, which is the
    /// honest answer from here.
    private nonisolated static func lookUp(_ track: ImportedTrack, client: MeleteClient) async -> MusicItem? {
        // Asked in the title's own spelling first, then wider. See `searchTerms`.
        for term in TrackMatcher.searchTerms(for: track.title) {
            guard let items = try? await client.songs(searching: String(term.prefix(60)), limit: 40),
                  !items.isEmpty else { continue }

            let candidates = items.map { item in
                TrackMatcher.Candidate(
                    title: item.name,
                    artists: item.artists + (item.albumArtist.map { [$0] } ?? []),
                    durationMs: item.duration.map { Int($0.seconds * 1000) }
                )
            }
            if let index = TrackMatcher.best(for: track, among: candidates) {
                return items[index]
            }
        }
        return nil
    }
}
