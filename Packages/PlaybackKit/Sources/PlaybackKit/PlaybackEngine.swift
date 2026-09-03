// `AVAudioSession` and `UIImage` don't exist on macOS. The guard exists purely so
// the package still builds on the host for `swift test` — the queue logic in
// PlayQueue.swift is the part worth testing there, and it stays platform-free.
#if os(iOS)

import AVFoundation
import Foundation
import MediaPlayer
import UIKit
import os

/// The single source of truth for what is playing.
///
/// There is exactly one of these per process, and both the phone UI and the CarPlay
/// scene drive it. That's the whole design constraint: CarPlay is a separate scene
/// that can connect before the phone UI has ever appeared, so if playback state
/// lived in a view model the two screens would disagree about what's playing.
///
/// ## Gapless, and the authority inversion it forces
///
/// Gapless playback requires the *player* to hold the next track already decoded,
/// which means `AVQueuePlayer` advances itself at a track boundary and tells us
/// afterwards. That inverts who is in charge: ``PlayQueue`` no longer drives the
/// player at a boundary, it follows it. Every user action still mutates the queue
/// first and then calls ``syncPlayer()``; only an automatic advance runs the other
/// way, through the `currentItem` observer.
///
/// Measured effect on a FLAC library: ~130ms of silence between tracks before,
/// ~57ms after. The residue is Apple's FLAC reader rounding each track up to a
/// whole block and decoding the padding as silence — not something this code can
/// remove. ALAC or AAC sources reach ~5ms through the same path.
@MainActor
@Observable
public final class PlaybackEngine {
    public static let shared = PlaybackEngine()

    // MARK: - Observable state

    public private(set) var queue = PlayQueue()
    public private(set) var state: PlaybackState = .idle
    public private(set) var elapsed: Duration = .zero
    /// The real duration once the asset loads, which can differ from the server's
    /// metadata — trust this one for the scrubber.
    public private(set) var duration: Duration?

    public var currentTrack: Track? { queue.currentTrack }

    /// Where the listener actually is in the track, as opposed to where the player
    /// has got to.
    ///
    /// The media clock reports when audio was handed to the renderer, not when it
    /// reaches someone's ears. Over wired output the difference is 10–40ms and
    /// invisible; over AirPods or car Bluetooth it is routinely 150–300ms. A sung
    /// word lasts 150–400ms, so lyrics highlighted off the raw clock sit a full word
    /// ahead of the audio — the single thing most likely to make this feature feel
    /// broken.
    ///
    /// Read fresh on each access rather than from the 0.5s observer, which is far
    /// too coarse to follow a lyric line. Used for lyrics only: seeking and the
    /// scrubber stay on the raw clock, where a latency correction would be wrong.
    public var audibleElapsed: Duration? {
        let time = player.currentTime()
        guard time.isNumeric, time.seconds.isFinite else { return nil }
        return .seconds(max(0, time.seconds - outputLatency - lyricsOffset.seconds))
    }

    /// Manual nudge for lyric timing, in addition to the automatic correction.
    ///
    /// Bluetooth codec latency is under-reported by the OS, so the automatic figure
    /// gets close but not exact — and how close varies by headphone. Apple Music
    /// exposes the same control for the same reason.
    public var lyricsOffset: Duration = .zero

    /// Cached because reading it is not free and it only changes with the route.
    private var outputLatency: TimeInterval = 0

    public var repeatMode: RepeatMode {
        get { queue.repeatMode }
        set {
            queue.repeatMode = newValue
            // Repeat mode changes what should be queued behind the current track.
            syncPlayer()
            updateNowPlayingInfo()
        }
    }

    public var isShuffled: Bool { queue.isShuffled }

    // MARK: - Collaborators

    public weak var reporter: (any PlaybackReporter)?
    public var artworkLoader: ArtworkLoader?

    // MARK: - Private

    private let log = Logger(subsystem: "com.example.aoide", category: "playback")
    private let player = AVQueuePlayer()

    /// How many tracks to keep decoded behind the current one. Two is enough for a
    /// seamless boundary while keeping wasted prefetch small when someone is
    /// skipping around.
    private let lookahead = 2

    /// What is currently loaded into the player, in order, identified by object
    /// identity. `enqueued[i]` corresponds to `player.items()[i]`.
    ///
    /// Object identity rather than the queue entry's id, because repeat-one loads
    /// the same entry as two distinct `AVPlayerItem`s and locating "the one that is
    /// playing now" has to distinguish them. Ordering is what makes the *diff*
    /// work: position `i` in both lists means "the i-th thing that will play", so
    /// comparing entry ids index-wise is exact.
    private var enqueued: [ObjectIdentifier] = []

    /// Maps a live `AVPlayerItem` back to the queue entry it renders.
    private var entryForItem: [ObjectIdentifier: UUID] = [:]

    /// Real decoded durations, which can differ from the server's metadata. Cached
    /// per item because a look-ahead item reaches `.readyToPlay` long before it
    /// becomes current, and `status` only transitions once.
    private var assetDurations: [ObjectIdentifier: Duration] = [:]

    /// Entries given up on. Filtered out of the render window so a dead track
    /// doesn't get re-enqueued, fail, and be re-enqueued forever. Cleared whenever a
    /// new queue is loaded.
    private var failedEntries: Set<UUID> = []

    /// Entries whose item failed and which are waiting out a retry delay. Filtered
    /// from the window like `failedEntries`, but only until their timer fires and
    /// puts them back — see ``LoadRetryPolicy``.
    private var coolingEntries: Set<UUID> = []

    /// Consecutive load failures per entry, reset the moment one loads.
    private var loadFailures: [UUID: Int] = [:]

    /// The pending retry per entry, so a deliberate action can cancel it.
    private var retryTasks: [UUID: Task<Void, Never>] = [:]

    /// How far ahead of the playhead to buffer, in seconds.
    ///
    /// Long enough to hold a whole track: once a song has started over cellular it
    /// should finish under a bridge. The default buffers only a few seconds, which
    /// is tuned for video and for data plans, not for someone walking to the gym.
    /// Lossless audio runs to a few megabytes a minute, so this is tens of
    /// megabytes of memory at most.
    private static let forwardBufferSeconds: TimeInterval = 600

    /// Per-item KVO, keyed so several simultaneously live items can each be
    /// observed. The previous single-observation design silently stopped watching
    /// the earlier item as soon as a second one existed.
    private var itemObservations: [ObjectIdentifier: [NSKeyValueObservation]] = [:]

    private var timeObserver: Any?
    private var currentItemObservation: NSKeyValueObservation?
    private var rateObservation: NSKeyValueObservation?

    /// Throttles progress reports to the server to roughly one every 10s.
    private var lastReportedSecond: Int = -1

    /// What the user asked for, as distinct from what the player has managed yet.
    ///
    /// `AVPlayer.rate` is still 0 for a moment after `play()`, so deriving state
    /// from it when an item becomes ready latched `.paused` while audio was
    /// actually playing — and nothing corrected it afterwards, because the
    /// recovery paths only promote from `.buffering`. The car showed a play
    /// triangle and a frozen clock over music that was running.
    private var intendsToPlay = false

    /// Pressing previous within this window goes to the previous track; after it,
    /// previous restarts the current one. Matches Apple Music.
    private let restartThreshold: Duration = .seconds(3)

    private init() {
        // `.advance` is what makes the handoff gapless. It also raises
        // NSInvalidArgumentException on a plain AVPlayer, so it and AVQueuePlayer
        // have to change together.
        player.actionAtItemEnd = .advance
        player.automaticallyWaitsToMinimizeStalling = true
        observeCurrentItem()
        observeRate()
        observePlayerTime()
        configureRemoteCommands()
        observeAudioSessionEvents()
        refreshOutputLatency()
    }

    private func refreshOutputLatency() {
        let session = AVAudioSession.sharedInstance()
        outputLatency = session.outputLatency + session.ioBufferDuration
    }

    // MARK: - Loading

    /// Replaces the queue and starts playing.
    public func play(_ tracks: [Track], startingAt index: Int = 0, shuffled: Bool = false) {
        guard !tracks.isEmpty else { return }
        stopReportingCurrent()
        // A fresh queue gets a fresh chance for anything that failed before — the
        // failure may well have been a passing network problem.
        forgetLoadFailures()
        queue.load(tracks, startingAt: index, shuffled: shuffled)
        beginCurrentTrack(autoplay: true)
    }

    public func playNext(_ tracks: [Track]) {
        // Into an empty queue this becomes a load, so it has to actually start —
        // otherwise the track sits loaded and silent and is never reported.
        let wasEmpty = queue.isEmpty
        queue.playNext(tracks)
        if wasEmpty {
            beginCurrentTrack(autoplay: true)
        } else {
            syncPlayer()
        }
    }

    public func addToQueue(_ tracks: [Track]) {
        let wasEmpty = queue.isEmpty
        queue.append(tracks)
        if wasEmpty {
            beginCurrentTrack(autoplay: true)
        } else {
            syncPlayer()
        }
    }

    public func clearQueue() {
        stopReportingCurrent()
        forgetLoadFailures()
        queue.clear()
        finishPlayback()
    }

    // MARK: - Transport

    public func togglePlayPause() {
        switch state {
        case .playing: pause()
        case .paused, .idle, .buffering, .failed: resume()
        }
    }

    public func resume() {
        guard queue.current != nil else { return }

        // Rebuild whenever what's loaded is unusable, not only when it's missing.
        // AVQueuePlayer does not advance past a failed item, so without this a
        // retry called `play()` on a dead item and the UI claimed to be playing
        // with silence coming out — permanently.
        let loadedItemIsDead = player.currentItem?.status == .failed
        var stateIsFailed = false
        if case .failed = state { stateIsFailed = true }

        if player.currentItem == nil || loadedItemIsDead || stateIsFailed {
            // The server never saw a Stopped for the track that died.
            stopReportingCurrent()
            beginCurrentTrack(autoplay: true)
            return
        }

        intendsToPlay = true
        player.play()
        state = .playing
        updateNowPlayingInfo()
        report { await $0.playbackDidProgress($1, position: $2, isPaused: false) }
    }

    public func pause() {
        intendsToPlay = false
        player.pause()
        state = .paused
        updateNowPlayingInfo()
        report { await $0.playbackDidProgress($1, position: $2, isPaused: true) }
    }

    public func next() {
        // If the player auto-advanced while this tap was in flight, adopt where it
        // actually is before skipping — otherwise the queue skips from a stale
        // position and the listener loses a whole track. Reconciling reports the
        // outgoing track itself, so don't report it twice.
        if !reconcileWithPlayer() {
            stopReportingCurrent()
        }
        switch queue.skipToNext() {
        case .moved, .repeatCurrent:
            beginCurrentTrack(autoplay: true)
        case .ended:
            stopReportingCurrent()
            finishPlayback()
        }
    }

    /// Previous restarts the current track unless we're still near its beginning.
    public func previous() {
        // Reconcile first. Right after a boundary `elapsed` still holds the
        // *outgoing* track's position, so testing the restart rule before adopting
        // the new track would restart the one that just started instead of going
        // back to the one that just finished.
        let advanced = reconcileWithPlayer()

        if !advanced, elapsed > restartThreshold {
            seek(to: .zero)
            return
        }

        // Report the outgoing track BEFORE the queue moves — `stopReportingCurrent`
        // reads `queue.currentTrack`, so afterwards it would attribute the stop to
        // the track being moved to. But only report at all if we actually leave:
        // at the head of the queue `skipToPrevious` returns `.ended` and the track
        // carries on playing, and closing its server session then leaves the rest
        // of the play unrecorded.
        var probe = queue
        let willMove = probe.skipToPrevious() != .ended

        if !advanced, willMove { stopReportingCurrent() }

        switch queue.skipToPrevious() {
        case .moved, .repeatCurrent:
            beginCurrentTrack(autoplay: true)
        case .ended:
            seek(to: .zero)
        }
    }

    public func jump(to entryId: UUID) {
        guard queue.current?.id != entryId else { return }
        // Report the outgoing track before moving, or the stop is attributed to
        // the track the user just jumped to.
        stopReportingCurrent()
        guard queue.jump(to: entryId) else { return }
        beginCurrentTrack(autoplay: true)
    }

    /// How far off the requested position the player may land.
    ///
    /// Zero forces a sample-accurate seek: the player must fetch and decode from
    /// the sync point *preceding* the target before anything resumes. Over a
    /// network stream that stalls for as long as it takes, and
    /// `addPeriodicTimeObserver` does not fire while it does — so the scrubber
    /// freezes at wherever it was and the audio goes quiet, which reads as the app
    /// hanging. A quarter-second is inaudible when a finger just dragged across a
    /// four-minute song, and it lets the player land on a sync point it already
    /// holds.
    private static let seekTolerance = CMTime(seconds: 0.25, preferredTimescale: 600)

    /// The player's SharePlay coordinator.
    ///
    /// Exposed so the app can attach a `GroupSession` to it without PlaybackKit
    /// importing GroupActivities — this package stays about playing audio, and the
    /// question of who else is listening belongs a layer up.
    public var playbackCoordinator: AVPlayerPlaybackCoordinator { player.playbackCoordinator }

    public func seek(to position: Duration) {
        let clamped = max(.zero, min(position, duration ?? position))
        player.seek(
            to: clamped.cmTime,
            toleranceBefore: Self.seekTolerance,
            toleranceAfter: Self.seekTolerance
        )
        elapsed = clamped
        updateNowPlayingInfo()
        report { await $0.playbackDidProgress($1, position: $2, isPaused: !self.state.isPlaying) }
    }

    public func setShuffled(_ shuffled: Bool) {
        queue.setShuffled(shuffled)
        syncPlayer()
    }

    public func remove(entryId: UUID) {
        let wasCurrent = queue.current?.id == entryId
        queue.remove(entryId: entryId)
        if wasCurrent {
            if queue.current == nil {
                finishPlayback()
            } else {
                beginCurrentTrack(autoplay: state.isPlaying)
            }
        } else {
            syncPlayer()
        }
    }

    public func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        queue.move(fromOffsets: source, toOffset: destination)
        syncPlayer()
    }

    // MARK: - Starting a track

    /// Starts whatever the queue now says is current, from the beginning.
    private func beginCurrentTrack(autoplay: Bool) {
        guard let track = queue.currentTrack else {
            finishPlayback()
            return
        }

        // Every caller here is a deliberate user action or a fresh load, never the
        // automatic boundary — so a track being asked for by name earns another try
        // even if it failed earlier. Auto-advance past a dead track still works,
        // because there the failed entry sits behind the head and stays filtered.
        if let id = queue.current?.id { forgetLoadFailures(of: id) }

        elapsed = .zero
        duration = track.duration
        lastReportedSecond = -1
        intendsToPlay = autoplay
        state = autoplay ? .buffering : .paused

        // Rebuild rather than advanceToNextItem(): measured, advanceToNextItem
        // inserts ~600ms of real dead air on a deliberate skip, while rebuilding
        // costs ~175ms locally. Over a slow remote server the two converge, so
        // rebuild is the better single choice.
        rebuildWindow(play: autoplay)

        updateNowPlayingInfo()

        let reporter = reporter
        Task { await reporter?.playbackDidStart(track) }
    }

    /// Called when the queue runs out.
    private func finishPlayback() {
        player.pause()
        player.removeAllItems()
        releaseAllItems()
        enqueued = []
        state = .idle
        elapsed = .zero
        duration = nil
        updateNowPlayingInfo()
    }

    // MARK: - The render window

    /// The entries that should be loaded into the player right now: the current
    /// track plus `lookahead` more.
    ///
    /// The repeat and shuffle rules live in ``PlayQueue/renderWindow(count:)``,
    /// which is platform-free and unit-tested — including the subtle rule that
    /// repeat-one applies to a natural ending but not to a deliberate skip.
    private func desiredWindow() -> [RenderSlot] {
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
    private func syncPlayer() {
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

        var after = player.items().last
        for slot in desired[common...] {
            let item = makeItem(for: slot.track, entryId: slot.entryId)
            player.insert(item, after: after)
            after = item
            enqueued.append(ObjectIdentifier(item))
        }
    }

    private func rebuildWindow(play shouldPlay: Bool) {
        player.removeAllItems()
        releaseAllItems()
        enqueued = []

        var after: AVPlayerItem?
        for slot in desiredWindow() {
            let item = makeItem(for: slot.track, entryId: slot.entryId)
            player.insert(item, after: after)
            after = item
            enqueued.append(ObjectIdentifier(item))
        }
        if shouldPlay { player.play() }
    }

    /// Always builds a *fresh* item.
    ///
    /// `AVPlayerItem` is single-owner for life: re-adding a removed one, or moving
    /// one between players, raises an uncatchable `NSInvalidArgumentException` that
    /// takes the app down. The same item also cannot appear twice in one queue,
    /// which is why repeat-one needs two distinct items for one entry.
    private func makeItem(for track: Track, entryId: UUID) -> AVPlayerItem {
        let item = AVPlayerItem(url: track.streamURL)
        item.preferredForwardBufferDuration = Self.forwardBufferSeconds
        let key = ObjectIdentifier(item)
        entryForItem[key] = entryId
        itemObservations[key] = observations(for: item)
        return item
    }

    private func release(_ item: AVPlayerItem) {
        release(key: ObjectIdentifier(item))
    }

    private func release(key: ObjectIdentifier) {
        itemObservations[key]?.forEach { $0.invalidate() }
        itemObservations[key] = nil
        entryForItem[key] = nil
        assetDurations[key] = nil
    }

    private func releaseAllItems() {
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
    private func reconcileWithPlayer() -> Bool {
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

    // MARK: - Boundary

    private func observeCurrentItem() {
        // Fires exactly once per transition, including the automatic ones we don't
        // initiate. `AVPlayerItem` isn't Sendable, so only its identity crosses.
        currentItemObservation = player.observe(\.currentItem, options: [.new]) { [weak self] player, _ in
            let key = player.currentItem.map(ObjectIdentifier.init)
            Task { @MainActor [weak self] in
                self?.handleCurrentItemChanged(key)
            }
        }
    }

    /// The car and the lock screen do not poll us — they extrapolate the position
    /// from the last value we reported multiplied by the playback rate. Report a
    /// rate of zero and their clock simply stops, which is what left CarPlay frozen
    /// at 0:00 over a track that was audibly playing.
    ///
    /// `AVPlayer.rate` is the only honest source for that, and it settles some time
    /// after `play()` — so it has to be observed rather than sampled.
    private func observeRate() {
        rateObservation = player.observe(\.rate, options: [.new]) { [weak self] player, _ in
            let rate = player.rate
            Task { @MainActor [weak self] in
                self?.handleRateChanged(rate)
            }
        }
    }

    private func handleRateChanged(_ rate: Float) {
        // Reconcile: audio moving means playing, whatever we previously believed.
        if rate > 0, state != .playing {
            state = .playing
        } else if rate == 0, state == .playing, !intendsToPlay {
            state = .paused
        }
        updateNowPlayingInfo()
    }

    private func handleCurrentItemChanged(_ key: ObjectIdentifier?) {
        guard let key, let entryId = entryForItem[key] else {
            // The queue drained on its own. Report the last track's stop before
            // tearing down — otherwise the final track of every queue never counts
            // as played on the server.
            if player.currentItem == nil, !enqueued.isEmpty {
                stopReportingCurrent()
                finishPlayback()
            }
            return
        }

        // Ignore the echo from our own rebuild — that path already did this work.
        guard key != enqueued.first else { return }

        // Report the *outgoing* track before the queue moves. Reading
        // queue.currentTrack after the move would attribute the scrobble to the
        // track that just started.
        stopReportingCurrent()

        _ = queue.jump(to: entryId)

        // Release everything the player retired on its way here, or the observation
        // maps grow for the whole session.
        if let index = enqueued.firstIndex(of: key) {
            for retired in enqueued.prefix(index) { release(key: retired) }
            enqueued.removeFirst(index)
        }

        elapsed = .zero
        lastReportedSecond = -1
        // Prefer the real decoded length. A look-ahead item reaches .readyToPlay
        // while it is still queued, so its duration was cached there rather than
        // arriving now.
        duration = assetDurations[key]
            ?? player.currentItem?.duration.validDuration
            ?? queue.currentTrack?.duration
        state = player.rate > 0 ? .playing : .paused

        // Synchronous, so a car head unit never shows the previous title over the
        // new audio.
        updateNowPlayingInfo()

        if let track = queue.currentTrack {
            let reporter = reporter
            Task { await reporter?.playbackDidStart(track) }
        }

        // Top the window back up behind the new current track.
        syncPlayer()
    }

    // MARK: - Per-item observation

    private func observations(for item: AVPlayerItem) -> [NSKeyValueObservation] {
        // KVO fires on whichever thread mutated the property, and AVFoundation uses
        // its own queues — so read what's needed synchronously, then hop to the main
        // actor carrying only Sendable values.
        let status = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let status = item.status
            let assetDuration = item.duration.validDuration
            let errorMessage = item.error?.localizedDescription
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
        // Several items are alive at once now; only the playing one may drive state.
        let isCurrent = player.currentItem.map { ObjectIdentifier($0) == key } ?? false

        switch status {
        case .readyToPlay:
            // Cache regardless of whether this item is current. Look-ahead items
            // become ready while still queued, and `status` only transitions once —
            // so not caching here means every track after the first falls back to
            // the server's metadata for its length.
            if let assetDuration { assetDurations[key] = assetDuration }
            if let entryId = entryForItem[key] { loadFailures[entryId] = nil }
            guard isCurrent else { return }
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

        case .failed:
            let message = error ?? "This track couldn't be played."
            // Read the entry id BEFORE releasing, which clears the mapping.
            guard let entryId = entryForItem[key] else { return }
            let failures = (loadFailures[entryId] ?? 0) + 1
            loadFailures[entryId] = failures

            if isCurrent {
                if let delay = LoadRetryPolicy.delay(afterFailures: failures, whileQueued: false) {
                    // Almost always a phone between cell towers, not a bad track.
                    // Keep the spinner and try again shortly; the listener sees
                    // buffering, which is the truth.
                    log.warning("Track failed to load (\(failures)), retrying in \(delay.seconds)s: \(message, privacy: .public)")
                    if intendsToPlay { state = .buffering }
                    scheduleRetry(of: entryId, after: delay)
                } else {
                    log.error("Playback failed, giving up: \(message, privacy: .public)")
                    failedEntries.insert(entryId)
                    skipPastDeadCurrent(message: message)
                }
            } else {
                // A queued track failed while something else plays. Don't interrupt
                // the music — take it out of the window so the boundary doesn't
                // stall on it, and put it back once the delay has passed. Dropping
                // it outright is what used to make songs vanish on a walk.
                let delay = LoadRetryPolicy.delay(afterFailures: failures, whileQueued: true) ?? .seconds(16)
                log.warning("Queued track failed to load (\(failures)), retrying in \(delay.seconds)s: \(message, privacy: .public)")

                coolingEntries.insert(entryId)
                if let item = player.items().first(where: { ObjectIdentifier($0) == key }) {
                    player.remove(item)
                }
                enqueued.removeAll { $0 == key }
                release(key: key)
                syncPlayer()
                scheduleRetry(of: entryId, after: delay)
            }

        default:
            break
        }
    }

    /// Puts an entry back into contention once its retry delay has passed.
    ///
    /// The entry may have become current, stayed queued, or left the queue in the
    /// meantime; `syncPlayer` and `rebuildWindow` both read the queue fresh, so the
    /// right thing happens in each case without checking here.
    private func scheduleRetry(of entryId: UUID, after delay: Duration) {
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
    private func skipPastDeadCurrent(message: String) {
        var probe = queue
        guard probe.skipToNext() != .ended else {
            state = .failed(message)
            return
        }
        stopReportingCurrent()
        _ = queue.skipToNext()
        beginCurrentTrack(autoplay: intendsToPlay)
    }

    private func forgetLoadFailures() {
        retryTasks.values.forEach { $0.cancel() }
        retryTasks = [:]
        failedEntries = []
        coolingEntries = []
        loadFailures = [:]
    }

    private func forgetLoadFailures(of entryId: UUID) {
        retryTasks[entryId]?.cancel()
        retryTasks[entryId] = nil
        failedEntries.remove(entryId)
        coolingEntries.remove(entryId)
        loadFailures[entryId] = nil
    }

    private func handleBuffering(_ likelyToKeepUp: Bool, key: ObjectIdentifier) {
        guard state != .idle else { return }
        guard player.currentItem.map({ ObjectIdentifier($0) == key }) ?? false else { return }
        if likelyToKeepUp, state == .buffering {
            state = intendsToPlay ? .playing : .paused
        }
    }

    private func observePlayerTime() {
        // Twice a second: fine enough for a smooth scrubber, coarse enough not to
        // spin the CPU while the screen is off. It also drives the ~10s server
        // report below, so the interval isn't free to change.
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                self?.handleTimeUpdate(time)
            }
        }
    }

    private func handleTimeUpdate(_ time: CMTime) {
        // `validDuration` rejects the negative and indefinite times that appear
        // across a transition, which is why no generation counter is needed here.
        guard let seconds = time.validDuration else { return }
        elapsed = seconds


        // No per-tick push of the position: with an honest rate reported, the
        // system extrapolates between our updates on its own, and rewriting the
        // whole dictionary twice a second is waste. Seeks and track changes
        // already refresh it explicitly.

        let whole = Int(time.seconds)
        if whole % 10 == 0, whole != lastReportedSecond {
            lastReportedSecond = whole
            report { await $0.playbackDidProgress($1, position: $2, isPaused: !self.state.isPlaying) }
        }
    }

    // MARK: - Reporting

    private func report(
        _ body: @escaping @Sendable (any PlaybackReporter, Track, Duration) async -> Void
    ) {
        guard let reporter, let track = queue.currentTrack else { return }
        let position = elapsed
        Task { await body(reporter, track, position) }
    }

    private func stopReportingCurrent() {
        guard let reporter, let track = queue.currentTrack else { return }
        let position = elapsed
        Task { await reporter.playbackDidStop(track, position: position) }
    }

    // MARK: - Now Playing

    /// Feeds the lock screen, the Control Center widget, and the CarPlay
    /// now-playing screen. All three read this one dictionary.
    private func updateNowPlayingInfo() {
        guard let track = queue.currentTrack else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            lastArtworkTrackId = nil
            return
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyAlbumTitle: track.album,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed.seconds,
            // From the player, not our derived state. The car draws its play/pause
            // glyph from this, and anything computed from intent can disagree with
            // whether audio is actually moving — which showed as a play triangle
            // over a running track.
            MPNowPlayingInfoPropertyPlaybackRate: Double(player.rate),
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyIsLiveStream: false,
        ]
        if let duration {
            info[MPMediaItemPropertyPlaybackDuration] = duration.seconds
        }
        if let trackNumber = track.trackNumber {
            info[MPMediaItemPropertyAlbumTrackNumber] = trackNumber
        }

        // Keep the artwork already on screen if it belongs to this track, so a
        // simple pause doesn't blank the cover while the image reloads.
        if let existing = MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork],
           lastArtworkTrackId == track.id {
            info[MPMediaItemPropertyArtwork] = existing
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        loadArtworkIfNeeded(for: track)
    }

    private var lastArtworkTrackId: String?

    private func loadArtworkIfNeeded(for track: Track) {
        guard lastArtworkTrackId != track.id else { return }
        guard let url = track.artworkURL, let artworkLoader else {
            log.notice("No now-playing artwork: url=\(track.artworkURL != nil, privacy: .public) loader=\(self.artworkLoader != nil, privacy: .public)")
            lastArtworkTrackId = track.id
            return
        }
        lastArtworkTrackId = track.id

        Task { [weak self] in
            guard let data = await artworkLoader(url) else { return }
            guard let artwork = makeArtwork(from: data) else { return }
            await MainActor.run {
                guard let self, self.queue.currentTrack?.id == track.id else { return }
                MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork] = artwork
            }
        }
    }

    // MARK: - Remote commands

    /// Wires the lock screen, headphone buttons, steering-wheel controls, and the
    /// CarPlay transport bar. All of them arrive through this one command centre.
    private func configureRemoteCommands() {
        let commands = MPRemoteCommandCenter.shared()

        // These arrive from outside the app — the lock screen, a steering wheel, a
        // headphone button — and the calling thread isn't guaranteed to be main.
        // Hop to the main actor rather than asserting we're already on it.
        commands.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.resume() }
            return .success
        }
        commands.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        commands.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayPause() }
            return .success
        }
        commands.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.next() }
            return .success
        }
        commands.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previous() }
            return .success
        }
        commands.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = event.positionTime
            Task { @MainActor in self?.seek(to: .seconds(position)) }
            return .success
        }

        // Explicitly disabled: these are for podcasts and audiobooks, and leaving
        // them on puts skip-15s buttons on the CarPlay screen instead of next/prev.
        commands.skipForwardCommand.isEnabled = false
        commands.skipBackwardCommand.isEnabled = false
        commands.seekForwardCommand.isEnabled = false
        commands.seekBackwardCommand.isEnabled = false
    }

    // MARK: - Interruptions and route changes

    private func observeAudioSessionEvents() {
        let center = NotificationCenter.default

        // `Notification` isn't `Sendable`, so the raw values are pulled out here —
        // in the observer, which the `.main` queue already runs on the main thread —
        // and only plain integers cross into the actor-isolated handler.

        // Phone calls, Siri, alarms.
        center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let typeRaw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let optionsRaw = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            MainActor.assumeIsolated {
                self?.handleInterruption(typeRaw: typeRaw, optionsRaw: optionsRaw)
            }
        }

        // Headphones unplugged, Bluetooth disconnected, leaving the car.
        center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let reasonRaw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            MainActor.assumeIsolated {
                self?.handleRouteChange(reasonRaw: reasonRaw)
            }
        }
    }

    private func handleInterruption(typeRaw: UInt?, optionsRaw: UInt) {
        guard let typeRaw, let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }

        switch type {
        case .began:
            pause()
        case .ended:
            // Only resume if the system says we should — otherwise music restarting
            // itself after an unrelated alert is a nasty surprise in a car.
            if AVAudioSession.InterruptionOptions(rawValue: optionsRaw).contains(.shouldResume) {
                resume()
            }
        @unknown default:
            break
        }
    }

    private func handleRouteChange(reasonRaw: UInt?) {
        // Latency is a property of the route, so it has to be re-read on every
        // change — plugging in AirPods moves it by a couple of hundred milliseconds.
        refreshOutputLatency()

        guard let reasonRaw, let reason = AVAudioSession.RouteChangeReason(rawValue: reasonRaw) else { return }

        // The old device went away — pulled headphones, left Bluetooth range.
        // Not pausing here is how you end up blasting music from the phone speaker.
        if reason == .oldDeviceUnavailable {
            pause()
        }
    }
}

/// Builds the artwork **outside** any actor, deliberately.
///
/// `MPMediaItemArtwork` stores its request handler and calls it later, on
/// MediaPlayer's own private queue, every time it needs the image at a new size.
/// A closure formed inside a `@MainActor` context carries that isolation with it,
/// so Swift 6's executor check trips the instant MediaPlayer invokes it — an
/// `EXC_BREAKPOINT` crash the moment a track with cover art starts playing.
/// Declaring this at file scope keeps the closure non-isolated.
private func makeArtwork(from data: Data) -> MPMediaItemArtwork? {
    guard let image = UIImage(data: data) else { return nil }
    return MPMediaItemArtwork(boundsSize: image.size) { _ in image }
}

// MARK: - Time conversions

extension Duration {
    var cmTime: CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }
}

extension CMTime {
    /// `CMTime` models indefinite and unknown durations, which turn into `NaN`
    /// seconds and would poison every calculation downstream.
    var validDuration: Duration? {
        guard isValid, !isIndefinite, seconds.isFinite, seconds >= 0 else { return nil }
        return .seconds(seconds)
    }
}

#endif
