#if os(iOS)

import AVFoundation
import Foundation

// MARK: - The render window

extension PlaybackEngine {
    /// How far ahead of the playhead to buffer, in seconds.
    ///
    /// Long enough to hold a whole track: once a song has started over cellular it
    /// should finish under a bridge. The default buffers only a few seconds, which
    /// is tuned for video and for data plans, not for someone walking to the gym.
    /// Lossless audio runs to a few megabytes a minute, so this is tens of
    /// megabytes of memory at most.
    private static let forwardBufferSeconds: TimeInterval = 600

    /// The entries that should be loaded into the player right now: the current
    /// track plus `lookahead` more.
    ///
    /// The repeat and shuffle rules live in ``PlayQueue/renderWindow(count:)``,
    /// which is platform-free and unit-tested — including the subtle rule that
    /// repeat-one applies to a natural ending but not to a deliberate skip.
    private func desiredWindow() -> [RenderSlot] {
        // While a blend is prepared, the incoming track lives on the spare deck and
        // must not also sit behind the current one on this one: the outgoing track
        // has to run *out* of items so the deck falls silent and hands over. An
        // `AVPlayerItem` cannot be moved between players, so this is the only place
        // the incoming track can be.
        if blend != nil, let head = queue.renderWindow(count: 1).first {
            return [head]
        }

        let skipped = failedEntries.union(coolingEntries)
        guard !skipped.isEmpty else {
            return queue.renderWindow(count: lookahead + 1)
        }
        // Ask for extra slots so filtering a dead track still fills the window.
        //
        // The head is never filtered, even if it previously failed. Dropping it
        // would leave the player loading a *different* track than the queue says is
        // current — Now Playing, the mini player and the server report would all
        // name one song while another played.
        return queue.renderWindow(count: lookahead + 1 + skipped.count)
            .enumerated()
            .filter { $0.offset == 0 || !skipped.contains($0.element.entryId) }
            .prefix(lookahead + 1)
            .map(\.element)
    }

    /// The only function permitted to mutate the player's item list.
    ///
    /// Keeping every mutation behind one function is what stops the player's queue
    /// and ``PlayQueue`` becoming two competing sources of truth.
    func syncPlayer() {
        // The decks own playback while they have it. Filling the player's window
        // here would start a second copy of the queue playing underneath them —
        // and `rebuildWindow` would press play on it.
        guard !isUsingDecks else { return }

        let desired = desiredWindow()

        guard !desired.isEmpty else {
            if !enqueued.isEmpty { finishPlayback() }
            return
        }

        let loaded = enqueued.map { entryForItem[$0] }

        // A changed head means the user moved somewhere — rebuild wholesale.
        guard loaded.first == desired.first?.entryId else {
            rebuildWindow(play: state.isPlaying)
            return
        }

        // Otherwise only the tail can differ. Leaving an already-correct next item
        // in place is the point: rebuilding it shortly before a boundary costs
        // ~378ms of silence at exactly the moment we're trying to eliminate.
        //
        // Comparing entry ids position-wise is exact even under repeat-one, where
        // the same entry appears twice: index `i` means "the i-th thing that will
        // play" in both lists.
        let matching = zip(loaded, desired).prefix { $0 == $1.entryId }.count
        // Never slice the player's list with an index derived from ours without
        // clamping — if they ever drift, an out-of-range slice is a hard crash.
        let common = min(matching, player.items().count, enqueued.count)
        guard common < desired.count || common < enqueued.count else { return }

        let items = player.items()
        if items.count > common {
            for item in items[common...] {
                player.remove(item)
                release(item)
            }
        }
        enqueued = Array(enqueued.prefix(common))

        enqueue(desired[common...])
    }

    func rebuildWindow(play shouldPlay: Bool) {
        player.removeAllItems()
        releaseAllItems()
        enqueued = []

        enqueue(desiredWindow())
        if shouldPlay { player.play() }
    }

    /// Appends a fresh item for each slot to the end of the player's list.
    private func enqueue(_ slots: some Sequence<RenderSlot>) {
        var after = player.items().last
        for slot in slots {
            let item = makeItem(for: slot.track, entryId: slot.entryId)
            player.insert(item, after: after)
            after = item
            enqueued.append(ObjectIdentifier(item))
        }
    }

    /// Stops the player and takes everything off it.
    func emptyPlayer() {
        player.pause()
        player.removeAllItems()
        releaseAllItems()
        enqueued = []
    }

    /// Always builds a *fresh* item.
    ///
    /// `AVPlayerItem` is single-owner for life: re-adding a removed one, or moving
    /// one between players, raises an uncatchable `NSInvalidArgumentException` that
    /// takes the app down. The same item also cannot appear twice in one queue,
    /// which is why repeat-one needs two distinct items for one entry.
    func makeItem(for track: Track, entryId: UUID) -> AVPlayerItem {
        let asset = assetMaker?(track.streamURL) ?? AVURLAsset(url: track.streamURL)
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = Self.forwardBufferSeconds
        // Play only where the sound is. The end point is the item's end as far as
        // the player is concerned, so the handover to the next item is the same
        // stall-free advance as reaching the file's own end; the start is a seek
        // made while the item is still queued, so it is loaded from there.
        if let sound = track.sound ?? soundResolver?(track) {
            item.forwardPlaybackEndTime = sound.soundEnd.cmTime
            if sound.soundStart > .zero {
                item.seek(to: sound.soundStart.cmTime, toleranceBefore: .zero, toleranceAfter: .zero, completionHandler: nil)
            }
        }
        let key = ObjectIdentifier(item)
        entryForItem[key] = entryId
        itemObservations[key] = observations(for: item)
        return item
    }

    private func release(_ item: AVPlayerItem) {
        release(key: ObjectIdentifier(item))
    }

    func release(key: ObjectIdentifier) {
        itemObservations[key]?.forEach { $0.invalidate() }
        itemObservations[key] = nil
        entryForItem[key] = nil
        assetDurations[key] = nil
    }

    func releaseAllItems() {
        itemObservations.values.forEach { $0.forEach { $0.invalidate() } }
        itemObservations = [:]
        entryForItem = [:]
        assetDurations = [:]
    }

    /// Pulls ``PlayQueue`` onto whatever the player is actually playing.
    ///
    /// Needed because the player advances on its own: a tap that arrives in the
    /// window between the boundary and the observer running would otherwise act on
    /// a stale position. Returns whether it had to move.
    ///
    /// Reports the outgoing track's stop itself, because at this point the boundary
    /// observer hasn't run and nothing else will attribute it correctly.
    @discardableResult
    func reconcileWithPlayer() -> Bool {
        guard !isUsingDecks else { return false }
        guard
            let item = player.currentItem,
            let entryId = entryForItem[ObjectIdentifier(item)],
            queue.current?.id != entryId
        else { return false }

        stopReportingCurrent()
        _ = queue.jump(to: entryId)
        elapsed = .zero
        return true
    }
}

#endif
