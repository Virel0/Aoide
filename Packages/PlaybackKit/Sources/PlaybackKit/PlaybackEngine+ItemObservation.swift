#if os(iOS)

import AVFoundation
import Foundation

// MARK: - Per-item observation

extension PlaybackEngine {
    /// An item that failed to load, with what has been worked out about it.
    private struct ItemFailure {
        let key: ObjectIdentifier
        let entryId: UUID
        /// Consecutive failures of this entry, or `Int.max` for a local file.
        let failures: Int
        let isLocal: Bool
        let message: String
    }

    func observations(for item: AVPlayerItem) -> [NSKeyValueObservation] {
        // KVO fires on whichever thread mutated the property, and AVFoundation uses
        // its own queues — so read what's needed synchronously, then hop to the main
        // actor carrying only Sendable values.
        let status = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let status = item.status
            let assetDuration = item.duration.validDuration
            // The description alone is "The operation couldn't be completed"; the
            // domain and code are what name the cause.
            let errorMessage = (item.error as NSError?).map { error in
                "\(error.localizedDescription) [\(error.domain) \(error.code)]"
            }
            let key = ObjectIdentifier(item)
            Task { @MainActor [weak self] in
                self?.handleStatus(status, key: key, assetDuration: assetDuration, error: errorMessage)
            }
        }

        let buffering = item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { [weak self] item, _ in
            let likely = item.isPlaybackLikelyToKeepUp
            let key = ObjectIdentifier(item)
            Task { @MainActor [weak self] in
                self?.handleBuffering(likely, key: key)
            }
        }

        return [status, buffering]
    }

    private func handleStatus(
        _ status: AVPlayerItem.Status,
        key: ObjectIdentifier,
        assetDuration: Duration?,
        error: String?
    ) {
        // An item waiting on the spare deck is not part of this deck's window and
        // must not touch its state — but a blend whose track cannot be loaded is
        // no longer a blend, and the handover has to become a plain cut before the
        // outgoing track runs out of deck.
        if blend?.itemKey == key {
            handleBlendItemStatus(status, key: key, assetDuration: assetDuration, error: error)
            return
        }

        // Several items are alive at once now; only the playing one may drive state.
        let isCurrent = player.currentItem.map { ObjectIdentifier($0) == key } ?? false

        switch status {
        case .readyToPlay:
            handleItemReady(key: key, assetDuration: assetDuration, isCurrent: isCurrent)
        case .failed:
            handleItemFailed(key: key, error: error, isCurrent: isCurrent)
        default:
            break
        }
    }

    private func handleBlendItemStatus(
        _ status: AVPlayerItem.Status,
        key: ObjectIdentifier,
        assetDuration: Duration?,
        error: String?
    ) {
        switch status {
        case .readyToPlay:
            if let assetDuration { assetDurations[key] = assetDuration }
        case .failed:
            log.warning("The track to blend in failed to load; cutting instead: \(error ?? "no reason given", privacy: .public)")
            cancelBlend()
        default:
            break
        }
    }

    private func handleItemReady(key: ObjectIdentifier, assetDuration: Duration?, isCurrent: Bool) {
        // Cache regardless of whether this item is current. Look-ahead items
        // become ready while still queued, and `status` only transitions once —
        // so not caching here means every track after the first falls back to
        // the server's metadata for its length.
        if let assetDuration { assetDurations[key] = assetDuration }
        if let entryId = entryForItem[key] { loadFailures[entryId] = nil }
        guard isCurrent else { return }
        lastFailure = nil
        if let assetDuration { duration = assetDuration }

        // Ask again. `play()` is called the instant the items are inserted,
        // which on a cold connection is before anything can decode — and
        // AVQueuePlayer does not retry on our behalf once the item finally
        // becomes ready. Without this, tapping a track from a list left the
        // car sitting at 0:00 with a play glyph until someone pressed play.
        if intendsToPlay, player.rate == 0 {
            player.play()
        }

        if state == .buffering { state = intendsToPlay ? .playing : .paused }
        updateNowPlayingInfo()
    }

    private func handleItemFailed(key: ObjectIdentifier, error: String?, isCurrent: Bool) {
        let message = error ?? "This track couldn't be played."
        // Read the entry id BEFORE releasing, which clears the mapping.
        guard let entryId = entryForItem[key] else { return }
        let track = queue.entries.first { $0.id == entryId }?.track
        // A file on this device does not come back after a wait. Retrying it
        // is thirty seconds of a spinner over a missing file; give up now,
        // remember why, and let the screen say so.
        let isLocal = track?.streamURL.isFileURL ?? false
        let failures = isLocal ? Int.max : (loadFailures[entryId] ?? 0) + 1
        loadFailures[entryId] = failures
        if isLocal, let track {
            lastFailure = PlaybackFailure(trackTitle: track.title, message: message)
            log.error("Local file failed: \(track.title, privacy: .public): \(message, privacy: .public)")
        }

        let failure = ItemFailure(key: key, entryId: entryId, failures: failures, isLocal: isLocal, message: message)
        if isCurrent {
            retryOrSkipCurrent(failure)
        } else {
            setAsideQueued(failure)
        }
    }

    private func retryOrSkipCurrent(_ failure: ItemFailure) {
        let message = failure.message
        if let delay = LoadRetryPolicy.delay(afterFailures: failure.failures, whileQueued: false) {
            // Almost always a phone between cell towers, not a bad track.
            // Keep the spinner and try again shortly; the listener sees
            // buffering, which is the truth.
            log.warning("Track failed to load (\(failure.failures)), retrying in \(delay.seconds)s: \(message, privacy: .public)")
            if intendsToPlay { state = .buffering }
            scheduleRetry(of: failure.entryId, after: delay)
        } else {
            log.error("Playback failed, giving up: \(message, privacy: .public)")
            failedEntries.insert(failure.entryId)
            skipPastDeadCurrent(message: message)
        }
    }

    /// A queued track failed while something else plays. Don't interrupt
    /// the music — take it out of the window so the boundary doesn't
    /// stall on it, and put it back once the delay has passed. Dropping
    /// it outright is what used to make songs vanish on a walk.
    private func setAsideQueued(_ failure: ItemFailure) {
        let key = failure.key
        if failure.isLocal {
            failedEntries.insert(failure.entryId)
        } else {
            coolingEntries.insert(failure.entryId)
        }
        if let item = player.items().first(where: { ObjectIdentifier($0) == key }) {
            player.remove(item)
        }
        enqueued.removeAll { $0 == key }
        release(key: key)
        syncPlayer()
        if !failure.isLocal {
            let delay = LoadRetryPolicy.delay(afterFailures: failure.failures, whileQueued: true) ?? .seconds(16)
            log.warning("Queued track failed to load (\(failure.failures)), retrying in \(delay.seconds)s: \(failure.message, privacy: .public)")
            scheduleRetry(of: failure.entryId, after: delay)
        }
    }

    private func handleBuffering(_ likelyToKeepUp: Bool, key: ObjectIdentifier) {
        guard state != .idle else { return }
        guard player.currentItem.map({ ObjectIdentifier($0) == key }) ?? false else { return }
        if likelyToKeepUp, state == .buffering {
            state = intendsToPlay ? .playing : .paused
        }
    }
}

#endif
