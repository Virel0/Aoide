import Foundation
import JellyfinKit
import PlaybackKit
import os

/// Fetches and caches lyrics for whatever is playing.
///
/// Caches confirmed *absence* as well as presence, so a track without lyrics is
/// asked about once rather than on every open — most personal libraries have a
/// long tail of tracks with none.
@MainActor
@Observable
final class LyricsStore {
    enum Entry {
        case loading
        /// The server confirmed this track has no lyrics.
        case absent
        case loaded(LyricsTrack)
        case failed(String)

        var track: LyricsTrack? {
            if case .loaded(let track) = self { return track }
            return nil
        }
    }

    private(set) var entries: [String: Entry] = [:]

    /// Persisted so the user isn't re-calibrating every launch.
    var offset: Duration {
        didSet {
            UserDefaults.standard.set(offset.seconds, forKey: Self.offsetKey)
            PlaybackEngine.shared.lyricsOffset = offset
        }
    }

    private static let offsetKey = "aoide.lyricsOffset"
    private let client: JellyfinClient
    private let log = Logger(subsystem: "com.example.aoide", category: "lyrics")

    init(client: JellyfinClient) {
        self.client = client
        let stored = UserDefaults.standard.double(forKey: Self.offsetKey)
        offset = .seconds(stored)
        PlaybackEngine.shared.lyricsOffset = .seconds(stored)
        // The decks read the lyrics too: a cut is placed between two lines
        // rather than between two words of one. Only what is already loaded
        // — the engine asks on its clock and cannot wait — which is why the
        // record coming up is fetched as soon as it is queued.
        PlaybackEngine.shared.lyricLinesResolver = { [weak self] track in
            self?.lineStartsMs(for: track.id)
        }
        Diagnostics.lyricsState = { [weak self] trackId in
            switch self?.entries[trackId] {
            case .loaded(let lyrics): lyrics.isSynced ? "synced, \(lyrics.lines.count) lines" : "unsynced"
            case .absent: "absent"
            case .loading: "loading"
            case .failed(let message): "failed: \(message)"
            case nil: "not asked"
            }
        }
    }

    /// Where each synced line starts, in milliseconds, or nil when the track
    /// has no synced lyrics loaded.
    func lineStartsMs(for trackId: String) -> [Double]? {
        guard case .loaded(let lyrics) = entries[trackId], lyrics.isSynced else { return nil }
        return lyrics.lines.compactMap { $0.start.map { $0.seconds * 1_000 } }
    }

    func entry(for trackId: String) -> Entry? { entries[trackId] }

    /// Whether to offer the lyrics button at all. Anything not yet known counts as
    /// "offer it" — better a sheet that says there are none than a button that never
    /// appears for a track that has them.
    func mayHaveLyrics(_ trackId: String) -> Bool {
        if case .absent = entries[trackId] { return false }
        return true
    }

    /// Tracked separately from `entries` on purpose. Clearing the entry on cancel
    /// while using it as the in-flight marker races into a permanent spinner: task A
    /// sets `.loading`, is cancelled; task B sees non-nil and bails; A then clears
    /// it and nobody retries.
    private var inFlight: Set<String> = []

    func load(trackId: String) async {
        guard !inFlight.contains(trackId) else { return }
        // A previous failure is worth retrying; a confirmed answer is not.
        switch entries[trackId] {
        case .loaded, .absent: return
        default: break
        }

        inFlight.insert(trackId)
        entries[trackId] = .loading
        defer { inFlight.remove(trackId) }

        // A downloaded track keeps its lyrics beside its audio. Reading them first
        // means the sheet works on a plane, and saves a request when it doesn't.
        if let stored = OfflineAssets.lyrics(for: trackId) {
            entries[trackId] = stored.isEmpty ? .absent : .loaded(stored)
            return
        }

        do {
            if let lyrics = try await client.lyrics(forItem: trackId) {
                entries[trackId] = .loaded(lyrics)
            } else {
                entries[trackId] = .absent
            }
        } catch is CancellationError {
            // Dismissing Now Playing before the fetch lands must not cache a
            // permanent failure for that track.
            entries[trackId] = nil
        } catch {
            if Task.isCancelled {
                entries[trackId] = nil
                return
            }
            let message = (error as? JellyfinError)?.errorDescription ?? error.localizedDescription
            log.error("Lyrics load failed: \(message, privacy: .public)")
            entries[trackId] = .failed(message)
        }
    }

    /// Warms the lyrics of the track playing and the next: opening the sheet
    /// after a boundary is instant rather than a spinner, and the decks have
    /// the lines to cut between when the hand-over is booked.
    func prefetchUpNext() async {
        let queue = PlaybackEngine.shared.queue
        for id in [queue.currentTrack?.id, queue.upNext.first?.track.id].compactMap({ $0 }) {
            await load(trackId: id)
        }
    }

    /// Drops everything but the current track, so a long listening session doesn't
    /// hold every lyric sheet it has ever seen.
    func trim(keeping trackId: String?) {
        guard entries.count > 40 else { return }
        entries = entries.filter { $0.key == trackId }
    }
}
