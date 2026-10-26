#if os(iOS)

import Foundation

// MARK: - Reporting

extension PlaybackEngine {
    func report(
        _ body: @escaping @Sendable (any PlaybackReporter, Track, Duration) async -> Void
    ) {
        guard let reporter, let track = queue.currentTrack else { return }
        let position = elapsed
        Task { await body(reporter, track, position) }
    }

    func stopReportingCurrent() {
        guard let reporter, let track = queue.currentTrack else { return }
        let position = elapsed
        Task { await reporter.playbackDidStop(track, position: position) }
    }

    /// Opens the listen for `track` and remembers that it is open.
    func openListen(for track: Track) {
        reportedStartFor = track.id
        let reporter = reporter
        Task { await reporter?.playbackDidStart(track) }
    }

    /// Reports progress every ten seconds of the track, once per second it
    /// lands on.
    func reportProgressIfDue(atWholeSecond whole: Int) {
        guard whole % 10 == 0, whole != lastReportedSecond else { return }
        lastReportedSecond = whole
        report { await $0.playbackDidProgress($1, position: $2, isPaused: !self.state.isPlaying) }
    }
}

#endif
