// `AVAudioSession` and `UIImage` don't exist on macOS. The guard exists purely so
// the package still builds on the host for `swift test` — the queue logic in
// PlayQueue.swift is the part worth testing there, and it stays platform-free.
#if os(iOS)

import AVFoundation
import Foundation
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
///
/// ## Where the rest is
///
/// This file holds the engine's state, because Swift keeps stored properties in
/// the class body. What the engine does is in `PlaybackEngine+*.swift`, one
/// responsibility per file: loading the queue, transport, starting a track, the
/// render window, crossfade, Auto DJ, observing the player and its items, load
/// retries, reporting, Now Playing, remote commands, and the audio session.
@MainActor
@Observable
public final class PlaybackEngine {
    /// The one engine in the process, shared by the phone UI and CarPlay.
    public static let shared = PlaybackEngine()

    // MARK: - Observable state

    /// The queue as the listener sees it: what is playing and what comes next.
    public internal(set) var queue = PlayQueue()
    /// Whether something is playing, paused, loading, or has failed.
    public internal(set) var state: PlaybackState = .idle
    /// How far into the current track the player is, on the player's own clock.
    public internal(set) var elapsed: Duration = .zero
    /// The real duration once the asset loads, which can differ from the server's
    /// metadata — trust this one for the scrubber.
    public internal(set) var duration: Duration?

    /// Where the set will leave the record playing, when Auto DJ has
    /// programmed an exit before its end. ``duration`` stays the record's own
    /// length: a bar that stopped at sixty per cent read as a bar lying, and
    /// the lyrics and the scrubber are in the record's time, not the set's.
    public internal(set) var exitAt: Duration?

    /// The track the queue says is current, if any.
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
        // On the decks the player is idle and its clock says nothing; what is
        // heard is the session's position, read fresh for the same reason.
        if isUsingDecks, let session = djSession {
            let heard = session.heardPosition(at: djClock())
            return .seconds(max(0, heard - outputLatency - lyricsOffset.seconds))
        }
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
    var outputLatency: TimeInterval = 0

    /// How the queue repeats: not at all, the whole queue, or the current track.
    public var repeatMode: RepeatMode {
        get { queue.repeatMode }
        set {
            queue.repeatMode = newValue
            // Repeat mode changes what should be queued behind the current track.
            syncPlayer()
            updateNowPlayingInfo()
        }
    }

    /// Whether the queue is playing in shuffled order.
    public var isShuffled: Bool { queue.isShuffled }

    /// What Auto DJ or Crossfade is doing right now, for a screen to show.
    public internal(set) var mixState: MixState = .off

    /// The record on its way out while ``mixState`` is `.mixing`: the queue has
    /// already moved on to the one coming in, and a screen that wants to show
    /// the two crossing needs to know what the first one was.
    public internal(set) var outgoingTrack: Track?

    /// The last track given up on and why, for a screen to show. Cleared when a
    /// track next loads, so it describes the current trouble and not history.
    public internal(set) var lastFailure: PlaybackFailure?

    // MARK: - Settings

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

    /// Auto DJ: whether tracks that can be mixed are mixed.
    ///
    /// A different thing from ``isCrossfading`` and a stricter one. A crossfade
    /// applies to any pair; a mix needs both records on this device, both
    /// gridded by the server, both steady enough to lock to, and tempi close
    /// enough to bend one into the other. When any of that is missing — which is
    /// most of the time — the pair crossfades, and that is the design.
    public var isAutoDJing = false

    // MARK: - Collaborators

    /// Told when a listen starts, progresses, and stops.
    public weak var reporter: (any PlaybackReporter)?
    /// Fetches cover art for the lock screen and the car.
    public var artworkLoader: ArtworkLoader?

    /// Asked, at the moment an item is made, for bounds a track did not carry —
    /// the app's cache of what the server has measured, which may have arrived
    /// after the queue was built. Main-actor, synchronous: a lookup, never a fetch.
    public var soundResolver: ((Track) -> SilenceBounds?)?

    /// Makes the asset a stream plays from, when the app wants more than a plain
    /// `AVURLAsset` — a URL whose real address is asked for only when the player
    /// starts loading it, through a resource loader the app attaches. Main-actor,
    /// synchronous; nothing is fetched here.
    public var assetMaker: ((URL) -> AVURLAsset)?

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

    /// Where each line of a track's synced lyrics starts, in milliseconds,
    /// when the app has them. A cut is placed between lines rather than
    /// between two words of one; nothing else reads this.
    public var lyricLinesResolver: ((Track) -> [Double]?)?

    // MARK: - The decks

    let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "aoide", category: "playback")

    /// Two decks, like a DJ's, because one player cannot play two things at once
    /// and a crossfade is by definition two things at once.
    ///
    /// Only one of them is "the player" at any moment; ``player`` is that one, and
    /// every path in this engine that is not about mixing goes through it and
    /// cannot tell there is a second. The spare deck is silent and empty except
    /// during a blend, when it holds the incoming track and takes over as the
    /// outgoing one ends. See ``MixTransition``.
    ///
    /// Both are queue players, so an album run still hands over the way it always
    /// has — inside one deck, with `AVQueuePlayer`'s own seamless advance. The
    /// mixer is not allowed anywhere near a record that segues.
    private let deckA = AVQueuePlayer()
    private let deckB = AVQueuePlayer()
    var playingDeckB = false

    /// The deck the listener is hearing as the current track.
    var player: AVQueuePlayer { playingDeckB ? deckB : deckA }

    /// The deck a blend is prepared on.
    var spareDeck: AVQueuePlayer { playingDeckB ? deckA : deckB }

    // MARK: - The render window

    /// How many tracks to keep decoded behind the current one. Two is enough for a
    /// seamless boundary while keeping wasted prefetch small when someone is
    /// skipping around.
    let lookahead = 2

    /// What is currently loaded into the player, in order, identified by object
    /// identity. `enqueued[i]` corresponds to `player.items()[i]`.
    ///
    /// Object identity rather than the queue entry's id, because repeat-one loads
    /// the same entry as two distinct `AVPlayerItem`s and locating "the one that is
    /// playing now" has to distinguish them. Ordering is what makes the *diff*
    /// work: position `i` in both lists means "the i-th thing that will play", so
    /// comparing entry ids index-wise is exact.
    var enqueued: [ObjectIdentifier] = []

    /// Maps a live `AVPlayerItem` back to the queue entry it renders.
    var entryForItem: [ObjectIdentifier: UUID] = [:]

    /// Real decoded durations, which can differ from the server's metadata. Cached
    /// per item because a look-ahead item reaches `.readyToPlay` long before it
    /// becomes current, and `status` only transitions once.
    var assetDurations: [ObjectIdentifier: Duration] = [:]

    // MARK: - Load failures

    /// Entries given up on. Filtered out of the render window so a dead track
    /// doesn't get re-enqueued, fail, and be re-enqueued forever. Cleared whenever a
    /// new queue is loaded.
    var failedEntries: Set<UUID> = []

    /// Entries whose item failed and which are waiting out a retry delay. Filtered
    /// from the window like `failedEntries`, but only until their timer fires and
    /// puts them back — see ``LoadRetryPolicy``.
    var coolingEntries: Set<UUID> = []

    /// Consecutive load failures per entry, reset the moment one loads.
    var loadFailures: [UUID: Int] = [:]

    /// The pending retry per entry, so a deliberate action can cancel it.
    var retryTasks: [UUID: Task<Void, Never>] = [:]

    // MARK: - Auto DJ state

    /// The decks, made only if Auto DJ is ever turned on: an idle
    /// `AVAudioEngine` is a running audio graph, and there is no reason for one
    /// on a device whose owner never asked for this.
    var djSession: DJSession?
    var djMixer: DJMixer?
    /// Drives the automation and the queue while a mix is on the decks.
    var djTimer: Timer?
    /// The entry the decks are playing, which is how a queue change is noticed.
    var djEntryId: UUID?
    /// The entry a mix has been booked into, so the same one is not booked twice
    /// and a changed queue can cancel it.
    var djScheduledEntryId: UUID?
    /// The session's hand-over count when the current booking was made, so a
    /// hand-over that begins and ends between two ticks — a join — is still
    /// noticed by the count moving past it.
    var djHandOversAtBooking = 0
    /// The entry a failed booking was last logged for.
    var djUnbookable: UUID?
    /// When the automation last ran, so a stalled main thread can be named
    /// rather than guessed at.
    var djLastTick: Double?

    /// A record being moved from the player onto the decks mid-play. See
    /// ``DeckTakeover``.
    var takeover: DeckTakeover?

    /// The exit decided for each pair of records, by "outgoing>incoming".
    var exitDecisions: [String: Double] = [:]

    /// What is booked, if anything: how long and of what kind.
    var booked: HandOver?

    /// The booking that is now being heard, kept from the moment the queue
    /// moves on to the incoming record until the outgoing one has stopped.
    /// The booking itself is cleared then — the *next* hand-over is booked
    /// against the new record — and without this the screen would have
    /// nothing to draw for the whole of the mix.
    var mixing: HandOver?

    // MARK: - Crossfade state

    /// The blend being prepared or performed, if any.
    var blend: Blend?

    /// Watches the outgoing track's clock during a blend and rides its deck's
    /// fader down. Removed the moment the blend ends, either way.
    var fadeObserver: Any?

    // MARK: - Observation

    /// Per-item KVO, keyed so several simultaneously live items can each be
    /// observed. The previous single-observation design silently stopped watching
    /// the earlier item as soon as a second one existed.
    var itemObservations: [ObjectIdentifier: [NSKeyValueObservation]] = [:]

    var timeObserver: Any?
    var currentItemObservation: NSKeyValueObservation?
    var rateObservation: NSKeyValueObservation?

    // MARK: - Intent and reporting

    /// Throttles progress reports to the server to roughly one every 10s.
    var lastReportedSecond: Int = -1

    /// Whether music was playing when an interruption began. See ``InterruptionPolicy``.
    var wasPlayingWhenInterrupted = false

    /// The track whose start has already been reported, so a listen is opened
    /// once and only once. A queue put back from disk deliberately reports
    /// nothing until somebody actually presses play — see ``restore(_:startingAt:elapsed:)``.
    var reportedStartFor: String?

    /// What the user asked for, as distinct from what the player has managed yet.
    ///
    /// `AVPlayer.rate` is still 0 for a moment after `play()`, so deriving state
    /// from it when an item becomes ready latched `.paused` while audio was
    /// actually playing — and nothing corrected it afterwards, because the
    /// recovery paths only promote from `.buffering`. The car showed a play
    /// triangle and a frozen clock over music that was running.
    var intendsToPlay = false

    /// Pressing previous within this window goes to the previous track; after it,
    /// previous restarts the current one. Matches Apple Music.
    let restartThreshold: Duration = .seconds(3)

    /// The track whose cover is already on the lock screen, so a pause does not
    /// reload it.
    var lastArtworkTrackId: String?

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
}

#endif
