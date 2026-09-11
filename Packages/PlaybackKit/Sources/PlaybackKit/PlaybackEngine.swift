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

    /// Two decks, like a DJ's, because one player cannot play two things at once
    /// and a crossfade is by definition two things at once.
    ///
    /// Only one of them is "the player" at any moment; ``player`` is that one, and
    /// every path in this file that is not about mixing goes through it and cannot
    /// tell there is a second. The spare deck is silent and empty except during a
    /// blend, when it holds the incoming track and takes over as the outgoing one
    /// ends. See ``MixTransition``.
    ///
    /// Both are queue players, so an album run still hands over the way it always
    /// has — inside one deck, with `AVQueuePlayer`'s own seamless advance. The
    /// mixer is not allowed anywhere near a record that segues.
    private let deckA = AVQueuePlayer()
    private let deckB = AVQueuePlayer()
    private var playingDeckB = false

    /// The deck the listener is hearing as the current track.
    private var player: AVQueuePlayer { playingDeckB ? deckB : deckA }

    /// The deck a blend is prepared on.
    private var spareDeck: AVQueuePlayer { playingDeckB ? deckA : deckB }

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

    /// Asked, at the moment an item is made, for bounds a track did not carry —
    /// the app's cache of what the server has measured, which may have arrived
    /// after the queue was built. Main-actor, synchronous: a lookup, never a fetch.
    public var soundResolver: ((Track) -> SilenceBounds?)?

    /// How loud a track was measured to be, so every record plays at one level.
    /// Returns decibels to apply, or nil to leave the track alone. Read when a
    /// track becomes current, so an answer arriving after the queue was built
    /// still lands. See ``LoudnessNormalisation``.
    public var loudnessResolver: ((Track) -> Double?)?

    /// The tempo measured for a track, when one was measured confidently enough
    /// to report, with how well that one number describes the whole track. Only
    /// ever used to decide how long a blend should be — see ``MixPlanner``, which
    /// explains at length why it is not used to beat-match.
    public var tempoResolver: ((Track) -> Tempo?)?

    /// Crossfade: whether one song is faded into the next. Off is the player
    /// this app has always been.
    ///
    /// Turning it off mid-blend lets the blend in flight finish; stopping a
    /// crossfade halfway is more startling than the crossfade.
    public var isCrossfading = false

    /// Album lock: two consecutive tracks of one album are never mixed, so a
    /// record that segues still segues. On by default, and the reason the mixer
    /// can be left on without ruining the albums that were sequenced.
    public var isAlbumLocked = true

    /// What Auto DJ is doing right now, for a screen to show.
    ///
    /// A listener cannot tell a mix from a long crossfade by looking at a
    /// scrubber, and the difference is the whole feature — so the player says
    /// so, the way Apple's own does. `booked` also answers the question people
    /// actually have, which is not "is it mixing" but "is it *going* to".
    public enum MixState: Equatable, Sendable {
        case off
        /// The decks have this record but nothing is planned after it.
        case ready
        /// A mix into the next record is booked, and this is how long it will be.
        case booked(bars: Int)
        /// Two records are playing, and this is how far through it is — enough
        /// for a screen to draw a crossfader that means something.
        case mixing(bars: Int, progress: Double)
    }

    public private(set) var mixState: MixState = .off

    /// Auto DJ: whether tracks that can be mixed are mixed.
    ///
    /// A different thing from ``isCrossfading`` and a stricter one. A crossfade
    /// applies to any pair; a mix needs both records on this device, both
    /// gridded by the server, both steady enough to lock to, and tempi close
    /// enough to bend one into the other. When any of that is missing — which is
    /// most of the time — the pair crossfades, and that is the design.
    public var isAutoDJing = false

    /// Where a track's file is, when this device holds it. Streamed tracks
    /// cannot be mixed: `AVAudioFile` reads from disk, and a mix that might
    /// stall halfway is not a mix.
    public var localFileResolver: ((Track) -> URL?)?

    /// Where a track's beats are, as the server measured them.
    public var beatGridResolver: ((Track) -> BeatGrid?)?

    /// What a track is made of — sections, phrases, singing — as the server
    /// measured it. Optional in every sense: a mix planned without it is a mix
    /// that cannot see the music, and refuses a little less than it should.
    public var arrangementResolver: ((Track) -> Arrangement?)?

    /// The decks, made only if Auto DJ is ever turned on: an idle
    /// `AVAudioEngine` is a running audio graph, and there is no reason for one
    /// on a device whose owner never asked for this.
    private var djSession: DJSession?
    private var djMixer: DJMixer?
    /// Drives the automation and the queue while a mix is on the decks.
    private var djTimer: Timer?
    /// The entry the decks are playing, which is how a queue change is noticed.
    private var djEntryId: UUID?
    /// The entry a mix has been booked into, so the same one is not booked twice
    /// and a changed queue can cancel it.
    private var djScheduledEntryId: UUID?

    /// How long before a mix the incoming record is put on the other deck.
    ///
    /// Longer than a blend's twelve seconds because more has to be true: a file
    /// opened, a grid read, and a plan made — and because a mix booked late is a
    /// mix that does not happen, where a blend booked late merely becomes a cut.
    private static let djLead = Duration.seconds(30)

    /// The blend being prepared or performed, if any.
    private var blend: Blend?

    /// A crossfade, from the moment the incoming track is put on the spare deck
    /// to the moment that deck becomes the player.
    private struct Blend {
        let entryId: UUID
        let track: Track
        let overlap: Duration
        /// The item on the spare deck, once it exists.
        var itemKey: ObjectIdentifier?
        /// Whether the incoming track's fade-in has been attached. A blend whose
        /// fade is not ready in time becomes a cut rather than a track arriving
        /// at full volume over the one still playing.
        var isFadeReady = false
        /// Whether the incoming track is audible yet.
        var isRunning = false
        /// Where the outgoing deck's own fader started, so the fade-out is applied
        /// on top of that track's loudness levelling rather than instead of it.
        var outgoingVolume: Float = 1
    }

    /// Watches the outgoing track's clock during a blend and rides its deck's
    /// fader down. Removed the moment the blend ends, either way.
    private var fadeObserver: Any?

    /// How long before a blend the incoming track is put on the spare deck.
    ///
    /// A remote track cannot be started from nothing at the instant it is wanted
    /// — it has to be fetched and decoded first — and a blend that begins with
    /// silence is worse than no blend. Twelve seconds is comfortably more than a
    /// track needs to become ready on a slow connection, and short enough that a
    /// listener skipping around rarely pays for a preparation nobody used.
    private static let blendLead = Duration.seconds(12)

    /// The last track given up on and why, for a screen to show. Cleared when a
    /// track next loads, so it describes the current trouble and not history.
    public private(set) var lastFailure: PlaybackFailure?

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

    /// Whether music was playing when an interruption began. See ``InterruptionPolicy``.
    private var wasPlayingWhenInterrupted = false

    /// The track whose start has already been reported, so a listen is opened
    /// once and only once. A queue put back from disk deliberately reports
    /// nothing until somebody actually presses play — see ``restore(_:startingAt:elapsed:)``.
    private var reportedStartFor: String?

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
        for deck in [deckA, deckB] {
            // `.advance` is what makes the handoff gapless. It also raises
            // NSInvalidArgumentException on a plain AVPlayer, so it and AVQueuePlayer
            // have to change together.
            deck.actionAtItemEnd = .advance
            deck.automaticallyWaitsToMinimizeStalling = true
        }
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

    /// Adds songs the app went looking for when the queue was running out.
    ///
    /// Separate from ``addToQueue(_:)`` because these were not chosen: they go
    /// behind everything rather than into the hand-picked lane, and they never
    /// start playback on their own — an empty queue that fills itself would be a
    /// player that started playing while nobody was there.
    public func extendQueue(_ tracks: [Track]) {
        guard !queue.isEmpty else { return }
        queue.extend(tracks)
        syncPlayer()
    }

    /// Clears what comes next; the current track plays on.
    public func clearUpNext() {
        queue.clearUpNext()
        syncPlayer()
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

        // A phone call deactivates this app's audio session, and nothing hands it
        // back on its own: without this, every play after a call was silence, and
        // the only cure was relaunching. Cheap and idempotent, so it costs a
        // no-op on the ordinary path.
        activateSession()

        if isUsingDecks {
            intendsToPlay = true
            djSession?.resume()
            state = .playing
            updateNowPlayingInfo()
            if let track = queue.currentTrack, reportedStartFor != track.id {
                reportedStartFor = track.id
                let reporter = reporter
                Task { await reporter?.playbackDidStart(track) }
            }
            report { await $0.playbackDidProgress($1, position: $2, isPaused: false) }
            return
        }

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
        if blend?.isRunning == true { spareDeck.play() }
        state = .playing
        updateNowPlayingInfo()

        // A restored queue has reported nothing yet, so the listen opens here
        // instead — otherwise the one track somebody comes back to would be the
        // one track the history never sees.
        if let track = queue.currentTrack, reportedStartFor != track.id {
            reportedStartFor = track.id
            let reporter = reporter
            Task { await reporter?.playbackDidStart(track) }
        }
        report { await $0.playbackDidProgress($1, position: $2, isPaused: false) }
    }

    public func pause() {
        intendsToPlay = false
        if isUsingDecks {
            djSession?.pause()
            state = .paused
            updateNowPlayingInfo()
            report { await $0.playbackDidProgress($1, position: $2, isPaused: true) }
            return
        }
        player.pause()
        // A blend in flight is two decks playing; pausing one of them would leave
        // half a crossfade audible.
        if blend?.isRunning == true { spareDeck.pause() }
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
        // The fade was scheduled against the clock the listener has just moved.
        cancelBlend()
        let clamped = max(.zero, min(position, duration ?? position))

        if isUsingDecks {
            // A mix booked against where the record *was* is abandoned by the
            // session; the tick will book another if the new position still has
            // one ahead of it.
            djScheduledEntryId = nil
            try? djSession?.seek(to: clamped.seconds, at: djClock())
            elapsed = clamped
            updateNowPlayingInfo()
            report { await $0.playbackDidProgress($1, position: $2, isPaused: !self.state.isPlaying) }
            return
        }

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
        // Whatever was prepared was prepared to follow a track that is no longer
        // the one playing. The rebuild below fills the window afresh.
        cancelBlend(resync: false)

        guard let track = queue.currentTrack else {
            finishPlayback()
            return
        }

        // Every caller here is a deliberate user action or a fresh load, never the
        // automatic boundary — so a track being asked for by name earns another try
        // even if it failed earlier. Auto-advance past a dead track still works,
        // because there the failed entry sits behind the head and stays filtered.
        if let id = queue.current?.id { forgetLoadFailures(of: id) }

        // The one moment the decks can take a record: at its beginning. See
        // `shouldUseDecks`.
        if shouldUseDecks(), let entryId = queue.current?.id {
            startOnDecks(track, entryId: entryId, autoplay: autoplay)
            return
        }
        stopDecks()

        beginOnPlayer(track, autoplay: autoplay)
    }

    /// The ordinary path: the queue player, the render window, everything this
    /// engine has always done.
    private func beginOnPlayer(_ track: Track, autoplay: Bool) {
        applyLoudness(for: track)

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

        reportedStartFor = track.id
        let reporter = reporter
        Task { await reporter?.playbackDidStart(track) }
    }

    /// Puts back the queue this device was last playing, stopped, where it was.
    ///
    /// Nothing is reported: a queue restored at launch is not a listen, and
    /// counting one would put a play nobody made into the history every time the
    /// app was reopened. `resume()` opens the listen if and when it is played.
    ///
    /// Refuses if anything is already queued — the car can connect and start
    /// something before the phone's own screen has ever run, and taking that
    /// away would be worse than not restoring at all.
    public func restore(_ tracks: [Track], startingAt index: Int, elapsed: Duration) {
        guard queue.isEmpty, !tracks.isEmpty else { return }
        cancelBlend(resync: false)
        forgetLoadFailures()
        queue.load(tracks, startingAt: index)
        guard let track = queue.currentTrack else { return }

        duration = track.duration
        lastReportedSecond = -1
        intendsToPlay = false
        state = .paused
        reportedStartFor = nil
        applyLoudness(for: track)
        rebuildWindow(play: false)
        if elapsed > .zero { seek(to: elapsed) } else { self.elapsed = .zero }
        updateNowPlayingInfo()
    }

    /// Levels the current track against every other one.
    ///
    /// `AVPlayer.volume` is this app's own fader, separate from the system
    /// volume the hardware buttons move, so it is free to spend on this and the
    /// listener's own control still does what they expect. Reset to unity for a
    /// track with no measurement, or the previous track's attenuation would
    /// quietly follow it.
    private func applyLoudness(for track: Track?) {
        applyLoudness(for: track, on: player)
    }

    private func applyLoudness(for track: Track?, on deck: AVQueuePlayer) {
        guard let track, let resolve = loudnessResolver, let gain = resolve(track) else {
            deck.volume = 1
            return
        }
        deck.volume = Float(min(1, pow(10, gain / 20)))
    }

    /// Called when the queue runs out.
    private func finishPlayback() {
        cancelBlend(resync: false)
        stopDecks()
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
    private func syncPlayer() {
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

    // MARK: - Auto DJ

    /// Whether the record now playing should be played on the decks rather than
    /// through the player.
    ///
    /// Decided when a track begins and not revisited, because the decks cannot
    /// take over a record already playing: two engines cannot be joined
    /// sample-accurately mid-track, and a mix of a record we do not control the
    /// clock of is not a mix. So the question is asked once, at the only moment
    /// it can be answered — and the answer is yes only when the *next* record is
    /// already mixable, since playing on the decks buys nothing otherwise.
    private func shouldUseDecks() -> Bool {
        guard isAutoDJing else { return false }
        // Every record this device holds and the server has gridded, whether or
        // not a mix follows it.
        //
        // This used to also require the *next* record to be mixable, on the
        // reasoning that the decks bought nothing otherwise. It bought something
        // expensive: a record that turned out to have a mixable one behind it had
        // to be moved onto the decks mid-play, and a listener heard that hand-over
        // as a strange moment in the sound just as "Mix ready" appeared. The
        // decks now play the record from the start, and they perform its
        // hand-over whatever kind it turns out to be — a mix, a crossfade, or a
        // join.
        guard let track = queue.currentTrack, djItem(for: track)?.grid != nil else { return false }
        return true
    }

    /// Taking a record off the player and onto the decks, mid-play.
    ///
    /// **The rare path.** The decks now take every gridded local record from its
    /// beginning, so this is only reached when Auto DJ is switched on while
    /// something is already playing, or when a record's grid arrives after it
    /// started. It used to be the ordinary path, and a listener heard it: two
    /// engines playing the same instant of the same file drift against each
    /// other by a few milliseconds, and two copies of one recording a few
    /// milliseconds apart is a comb filter — which sounds like the volume doing
    /// something strange, exactly as it was described.
    ///
    /// It is kept because the alternative is refusing to mix for the rest of a
    /// record somebody just turned the feature on during, and it is now
    /// abandoned at the first sign of trouble rather than pressed through.
    private struct DeckTakeover {
        let startsAt: Double
        let endsAt: Double
    }

    private var takeover: DeckTakeover?

    /// How far ahead the deck is booked when taking a record over.
    private static let takeoverLead = 0.35
    /// And how long the two are crossfaded across.
    private static let takeoverFade = 0.3

    /// Asked on every time update while the player still has the record.
    private func considerDeckTakeover() {
        guard isAutoDJing, !isUsingDecks, takeover == nil, state.isPlaying, blend == nil else { return }
        guard let entryId = queue.current?.id,
              let track = queue.currentTrack,
              let item = djItem(for: track)
        else { return }

        let window = queue.renderWindow(count: 2)
        guard window.count == 2, window[1].entryId != entryId else { return }

        // Planned from where the record will be once the hand-over is done, not
        // from where it is now.
        let after = elapsed + .seconds(Self.takeoverLead + Self.takeoverFade)
        guard let transition = plannedMix(from: track, to: window[1].track, position: after) else { return }
        // Only worth moving a record for a mix that is actually close.
        guard transition.outgoingStartMs - elapsed.seconds * 1_000 <= Self.djLead.seconds * 1_000 else { return }

        beginTakeover(track, entryId: entryId, item: item)
    }

    private func beginTakeover(_ track: Track, entryId: UUID, item: DJItem) {
        let mixer = djMixer ?? DJMixer()
        djMixer = mixer
        let session = djSession ?? DJSession(mixer: mixer)
        djSession = session
        session.onTrackEnded = { [weak self] in self?.next() }

        do {
            try mixer.start()
            // A deck can only be booked against a clock that is running. Before
            // the engine has rendered anything there is no clock, the booking is
            // silently dropped, and what follows is a player faded out under a
            // deck that never started — silence, and then a stall. Wait a tick.
            guard mixer.renderTime != nil else { return }
            // The units' own latency comes off the content position: the deck
            // is booked for a moment, and what reaches the speaker at that
            // moment left the file that much earlier.
            let booked = try session.start(
                item,
                from: elapsed.seconds + Self.takeoverLead - mixer.latency,
                at: djClock(),
                inSeconds: Self.takeoverLead
            )
            guard booked else {
                log.warning("The decks would not take \(track.title, privacy: .public); leaving it on the player")
                session.stop()
                djSession = nil
                return
            }
        } catch {
            log.warning("Couldn't take \(track.title, privacy: .public) onto the decks: \(error.localizedDescription, privacy: .public)")
            djSession = nil
            return
        }

        let now = djClock()
        takeover = DeckTakeover(startsAt: now + Self.takeoverLead, endsAt: now + Self.takeoverLead + Self.takeoverFade)
        djEntryId = entryId
        djScheduledEntryId = nil
        bookedBars = nil
        mixState = .ready
        log.info("Taking \(track.title, privacy: .public) onto the decks at \(self.elapsed.seconds, privacy: .public)s")
        startDJTimer()
    }

    /// Rides the two across each other, then empties the player.
    private func runTakeover(_ moment: DeckTakeover, at now: Double) {
        guard let session = djSession else { return }
        let progress = (now - moment.startsAt) / (moment.endsAt - moment.startsAt)

        guard progress < 1 else {
            session.setCurrentVolume(scale: 1)
            player.pause()
            player.removeAllItems()
            releaseAllItems()
            enqueued = []
            player.volume = 1
            takeover = nil
            return
        }
        guard progress >= 0 else { return }

        // The same equal-power curve as everything else here, for the same
        // reason: two copies of one recording at half volume are not one copy at
        // full volume.
        player.volume = Float(MixCurve.outgoing(progress: progress))
        session.setCurrentVolume(scale: MixCurve.incoming(progress: progress))
    }

    /// Everything the decks need about a track, or nothing if it cannot be one.
    private func djItem(for track: Track) -> DJItem? {
        guard let url = localFileResolver?(track) else { return nil }
        return DJItem(
            url: url,
            sound: track.sound ?? soundResolver?(track),
            gainDb: loudnessResolver?(track),
            grid: beatGridResolver?(track),
            exitSeconds: programmedExit(for: track).map { $0 / 1_000 }
        )
    }

    /// Where the set leaves a record, in milliseconds, when one is being
    /// programmed — which is whenever Auto DJ has the record.
    ///
    /// Not only how one record becomes the next, but when: a room hears the
    /// first hook and moves on, and a record played to its last chorus and
    /// fade-out is the tell of a playlist rather than a set. See
    /// ``SetProgrammer``. Somebody who wants whole songs has Crossfade.
    private func programmedExit(for track: Track) -> Double? {
        guard isAutoDJing,
              let grid = beatGridResolver?(track),
              let arrangement = arrangementResolver?(track),
              let duration = (track.sound ?? soundResolver?(track))?.soundEnd ?? track.duration
        else { return nil }
        return SetProgrammer.exitMs(grid: grid, arrangement: arrangement, durationMs: duration.seconds * 1_000)
    }

    /// The mix from one record into another, if there is one.
    private func plannedMix(from outgoing: Track, to incoming: Track, position: Duration) -> DJTransition? {
        guard isAutoDJing,
              let outgoingGrid = beatGridResolver?(outgoing),
              let incomingGrid = beatGridResolver?(incoming),
              localFileResolver?(incoming) != nil
        else { return nil }
        // Nothing may be booked behind the playhead, and the booking itself needs
        // a moment: the file has to be opened and the deck spun up.
        return DJPlanner.plan(
            outgoing: outgoingGrid,
            incoming: incomingGrid,
            notBeforeMs: position.seconds * 1000 + 1_000,
            outgoingArrangement: arrangementResolver?(outgoing),
            incomingArrangement: arrangementResolver?(incoming),
            outgoingExitMs: programmedExit(for: outgoing)
        )
    }

    /// Starts a record on the decks.
    private func startOnDecks(_ track: Track, entryId: UUID, autoplay: Bool) {
        let mixer = djMixer ?? DJMixer()
        djMixer = mixer
        let session = djSession ?? DJSession(mixer: mixer)
        djSession = session
        session.onTrackEnded = { [weak self] in
            // The record finished with nothing mixed in behind it, which is the
            // ordinary end of a track and not a failure of anything.
            self?.next()
        }

        guard let item = djItem(for: track) else {
            beginOnPlayer(track, autoplay: autoplay)
            return
        }

        do {
            try mixer.start()
            try session.start(item, at: djClock())
        } catch {
            // A file that will not open is a file the player should try instead;
            // it knows how to fail out loud, and this does not.
            log.error("Couldn't put \(track.title, privacy: .public) on the decks: \(error.localizedDescription, privacy: .public)")
            djSession = nil
            beginOnPlayer(track, autoplay: autoplay)
            return
        }

        djEntryId = entryId
        djScheduledEntryId = nil
        bookedBars = nil
        mixState = .ready
        // The scrubber runs to where the set leaves the record, not to where
        // the file ends; a bar that stops at sixty per cent is a bar lying.
        duration = item.exitSeconds.map { .seconds($0) } ?? item.sound.map { $0.soundEnd } ?? track.duration
        elapsed = .zero
        lastReportedSecond = -1
        intendsToPlay = autoplay
        state = autoplay ? .playing : .paused
        if !autoplay { session.pause() }

        // The player is not merely idle while the decks have it — it is emptied,
        // so nothing of the old queue is left buffered behind a record it is not
        // playing.
        player.pause()
        player.removeAllItems()
        releaseAllItems()
        enqueued = []

        updateNowPlayingInfo()
        reportedStartFor = track.id
        let reporter = reporter
        Task { await reporter?.playbackDidStart(track) }

        startDJTimer()
    }

    /// The decks' own clock, in seconds. Only advances when audio does.
    private func djClock() -> Double {
        guard let time = djMixer?.renderTime, time.sampleRate > 0 else { return 0 }
        return Double(time.sampleTime) / time.sampleRate
    }

    private var isUsingDecks: Bool { djSession != nil && djEntryId != nil }

    private func startDJTimer() {
        djTimer?.invalidate()
        djLastTick = nil
        // Sixty a second. The decks' own alignment does not depend on this timer
        // — that was settled when the mix was booked — but every step it misses
        // is a step of the fade taken in one jump instead of two, and a shelf
        // moved twenty-four decibels in a few jumps is a click.
        djTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.djTick() }
        }
    }

    private func stopDecks() {
        djTimer?.invalidate()
        djTimer = nil
        djSession?.stop()
        djSession = nil
        djMixer?.stop()
        djMixer = nil
        djEntryId = nil
        djScheduledEntryId = nil
        bookedBars = nil
        mixState = .off
        // A take-over abandoned halfway would otherwise leave the player turned
        // down for good.
        takeover = nil
        player.volume = 1
    }

    /// When the automation last ran, so a stalled main thread can be named
    /// rather than guessed at.
    private var djLastTick: Double?

    private func djTick() {
        guard let session = djSession, let entryId = djEntryId else { return }
        let now = djClock()

        // A mix is the one thing here that sounds wrong when the main thread is
        // busy, and "it crackled" is not a report anybody can act on. This is.
        if let last = djLastTick, now - last > 0.2, session.phase == .mixing {
            log.warning("The mix automation was \((now - last) * 1000, privacy: .public)ms late")
        }
        djLastTick = now

        if let moment = takeover {
            runTakeover(moment, at: now)
        }

        session.update(at: now)

        // A mix that has begun means the queue has moved: the record the listener
        // is hearing arrive is the next one, and everything that reads the queue
        // — the lock screen, the car, the history — has to agree.
        if session.phase == .mixing, let scheduled = djScheduledEntryId, scheduled != entryId {
            adoptMixedTrack(scheduled)
            return
        }

        elapsed = .seconds(session.position(at: now))
        bookHandoverIfDue(at: now)

        let bars = bookedBars
        switch (session.phase, bars) {
        case (.mixing, let bars?):
            mixState = .mixing(bars: bars, progress: session.mixProgress(at: now) ?? 0)
        case (_, let bars?):
            mixState = .booked(bars: bars)
        default:
            mixState = .ready
        }

        let whole = Int(elapsed.seconds)
        if whole % 10 == 0, whole != lastReportedSecond {
            lastReportedSecond = whole
            report { await $0.playbackDidProgress($1, position: $2, isPaused: !self.state.isPlaying) }
        }
    }

    /// How many bars the booked mix runs for, if one is booked.
    private var bookedBars: Int?

    /// Books whatever hand-over the next record has earned, once it is close
    /// enough to be worth opening a second file for.
    ///
    /// The order is the whole policy: a mix if the pair can be mixed, a
    /// crossfade if Crossfade is on and the pair suits one, and otherwise a join
    /// — one record ending exactly as the next begins, which on two decks driven
    /// by one clock is a truer gapless than asking a player to advance.
    private func bookHandoverIfDue(at now: Double) {
        guard let session = djSession, session.phase == .playing, state.isPlaying else { return }
        let window = queue.renderWindow(count: 2)

        guard window.count == 2, window[1].entryId != window[0].entryId else {
            djScheduledEntryId = nil
            bookedBars = nil
            return
        }
        let next = window[1]
        // The queue moved under a booking: the record booked is not the one
        // coming any more.
        if let booked = djScheduledEntryId, booked != next.entryId {
            djScheduledEntryId = nil
            bookedBars = nil
        }
        guard djScheduledEntryId == nil, !session.hasScheduledMix else { return }
        guard let track = queue.currentTrack, let item = djItem(for: next.track) else { return }

        // Everything below books against how much of the record is left, so
        // nothing is booked while the answer is "most of it".
        let remaining = remainingSound(of: track) ?? .zero
        guard remaining <= Self.djLead else { return }

        do {
            if let transition = plannedMix(from: track, to: next.track, position: elapsed) {
                try session.schedule(transition, into: item, at: now)
                bookedBars = transition.bars
                log.info("Mixing \(track.title, privacy: .public) into \(next.track.title, privacy: .public) over \(transition.bars) bars")
            } else {
                let plan = MixPlanner.plan(
                    from: mixTrack(track),
                    to: mixTrack(next.track),
                    automix: isCrossfading,
                    albumLock: isAlbumLocked
                )
                switch plan {
                case .blend(let overlap):
                    try session.scheduleBlend(seconds: overlap.seconds, into: item, at: now)
                case .gapless, .cut:
                    try session.scheduleJoin(into: item, at: now)
                }
                bookedBars = nil
            }
            djScheduledEntryId = next.entryId
        } catch {
            log.warning("Couldn't book a hand-over: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The queue catches up with what the decks are already playing.
    private func adoptMixedTrack(_ entryId: UUID) {
        stopReportingCurrent()
        _ = queue.jump(to: entryId)
        djEntryId = entryId
        djScheduledEntryId = nil
        bookedBars = nil
        lastReportedSecond = -1
        if let track = queue.currentTrack {
            duration = programmedExit(for: track).map { .seconds($0 / 1_000) }
                ?? (track.sound ?? soundResolver?(track))?.soundEnd
                ?? track.duration
            updateNowPlayingInfo()
            reportedStartFor = track.id
            let reporter = reporter
            Task { await reporter?.playbackDidStart(track) }
        }
    }

    // MARK: - Crossfade

    /// Runs on every time update while something is playing: decides whether a
    /// blend should be prepared, started, or abandoned.
    ///
    /// Driven from the clock rather than scheduled ahead, because everything it
    /// depends on can change under it — the queue can be reordered, the next track
    /// can be removed, the toggle can go off — and a decision re-taken twice a
    /// second cannot go stale.
    private func considerBlend() {
        let window = queue.renderWindow(count: 2)

        // Nothing to hand over to, or repeat-one, which would blend a track into
        // itself. Either way, anything prepared is no longer wanted.
        guard window.count == 2, window[1].entryId != window[0].entryId, let current = queue.currentTrack else {
            cancelBlend()
            return
        }
        let next = window[1]

        if let blend {
            // The queue moved on under a prepared blend: the track it was going to
            // bring in is not the one coming next any more.
            guard blend.entryId == next.entryId else {
                cancelBlend()
                return
            }
            guard !blend.isRunning, state.isPlaying else { return }
            guard let remaining = remainingSound(of: current), remaining <= blend.overlap else { return }
            // The moment has come. If the incoming track is not ready to arrive
            // from silence, it does not arrive at all — better the plain cut this
            // player has always done than a second song at full volume over the
            // first.
            if blend.isFadeReady {
                startBlend()
            } else {
                log.warning("The blend wasn't ready in time; cutting instead")
                cancelBlend()
            }
            return
        }

        guard state.isPlaying else { return }
        guard case let .blend(overlap) = MixPlanner.plan(
            from: mixTrack(current),
            to: mixTrack(next.track),
            automix: isCrossfading,
            albumLock: isAlbumLocked
        ) else { return }
        guard let remaining = remainingSound(of: current),
              remaining <= overlap + Self.blendLead
        else { return }

        armBlend(next, overlap: overlap)
    }

    /// What the planner needs to know about a track, filled in from the same
    /// caches the player itself reads.
    private func mixTrack(_ track: Track) -> MixTrack {
        MixTrack(
            album: track.album,
            trackNumber: track.trackNumber,
            duration: track.duration,
            sound: track.sound ?? soundResolver?(track),
            bpm: tempoResolver?(track)?.bpm,
            bpmStability: tempoResolver?(track)?.stability
        )
    }

    /// How much sound is left in the track playing now, measured to wherever the
    /// player will actually stop — the sound's end when it has been measured, and
    /// the file's end when it has not.
    private func remainingSound(of track: Track) -> Duration? {
        let end: Duration
        if let exit = programmedExit(for: track) {
            end = .seconds(exit / 1_000)
        } else if let sound = track.sound ?? soundResolver?(track) {
            end = sound.soundEnd
        } else if let duration {
            end = duration
        } else {
            return nil
        }
        return end > elapsed ? end - elapsed : .zero
    }

    /// Puts the incoming track on the spare deck, silent and ready, and takes it
    /// out of this deck's window so the outgoing track runs out of things to
    /// advance to.
    private func armBlend(_ slot: RenderSlot, overlap: Duration) {
        blend = Blend(entryId: slot.entryId, track: slot.track, overlap: overlap)
        syncPlayer()

        let item = makeItem(for: slot.track, entryId: slot.entryId)
        blend?.itemKey = ObjectIdentifier(item)
        spareDeck.removeAllItems()
        spareDeck.insert(item, after: nil)
        spareDeck.pause()
        applyLoudness(for: slot.track, on: spareDeck)

        prepareFadeIn(item, of: slot.track, overlap: overlap)
        log.info("Blending in \(slot.track.title, privacy: .public) over \(overlap.seconds, privacy: .public)s")
    }

    /// Attaches the incoming track's fade-in before it plays a note.
    ///
    /// Asynchronous because the fade has to be attached to the asset's own audio
    /// track, and for a streamed file that track is not known until some of the
    /// file has been read. That is the reason a blend is prepared seconds ahead
    /// rather than at the moment it is wanted.
    ///
    /// Only the incoming half is done this way. An `AVAudioMix` is sample-accurate
    /// and immune to a busy main thread, but AVFoundation only promises to honour
    /// one that was attached *before* the item played — which the outgoing track,
    /// by definition, already has. Its half is ridden down on the deck's fader
    /// instead; see ``startBlend()``.
    private func prepareFadeIn(_ item: AVPlayerItem, of track: Track, overlap: Duration) {
        let key = ObjectIdentifier(item)
        let seconds = overlap.seconds
        let start = (track.sound ?? soundResolver?(track))?.soundStart ?? .zero

        Task { @MainActor [weak self] in
            let mix = await Self.audioTrack(of: item).flatMap {
                MixRamp.fadeIn(track: $0, startingAt: start.cmTime, seconds: seconds)
            }
            guard let self, self.blend?.itemKey == key else { return }
            guard let mix else {
                self.log.warning("Couldn't build a fade-in; cutting instead")
                self.cancelBlend()
                return
            }
            item.audioMix = mix
            self.blend?.isFadeReady = true
        }
    }

    private static func audioTrack(of item: AVPlayerItem) async -> AVAssetTrack? {
        try? await item.asset.loadTracks(withMediaType: .audio).first
    }

    /// Lets the incoming track be heard, and starts taking the outgoing one down.
    ///
    /// The fade-out is driven by the outgoing deck's own clock rather than a
    /// timer: a clock that only advances when audio does cannot drift away from
    /// the music, and it keeps running with the screen off, which a display link
    /// does not. Twenty steps a second puts each step a small fraction of a
    /// decibel from the last, which is well under what anyone can hear.
    private func startBlend() {
        guard let current = blend, !current.isRunning, current.isFadeReady else { return }
        guard let fadeEnd = outgoingEnd(), fadeEnd.isFinite else { return }

        blend?.isRunning = true
        blend?.outgoingVolume = player.volume

        let base = player.volume
        let overlap = current.overlap.seconds
        let deck = player
        fadeObserver = deck.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.05, preferredTimescale: 600),
            queue: .main
        ) { time in
            let progress = (time.seconds - (fadeEnd - overlap)) / overlap
            deck.volume = base * Float(MixCurve.outgoing(progress: progress))
        }

        spareDeck.play()
    }

    /// Where the track playing now stops, in its own timeline.
    private func outgoingEnd() -> Double? {
        guard let track = queue.currentTrack else { return nil }
        if let sound = track.sound ?? soundResolver?(track) { return sound.soundEnd.seconds }
        return duration?.seconds
    }

    /// Takes the fade-out off whichever deck was carrying it and puts its fader
    /// back where levelling had it.
    private func endFadeOut(restoringVolumeOn deck: AVQueuePlayer) {
        guard let fadeObserver else { return }
        deck.removeTimeObserver(fadeObserver)
        self.fadeObserver = nil
        deck.volume = blend?.outgoingVolume ?? 1
    }

    /// The outgoing track has finished and its deck is empty. Hand over.
    ///
    /// Returns whether it did, so the ordinary "the queue ran out" path can carry
    /// on when there was no blend in flight.
    private func completeBlend() -> Bool {
        guard let running = blend, running.isRunning, let key = running.itemKey else { return false }

        stopReportingCurrent()

        // Retire the deck that just ran dry before it becomes the spare one.
        endFadeOut(restoringVolumeOn: player)
        player.pause()
        player.removeAllItems()
        for retired in enqueued { release(key: retired) }
        enqueued = [key]

        swapDecks()
        _ = queue.jump(to: running.entryId)

        blend = nil
        lastReportedSecond = -1
        elapsed = player.currentTime().validDuration ?? .zero
        duration = assetDurations[key]
            ?? player.currentItem?.duration.validDuration
            ?? running.track.duration
        state = player.rate > 0 ? .playing : .paused
        updateNowPlayingInfo()

        // Reported here rather than when the fade began: the listen is opened
        // once, at the moment this track becomes the one playing, so a blend does
        // not put two open plays in the history at the same time.
        reportedStartFor = running.track.id
        let reporter = reporter
        let track = running.track
        Task { await reporter?.playbackDidStart(track) }

        syncPlayer()
        return true
    }

    /// Moves the observations that watch "the player" onto the other deck.
    ///
    /// They are re-installed rather than kept on both, so nothing in this file
    /// has to ask which deck a callback came from.
    private func swapDecks() {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        currentItemObservation?.invalidate()
        currentItemObservation = nil
        rateObservation?.invalidate()
        rateObservation = nil

        playingDeckB.toggle()

        observeCurrentItem()
        observeRate()
        observePlayerTime()
    }

    /// Abandons whatever was prepared. Safe to call when nothing is.
    ///
    /// - Parameter resync: whether to put the incoming track back into this
    ///   deck's window. False only where the caller is about to rebuild it
    ///   anyway, or is tearing everything down — `syncPlayer` can decide the
    ///   queue has run out, and calling it from inside that decision would go
    ///   round in circles.
    private func cancelBlend(resync: Bool = true) {
        guard let cancelled = blend else { return }
        endFadeOut(restoringVolumeOn: player)
        blend = nil
        spareDeck.pause()
        spareDeck.removeAllItems()
        if let key = cancelled.itemKey { release(key: key) }
        if resync { syncPlayer() }
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
        // While the decks have the record, the player is either being faded out
        // of a hand-over or already empty. Either way its boundaries are not the
        // queue's, and acting on one would tear the decks down mid-record.
        guard !isUsingDecks else { return }

        guard let key, let entryId = entryForItem[key] else {
            // The queue drained on its own. Report the last track's stop before
            // tearing down — otherwise the final track of every queue never counts
            // as played on the server.
            if player.currentItem == nil, !enqueued.isEmpty {
                // A deck that runs dry mid-blend has not reached the end of the
                // queue; it has reached the end of its track, and the next one is
                // already playing on the other deck.
                if completeBlend() { return }
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

        applyLoudness(for: queue.currentTrack)

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
            reportedStartFor = track.id
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
            switch status {
            case .readyToPlay:
                if let assetDuration { assetDurations[key] = assetDuration }
            case .failed:
                log.warning("The track to blend in failed to load; cutting instead: \(error ?? "no reason given", privacy: .public)")
                cancelBlend()
            default:
                break
            }
            return
        }

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

        case .failed:
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
                if isLocal {
                    failedEntries.insert(entryId)
                } else {
                    coolingEntries.insert(entryId)
                }
                if let item = player.items().first(where: { ObjectIdentifier($0) == key }) {
                    player.remove(item)
                }
                enqueued.removeAll { $0 == key }
                release(key: key)
                syncPlayer()
                if !isLocal {
                    let delay = LoadRetryPolicy.delay(afterFailures: failures, whileQueued: true) ?? .seconds(16)
                    log.warning("Queued track failed to load (\(failures)), retrying in \(delay.seconds)s: \(message, privacy: .public)")
                    scheduleRetry(of: entryId, after: delay)
                }
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

        considerBlend()
        considerDeckTakeover()


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
            MPNowPlayingInfoPropertyPlaybackRate: isUsingDecks
                ? (state.isPlaying ? 1 : 0)
                : Double(player.rate),
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

        // An AVAudioEngine stops itself when the hardware underneath it changes —
        // a different output, a different sample rate — and does not start again
        // on its own. Nothing else in this file needs to know, because nothing
        // else is an engine; without it, plugging in headphones mid-mix is
        // silence until the next track.
        center.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.restartDecksAfterConfigurationChange()
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
            // Read before pausing, which clears it.
            wasPlayingWhenInterrupted = state.isPlaying || intendsToPlay
            pause()
            // The system tears the engine down under an interruption, so what is
            // resumed later has to be a *started* engine. Stopping it here makes
            // that explicit rather than leaving a graph that looks alive.
            if isUsingDecks { djMixer?.stop() }
        case .ended:
            // The session is ours again only once we say so; `resume()` does it
            // too, but the flag may say not to resume and the next deliberate tap
            // should still find a live session.
            activateSession()
            let systemSaysResume = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
                .contains(.shouldResume)
            let resuming = InterruptionPolicy.shouldResume(
                systemSaysResume: systemSaysResume,
                wasPlayingWhenInterrupted: wasPlayingWhenInterrupted
            )
            log.info("Interruption ended: system says resume=\(systemSaysResume, privacy: .public), was playing=\(self.wasPlayingWhenInterrupted, privacy: .public), resuming=\(resuming, privacy: .public)")
            wasPlayingWhenInterrupted = false
            if isUsingDecks {
                do {
                    try djMixer?.start()
                } catch {
                    // Silence is the one outcome worth avoiding: hand the record
                    // back to the player, which knows how to complain.
                    log.error("Couldn't restart the decks after an interruption: \(error.localizedDescription, privacy: .public)")
                    let wasPlaying = resuming
                    stopDecks()
                    if let track = queue.currentTrack { beginOnPlayer(track, autoplay: wasPlaying) }
                    return
                }
            }
            if resuming { resume() }
        @unknown default:
            break
        }
    }

    /// Puts the decks back together after the hardware changed underneath them.
    ///
    /// A record cannot be resumed exactly where it was through a restart, so it
    /// is restarted from where the session says it had reached — which is the
    /// same thing the listener would expect from a device they just plugged in.
    private func restartDecksAfterConfigurationChange() {
        guard isUsingDecks, let session = djSession, let mixer = djMixer else { return }
        let position = session.position(at: djClock())
        let wasPlaying = state.isPlaying
        log.info("The output changed under the decks; restarting at \(position, privacy: .public)s")
        do {
            mixer.stop()
            try mixer.start()
            try session.seek(to: position, at: djClock())
            if !wasPlaying { session.pause() }
        } catch {
            log.error("Couldn't restart the decks: \(error.localizedDescription, privacy: .public)")
            stopDecks()
            if let track = queue.currentTrack { beginOnPlayer(track, autoplay: wasPlaying) }
        }
    }

    /// Claims the audio session back.
    ///
    /// The category and mode are set once at launch and survive; this only says
    /// "this app wants the output again", which is the half a phone call takes
    /// away. A failure is logged rather than thrown: another app holding an
    /// exclusive session is a reason to stay quiet, not to crash a music player.
    private func activateSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            log.error("Could not reclaim the audio session: \(error.localizedDescription, privacy: .public)")
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
