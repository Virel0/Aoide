import CurationKit
import Foundation
import Intents
import JellyfinKit
import PlaybackKit
import os

/// Handles "play …" from Siri and the car's voice button.
///
/// This is `INPlayMediaIntent`, not App Intents. There is no music schema in
/// `AssistantSchemas` — Photos, Books, Files and Browser exist, music does not — so
/// SiriKit media intents remain the only route by which Siri will hand a spoken
/// music request to a third-party app.
///
/// Handled in-process rather than in an extension. A separate extension could
/// resolve the request but not start playback, because the queue and the player
/// live here; it would have to hand back and launch the app anyway.
final class MediaIntentHandler: NSObject {
    private let log = Logger(subsystem: "com.example.aoide", category: "siri")

    /// How many tracks a spoken request may queue. Enough for an artist's
    /// discography, bounded so "play everything" can't spend a minute fetching.
    private let maximumTracks = 300

    /// Music library ids, resolved once and reused. Every query below is scoped to
    /// them: unscoped, `includeItemTypes=Audio` also matches audiobook chapters,
    /// so "play something" could start reading a novel aloud in the car.
    private var scope: [String]?

    fileprivate func musicScope(_ client: JellyfinClient) async -> String? {
        if let scope { return scope.first }
        let ids = (try? await client.musicLibraries().map(\.id)) ?? []
        // Only cached on success — caching a failure would silently un-scope every
        // later request for the life of the process.
        if !ids.isEmpty { scope = ids }
        return ids.first
    }
}

// MARK: - INPlayMediaIntentHandling

extension MediaIntentHandler: @preconcurrency INPlayMediaIntentHandling {
    /// Siri asks whether we can service the request before committing to it.
    ///
    /// The response is built here rather than inside the actor hop:
    /// `INPlayMediaIntentResponse` is not `Sendable`, so it cannot cross one.
    func confirm(intent: INPlayMediaIntent) async -> INPlayMediaIntentResponse {
        let signedIn = await MainActor.run { AppSession.shared.client != nil }
        // Sending them to the app rather than failing mutely: signing in cannot
        // happen by voice.
        return INPlayMediaIntentResponse(
            code: signedIn ? .ready : .failureRequiringAppLaunch,
            userActivity: nil
        )
    }

    func handle(intent: INPlayMediaIntent) async -> INPlayMediaIntentResponse {
        guard let client = await MainActor.run(body: { AppSession.shared.client }) else {
            return INPlayMediaIntentResponse(code: .failureRequiringAppLaunch, userActivity: nil)
        }

        // "Play" with nothing else said means resume, not "pick something".
        if intent.resumePlayback == true || isBareResume(intent) {
            let resumed = await MainActor.run { () -> Bool in
                guard PlaybackEngine.shared.currentTrack != nil else { return false }
                PlaybackEngine.shared.resume()
                return true
            }
            if resumed {
                return INPlayMediaIntentResponse(code: .success, userActivity: nil)
            }
        }

        let request = MediaRequest(intent: intent)
        let items = await findTracks(for: request, client: client)

        guard !items.isEmpty else {
            log.notice("Siri asked for something not in the library: \(request.spokenDescription, privacy: .public)")
            return INPlayMediaIntentResponse(code: .failureUnknownMediaType, userActivity: nil)
        }

        await MainActor.run {
            let tracks = JellyfinPlaybackBridge.tracks(from: items, client: client)
            guard !tracks.isEmpty else { return }
            // `.siri` even when the request arrived through the car's voice button:
            // what was asked for was spoken, and that is what the source records.
            PlaybackContext.attributing(.siri) {
                PlaybackEngine.shared.play(tracks, shuffled: request.shuffled)
            }
            if let mode = request.repeatMode {
                PlaybackEngine.shared.repeatMode = mode
            }
        }

        // `.success` rather than `.handleInApp`: the app declares background audio
        // and the engine is a singleton, so playback starts without the UI ever
        // coming forward — which is the whole point when the phone is in a pocket.
        return INPlayMediaIntentResponse(code: .success, userActivity: nil)
    }

    /// "Hey Siri, play" with no subject at all.
    private func isBareResume(_ intent: INPlayMediaIntent) -> Bool {
        guard let search = intent.mediaSearch else { return intent.mediaItems?.isEmpty ?? true }
        return search.mediaName == nil
            && search.artistName == nil
            && search.albumName == nil
            && (search.genreNames?.isEmpty ?? true)
            && search.mediaIdentifier == nil
    }

    // MARK: - Resolution

    /// Turns what Siri heard into tracks.
    ///
    /// Deliberately ordered most-specific first. Siri fills several fields at once
    /// for a phrase like "play Boreas by The Oh Hellos", and searching on the
    /// broadest of them would return the artist's whole catalogue.
    private func findTracks(for request: MediaRequest, client: JellyfinClient) async -> [JellyfinItem] {
        let parent = await musicScope(client)

        // 1. A named album, optionally by a named artist.
        if let album = request.albumName {
            let matches = (try? await client.search(album, parentId: parent, limit: 25)) ?? []
            if let best = bestMatch(matches.filter { $0.type == .musicAlbum }, to: album, artist: request.artistName),
               let tracks = try? await client.tracks(inAlbum: best.id), !tracks.isEmpty {
                return tracks
            }
        }

        // 2. A named song.
        if let song = request.mediaName {
            let matches = (try? await client.search(song, parentId: parent, limit: 40)) ?? []
            let songs = matches.filter { $0.type == .audio }
            if let best = bestMatch(songs, to: song, artist: request.artistName) {
                // Everything else that matched follows it, so "play Shape of You"
                // doesn't stop dead after one track.
                let rest = songs.filter { $0.id != best.id }
                return [best] + rest
            }
            // Siri often puts an album or artist name in mediaName. Fall through
            // to those rather than giving up.
            if let album = matches.first(where: { $0.type == .musicAlbum }),
               let tracks = try? await client.tracks(inAlbum: album.id), !tracks.isEmpty {
                return tracks
            }
            if let artist = matches.first(where: { $0.type == .musicArtist }) {
                return await tracks(byArtist: artist, client: client)
            }
        }

        // 3. A named artist.
        if let artistName = request.artistName {
            let matches = (try? await client.search(artistName, parentId: parent, limit: 25)) ?? []
            if let artist = bestMatch(matches.filter { $0.type == .musicArtist }, to: artistName, artist: nil) {
                return await tracks(byArtist: artist, client: client)
            }
        }

        // 4. A genre.
        if let genre = request.genreNames.first {
            let genres = (try? await client.musicGenres(parentId: parent)) ?? []
            if let match = bestMatch(genres, to: genre, artist: nil) {
                let albums = (try? await client.albums(inGenre: match.id, parentId: parent, limit: 20)) ?? []
                return await tracks(fromAlbums: albums, client: client)
            }
        }

        // 5. Nothing recognisable, but a clear intent to hear music.
        if request.wantsAnything {
            return (try? await client.songs(parentId: parent, sort: .random, limit: maximumTracks).items) ?? []
        }
        return []
    }

    private func tracks(byArtist artist: JellyfinItem, client: JellyfinClient) async -> [JellyfinItem] {
        let albums = (try? await client.albums(byArtist: artist.id)) ?? []
        return await tracks(fromAlbums: albums, client: client)
    }

    private func tracks(fromAlbums albums: [JellyfinItem], client: JellyfinClient) async -> [JellyfinItem] {
        var all: [JellyfinItem] = []
        for album in albums {
            guard all.count < maximumTracks else { break }
            guard let tracks = try? await client.tracks(inAlbum: album.id) else { continue }
            all += tracks
        }
        return Array(all.prefix(maximumTracks))
    }

    /// Prefers an exact name, then one whose artist also matches what was said,
    /// then simply the first. Speech recognition rarely returns the exact string,
    /// so an exact-only match would reject most real requests.
    private func bestMatch(_ items: [JellyfinItem], to spoken: String, artist: String?) -> JellyfinItem? {
        guard !items.isEmpty else { return nil }
        let target = spoken.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)

        func normalised(_ s: String) -> String {
            s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        }

        if let artist {
            let wantedArtist = normalised(artist)
            if let exact = items.first(where: {
                normalised($0.name) == target && normalised($0.albumArtist ?? "").contains(wantedArtist)
            }) { return exact }
            if let byArtist = items.first(where: { normalised($0.albumArtist ?? "").contains(wantedArtist) }) {
                return byArtist
            }
        }
        return items.first { normalised($0.name) == target } ?? items.first
    }
}

// MARK: - INSearchForMediaIntentHandling

/// "Search for X on Aoide" / "find X on Aoide".
///
/// Siri picks between this and `INPlayMediaIntent` on phrasing alone, and an app
/// that declares only one of them gets told it cannot do the other. On a music app
/// both mean the same thing in practice — the person wants to hear it — so this
/// resolves identically and starts playback rather than handing back a list nobody
/// can read while driving.
extension MediaIntentHandler: @preconcurrency INSearchForMediaIntentHandling {
    func handle(intent: INSearchForMediaIntent) async -> INSearchForMediaIntentResponse {
        guard let client = await MainActor.run(body: { AppSession.shared.client }) else {
            return INSearchForMediaIntentResponse(code: .failureRequiringAppLaunch, userActivity: nil)
        }

        let request = MediaRequest(search: intent.mediaSearch)
        let items = await findTracks(for: request, client: client)

        guard !items.isEmpty else {
            log.notice("Siri searched for something not in the library: \(request.spokenDescription, privacy: .public)")
            return INSearchForMediaIntentResponse(code: .failure, userActivity: nil)
        }

        await MainActor.run {
            let tracks = JellyfinPlaybackBridge.tracks(from: items, client: client)
            guard !tracks.isEmpty else { return }
            PlaybackContext.attributing(.siri) {
                PlaybackEngine.shared.play(tracks, shuffled: request.shuffled)
            }
        }
        return INSearchForMediaIntentResponse(code: .success, userActivity: nil)
    }
}

// MARK: - What Siri heard

/// A normalised view of `INMediaSearch`, so the resolution logic isn't reading
/// Objective-C optionals and `NSNumber` booleans directly.
struct MediaRequest {
    let mediaName: String?
    let artistName: String?
    let albumName: String?
    let genreNames: [String]
    let shuffled: Bool
    let repeatMode: RepeatMode?
    /// "Play some music" — no subject, but clearly not a resume.
    let wantsAnything: Bool

    init(intent: INPlayMediaIntent) {
        self.init(search: intent.mediaSearch, shuffled: intent.playShuffled == true, repeatMode: intent.playbackRepeatMode)
    }

    init(search: INMediaSearch?) {
        self.init(search: search, shuffled: false, repeatMode: .unknown)
    }

    private init(search: INMediaSearch?, shuffled: Bool, repeatMode rawRepeat: INPlaybackRepeatMode) {
        mediaName = search?.mediaName?.trimmedNonEmpty
        artistName = search?.artistName?.trimmedNonEmpty
        albumName = search?.albumName?.trimmedNonEmpty
        genreNames = search?.genreNames?.compactMap(\.trimmedNonEmpty) ?? []
        self.shuffled = shuffled

        repeatMode = switch rawRepeat {
        case .all: .all
        case .one: .one
        case .none: RepeatMode.off
        case .unknown: nil
        @unknown default: nil
        }

        wantsAnything = mediaName == nil && artistName == nil && albumName == nil && genreNames.isEmpty
    }

    var spokenDescription: String {
        [albumName, artistName, mediaName, genreNames.first]
            .compactMap { $0 }
            .joined(separator: " / ")
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
