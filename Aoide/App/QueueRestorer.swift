import CurationKit
import Foundation
import JellyfinKit
import PlaybackKit
import os

/// Puts back what this device was playing when it was last closed.
///
/// The queue is already written to the store on every track change and every
/// progress tick — that is what the handover between devices reads — so the
/// information was always there; nothing read it back on this device. Force
/// quitting the app therefore meant starting the evening again.
///
/// Restored stopped, at the track and the second it was left on. Starting the
/// music by itself when somebody opens an app is the kind of surprise that ends
/// with the phone being silenced in a pocket.
@MainActor
enum QueueRestorer {
    private static let log = Logger(subsystem: "com.example.aoide", category: "playback")

    static func restore(client: JellyfinClient) async {
        // Anything already queued wins: the car can connect and start playing
        // before the phone's own screen has ever run.
        guard PlaybackEngine.shared.queue.isEmpty else { return }
        guard let db = CurationDatabase.shared else { return }

        let stored: QueueState? = try? await Task.detached { try db.localQueue() }.value
        guard let saved = stored, !saved.trackIdList.isEmpty else { return }

        let ids = saved.trackIdList
        guard let items = try? await client.items(ids: ids) else {
            log.info("Could not reach the server to put the queue back")
            return
        }

        // Kept in the queue's own order rather than the server's, and the
        // position is found by id: a track the library no longer has would
        // otherwise shift everything after it and resume the wrong song.
        let byId = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let ordered = ids.compactMap { byId[$0] }
        guard !ordered.isEmpty else { return }

        let startId = ids.indices.contains(saved.position) ? ids[saved.position] : ids[0]
        let start = ordered.firstIndex { $0.id == startId } ?? 0

        let mapped = JellyfinPlaybackBridge.playableTracks(from: ordered, client: client)
        guard !mapped.tracks.isEmpty else { return }
        let playableStart = mapped.sourceIndices.firstIndex { $0 >= start } ?? 0

        PlaybackEngine.shared.restore(
            mapped.tracks,
            startingAt: playableStart,
            elapsed: .milliseconds(saved.elapsedMs)
        )
        log.info("Put back \(mapped.tracks.count, privacy: .public) tracks at \(playableStart, privacy: .public)")

        // Whatever it is about to play deserves its measurements too.
        SoundBoundsSync.shared.prefetch(ids: mapped.tracks.map(\.id))
        AudioAnalysisSync.shared.prefetch(ids: mapped.tracks.map(\.id))
        BeatGridSync.shared.prefetch(ids: mapped.tracks.map(\.id))
    }
}
