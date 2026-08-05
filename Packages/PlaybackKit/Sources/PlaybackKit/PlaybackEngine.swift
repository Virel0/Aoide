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

    public var repeatMode: RepeatMode {
        get { queue.repeatMode }
        set {
            queue.repeatMode = newValue
            updateNowPlayingInfo()
        }
    }

    public var isShuffled: Bool { queue.isShuffled }

    // MARK: - Collaborators

    public weak var reporter: (any PlaybackReporter)?
    public var artworkLoader: ArtworkLoader?

    // MARK: - Private

    private let log = Logger(subsystem: "com.example.jellymusic", category: "playback")
    private let player = AVPlayer()

    private var timeObserver: Any?
    private var itemEndObserver: (any NSObjectProtocol)?
    private var statusObservation: NSKeyValueObservation?
    private var bufferObservation: NSKeyValueObservation?

    /// The next track's item, built early so its asset starts loading before we
    /// need it. Not true gapless — that would need `AVQueuePlayer` and a second
    /// source of truth — but it removes the stall at a track boundary.
    private var preloadedNext: (trackId: String, item: AVPlayerItem)?

    /// Throttles progress reports to the server to roughly one every 10s.
    private var lastReportedSecond: Int = -1

    /// Pressing previous within this window goes to the previous track; after it,
    /// previous restarts the current one. Matches Apple Music.
    private let restartThreshold: Duration = .seconds(3)

    private init() {
        player.actionAtItemEnd = .pause
        player.automaticallyWaitsToMinimizeStalling = true
        observePlayerTime()
        configureRemoteCommands()
        observeAudioSessionEvents()
    }

    // MARK: - Loading

    /// Replaces the queue and starts playing.
    public func play(_ tracks: [Track], startingAt index: Int = 0, shuffled: Bool = false) {
        guard !tracks.isEmpty else { return }
        stopReportingCurrent()
        queue.load(tracks, startingAt: index, shuffled: shuffled)
        startCurrentTrack(autoplay: true)
    }

    public func playNext(_ tracks: [Track]) {
        queue.playNext(tracks)
        refreshPreload()
    }

    public func addToQueue(_ tracks: [Track]) {
        let wasEmpty = queue.isEmpty
        queue.append(tracks)
        if wasEmpty {
            startCurrentTrack(autoplay: true)
        } else {
            refreshPreload()
        }
    }

    public func clearQueue() {
        stopReportingCurrent()
        queue.clear()
        player.replaceCurrentItem(with: nil)
        preloadedNext = nil
        state = .idle
        elapsed = .zero
        duration = nil
        updateNowPlayingInfo()
    }

    // MARK: - Transport

    public func togglePlayPause() {
        switch state {
        case .playing: pause()
        case .paused, .idle: resume()
        case .buffering, .failed: resume()
        }
    }

    public func resume() {
        guard queue.current != nil else { return }
        if player.currentItem == nil {
            startCurrentTrack(autoplay: true)
            return
        }
        player.play()
        state = .playing
        updateNowPlayingInfo()
        report { await $0.playbackDidProgress($1, position: $2, isPaused: false) }
    }

    public func pause() {
        player.pause()
        state = .paused
        updateNowPlayingInfo()
        report { await $0.playbackDidProgress($1, position: $2, isPaused: true) }
    }

    public func next() {
        stopReportingCurrent()
        switch queue.skipToNext() {
        case .moved, .repeatCurrent:
            startCurrentTrack(autoplay: true)
        case .ended:
            finishPlayback()
        }
    }

    /// Previous restarts the current track unless we're still near its beginning.
    public func previous() {
        if elapsed > restartThreshold {
            seek(to: .zero)
            return
        }
        stopReportingCurrent()
        switch queue.skipToPrevious() {
        case .moved, .repeatCurrent:
            startCurrentTrack(autoplay: true)
        case .ended:
            seek(to: .zero)
        }
    }

    public func jump(to entryId: UUID) {
        guard queue.jump(to: entryId) else { return }
        stopReportingCurrent()
        startCurrentTrack(autoplay: true)
    }

    public func seek(to position: Duration) {
        let clamped = max(.zero, min(position, duration ?? position))
        player.seek(to: clamped.cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
        elapsed = clamped
        updateNowPlayingInfo()
        report { await $0.playbackDidProgress($1, position: $2, isPaused: !self.state.isPlaying) }
    }

    public func setShuffled(_ shuffled: Bool) {
        queue.setShuffled(shuffled)
        refreshPreload()
    }

    public func remove(entryId: UUID) {
        let wasCurrent = queue.current?.id == entryId
        queue.remove(entryId: entryId)
        if wasCurrent {
            if queue.current == nil { finishPlayback() } else { startCurrentTrack(autoplay: state.isPlaying) }
        } else {
            refreshPreload()
        }
    }

    public func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        queue.move(fromOffsets: source, toOffset: destination)
        refreshPreload()
    }

    // MARK: - Playing a track

    private func startCurrentTrack(autoplay: Bool) {
        guard let track = queue.currentTrack else {
            finishPlayback()
            return
        }

        let item: AVPlayerItem
        if let preloaded = preloadedNext, preloaded.trackId == track.id {
            item = preloaded.item
        } else {
            item = AVPlayerItem(url: track.streamURL)
        }
        preloadedNext = nil

        observe(item)
        player.replaceCurrentItem(with: item)

        elapsed = .zero
        duration = track.duration
        lastReportedSecond = -1
        state = autoplay ? .buffering : .paused

        if autoplay { player.play() }

        updateNowPlayingInfo()
        refreshPreload()

        let reporter = reporter
        Task { await reporter?.playbackDidStart(track) }
    }

    /// Called when the queue runs out.
    private func finishPlayback() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        preloadedNext = nil
        state = .idle
        elapsed = .zero
        updateNowPlayingInfo()
    }

    /// Builds the following track's item ahead of time so the handoff doesn't stall.
    private func refreshPreload() {
        guard let nextTrack = queue.upNext.first?.track else {
            preloadedNext = nil
            return
        }
        guard preloadedNext?.trackId != nextTrack.id else { return }
        preloadedNext = (nextTrack.id, AVPlayerItem(url: nextTrack.streamURL))
    }

    // MARK: - Observation

    private func observe(_ item: AVPlayerItem) {
        itemEndObserver.map(NotificationCenter.default.removeObserver)
        statusObservation?.invalidate()
        bufferObservation?.invalidate()

        itemEndObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleTrackEnded()
            }
        }

        // KVO fires on whichever thread mutated the property, and AVFoundation uses
        // its own queues — so `assumeIsolated` here would trap exactly the way the
        // artwork handler did. Read what's needed synchronously, then hop to the
        // main actor carrying only Sendable values.
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let status = item.status
            let assetDuration = item.duration.validDuration
            let errorMessage = item.error?.localizedDescription
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch status {
                case .readyToPlay:
                    if let assetDuration { self.duration = assetDuration }
                    if self.state == .buffering { self.state = .playing }
                    self.updateNowPlayingInfo()
                case .failed:
                    let message = errorMessage ?? "This track couldn't be played."
                    self.log.error("Playback failed: \(message, privacy: .public)")
                    self.state = .failed(message)
                default:
                    break
                }
            }
        }

        bufferObservation = item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { [weak self] item, _ in
            let likelyToKeepUp = item.isPlaybackLikelyToKeepUp
            Task { @MainActor [weak self] in
                guard let self, self.state != .idle else { return }
                if likelyToKeepUp, self.state == .buffering {
                    self.state = self.player.rate > 0 ? .playing : .paused
                }
            }
        }
    }

    private func handleTrackEnded() {
        stopReportingCurrent()
        switch queue.advanceAutomatically() {
        case .moved:
            startCurrentTrack(autoplay: true)
        case .repeatCurrent:
            seek(to: .zero)
            player.play()
            state = .playing
        case .ended:
            finishPlayback()
        }
    }

    private func observePlayerTime() {
        // Twice a second: fine enough for a smooth scrubber, coarse enough not to
        // spin the CPU while the screen is off.
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                self?.handleTimeUpdate(time)
            }
        }
    }

    private func handleTimeUpdate(_ time: CMTime) {
        guard let seconds = time.validDuration else { return }
        elapsed = seconds

        if state == .buffering, player.rate > 0 { state = .playing }

        // Report to the server about every 10 seconds rather than twice a second.
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
            return
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyAlbumTitle: track.album,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed.seconds,
            MPNowPlayingInfoPropertyPlaybackRate: state.isPlaying ? 1.0 : 0.0,
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
