import CurationKit
import Foundation
import JellyfinKit
import PlaybackKit

/// The two things the engine's reports can't carry: where a queue came from, and the
/// full metadata behind each track in it.
///
/// `PlaybackReporter` hands over a `Track`, which is deliberately everything the
/// *player* needs and nothing more — no genres, no year, no album artist held apart
/// from the track artist, and no memory of whether the listener tapped an album, a
/// search result, or asked Siri. The curation store wants all of it: recaps group by
/// artist, smart playlists filter on genre and year, and "mostly from playlists" is a
/// sentence only a recorded source can write.
///
/// Widening `Track` would be the obvious fix and is the wrong one — PlaybackKit stays
/// about playing audio, and a queue model that knows what a genre is has stopped being
/// testable without a server. So the app remembers it here instead, keyed off the queue
/// entries the engine already exposes.
@MainActor
enum PlaybackContext {
    /// Where each live queue entry came from.
    ///
    /// Keyed by entry rather than by track id because one queue can legitimately hold
    /// the same song twice, having arrived from two different places.
    private static var sources: [UUID: PlaySource] = [:]

    /// What Jellyfin knows about each live track, by id. Tracks are the same object in
    /// every queue slot, so this one is keyed by track.
    private static var metadata: [String: TrackRef] = [:]

    // MARK: - Recording context

    /// Runs a queue mutation and attributes everything it introduces to `source`.
    ///
    /// Wrapping the mutation rather than passing a source down into the engine is what
    /// keeps PlaybackKit ignorant of the curation store, and it works identically for a
    /// fresh queue, a Play Next and an append: whatever is queued afterwards and wasn't
    /// before came from `source`. Entries that were already there keep the source they
    /// arrived with, so queuing a search result behind an album doesn't retroactively
    /// file the album under search.
    ///
    /// Also the only place either map shrinks. Both are pruned to what is actually
    /// queued, so shuffling a library doesn't leave thousands of rows behind after the
    /// listener moves on to one album.
    @discardableResult
    static func attributing<T>(_ source: PlaySource, _ mutate: () -> T) -> T {
        let before = Set(PlaybackEngine.shared.queue.entries.map(\.id))
        let result = mutate()

        var attributed: [UUID: PlaySource] = [:]
        var kept: [String: TrackRef] = [:]
        for entry in PlaybackEngine.shared.queue.entries {
            attributed[entry.id] = before.contains(entry.id) ? (sources[entry.id] ?? source) : source
            if let known = metadata[entry.track.id] { kept[entry.track.id] = known }
        }
        sources = attributed
        metadata = kept
        return result
    }

    /// Remembers what Jellyfin knows about these items for as long as they stay queued.
    ///
    /// Called as items are mapped into tracks, because that is the last moment the full
    /// item is in hand — by the time anything plays, only the `Track` survives.
    static func remember(_ items: [JellyfinItem]) {
        let now = Date().millis
        for item in items where item.type == .audio {
            // One derivation, shared with the library index — see `TrackCatalogue`. The
            // content key is what a playlist entry survives a rescan by, so two
            // derivations differing by a character would mean rows that can never be
            // relinked to each other.
            metadata[item.id] = TrackCatalogue.trackRef(for: item, at: now)
        }
    }

    /// Drops everything. Called on sign-out, when the queue is emptied and none of this
    /// belongs to the next account.
    static func clear() {
        sources = [:]
        metadata = [:]
    }

    // MARK: - Reading it back

    /// Where the track a report names came from.
    ///
    /// Matched through the queue's current entry, but only after checking that entry is
    /// still the track being reported: each report is its own task, so a fast run of
    /// skips can deliver one after the queue has moved past it. Attributing a play to
    /// whatever the listener tapped *next* is worse than admitting we don't know.
    static func source(of track: Track) -> PlaySource {
        let queue = PlaybackEngine.shared.queue
        if let current = queue.current, current.track.id == track.id {
            return sources[current.id] ?? .unknown
        }
        // Failing that, any slot holding the same song. Everything queued by one tap
        // shares a source, so this is only ambiguous in the case the entry key exists
        // for — the same song queued twice from two places — and it is still better
        // than nothing there.
        if let entry = queue.entries.first(where: { $0.track.id == track.id }) {
            return sources[entry.id] ?? .unknown
        }
        return .unknown
    }

    /// The `track` cache row for a track that is starting, as complete as the app can
    /// make it.
    static func cacheRow(for track: Track, at now: Millis) -> TrackRef {
        if var known = metadata[track.id] {
            known.lastSeenAt = now
            return known
        }

        // Nothing in this session mapped this track — a queue restored from disk, or a
        // path that reached the engine without going through the bridge. What `Track`
        // carries is enough to count a play against; the fields only Jellyfin knows stay
        // empty until the song is played from a list again.
        //
        // The one cost is the content key, which is built from the artist: `Track.artist`
        // is the *album* artist where there is one, so a compilation resolved this way
        // gets a different key than the same track resolved from its Jellyfin item, and
        // relinking after a rescan would miss it. Rare, and recoverable the next time
        // the track is played from a list.
        let durationMs = track.duration.map { Int(($0.seconds * 1000).rounded()) }
        return TrackRef(
            jellyfinId: track.id,
            contentKey: ContentKey.make(
                artist: track.artist,
                album: track.album,
                title: track.title,
                durationMs: durationMs
            ),
            title: track.title,
            artist: track.artist,
            album: track.album,
            durationMs: durationMs,
            lastSeenAt: now
        )
    }

}
