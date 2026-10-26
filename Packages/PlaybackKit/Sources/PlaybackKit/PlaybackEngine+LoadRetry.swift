#if os(iOS)

import Foundation

// MARK: - Load retries

extension PlaybackEngine {
    /// Puts an entry back into contention once its retry delay has passed.
    ///
    /// The entry may have become current, stayed queued, or left the queue in the
    /// meantime; `syncPlayer` and `rebuildWindow` both read the queue fresh, so the
    /// right thing happens in each case without checking here.
    func scheduleRetry(of entryId: UUID, after delay: Duration) {
        retryTasks[entryId]?.cancel()
        retryTasks[entryId] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.retryTasks[entryId] = nil
            self.coolingEntries.remove(entryId)

            if self.queue.current?.id == entryId {
                // A fresh item for the same track; the old one is dead for good.
                self.rebuildWindow(play: self.intendsToPlay)
            } else {
                self.syncPlayer()
            }
        }
    }

    /// The current track is not going to load. Move on if there is anywhere to
    /// move on to; otherwise say so.
    func skipPastDeadCurrent(message: String) {
        var probe = queue
        guard probe.skipToNext() != .ended else {
            state = .failed(message)
            return
        }
        stopReportingCurrent()
        _ = queue.skipToNext()
        beginCurrentTrack(autoplay: intendsToPlay)
    }

    func forgetLoadFailures() {
        retryTasks.values.forEach { $0.cancel() }
        retryTasks = [:]
        failedEntries = []
        coolingEntries = []
        loadFailures = [:]
    }

    func forgetLoadFailures(of entryId: UUID) {
        retryTasks[entryId]?.cancel()
        retryTasks[entryId] = nil
        failedEntries.remove(entryId)
        coolingEntries.remove(entryId)
        loadFailures[entryId] = nil
    }
}

#endif
