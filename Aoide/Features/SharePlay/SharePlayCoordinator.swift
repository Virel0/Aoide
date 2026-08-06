import AVFoundation
import Combine
import Foundation
import GroupActivities
import JellyfinKit
import PlaybackKit
import os

/// Runs a shared listening session.
///
/// Two separate channels, because they answer different questions. `AVPlayer`'s own
/// playback coordinator keeps play, pause and position in step — Apple's, because
/// getting drift right across a network is not something to reimplement. *Which*
/// track everyone is on travels over a `GroupSessionMessenger` instead, since the
/// coordinator syncs the item that's playing but has no idea how to pick the next
/// one out of somebody else's library.
@MainActor
@Observable
final class SharePlayCoordinator {
    static let shared = SharePlayCoordinator()

    /// Whether a FaceTime call is up to start this from. SharePlay has no meaning
    /// outside one, so the button is hidden rather than shown failing.
    private(set) var isEligible = false
    private(set) var isActive = false
    private(set) var participantCount = 0

    private let log = Logger(subsystem: "com.example.aoide", category: "shareplay")
    private let stateObserver = GroupStateObserver()

    private var session: GroupSession<ListeningActivity>?
    private var messenger: GroupSessionMessenger?
    private var cancellables: Set<AnyCancellable> = []
    private var tasks: Set<Task<Void, Never>> = []
    private var client: JellyfinClient?

    /// Suppresses the echo when applying a queue that arrived from someone else —
    /// otherwise adopting their track broadcasts it straight back and the two
    /// devices bounce the same message between them.
    private var isApplyingRemoteQueue = false

    private init() {
        isEligible = stateObserver.isEligibleForGroupSession
        stateObserver.$isEligibleForGroupSession
            .receive(on: DispatchQueue.main)
            .sink { [weak self] eligible in self?.isEligible = eligible }
            .store(in: &cancellables)
    }

    func connect(client: JellyfinClient) {
        self.client = client
    }

    /// Listens for sessions the other side started, so joining needs no button.
    func listenForSessions() {
        let task = Task { [weak self] in
            for await session in ListeningActivity.sessions() {
                await self?.join(session)
            }
        }
        tasks.insert(task)
    }

    // MARK: - Starting

    func start() async {
        guard let track = PlaybackEngine.shared.currentTrack else { return }
        let activity = ListeningActivity(albumTitle: track.album, artist: track.artist)
        switch await activity.prepareForActivation() {
        case .activationPreferred:
            _ = try? await activity.activate()
        case .activationDisabled, .cancelled:
            // Chosen "just for me", or dismissed. Playback carries on locally;
            // there is nothing to report.
            return
        @unknown default:
            return
        }
    }

    func leave() {
        session?.leave()
        teardown()
    }

    // MARK: - Session lifecycle

    private func join(_ session: GroupSession<ListeningActivity>) {
        teardown()
        self.session = session
        let messenger = GroupSessionMessenger(session: session)
        self.messenger = messenger

        session.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                if case .invalidated = state { self?.teardown() }
            }
            .store(in: &cancellables)

        session.$activeParticipants
            .receive(on: DispatchQueue.main)
            .sink { [weak self] participants in self?.participantCount = participants.count }
            .store(in: &cancellables)

        // Hand the player to the session: play, pause and seek now travel on their
        // own, in both directions.
        PlaybackEngine.shared.playbackCoordinator.coordinateWithSession(session)

        let task = Task { [weak self] in
            for await (message, _) in messenger.messages(of: QueueMessage.self) {
                await self?.apply(message)
            }
        }
        tasks.insert(task)

        session.join()
        isActive = true

        // Whoever starts already has something playing; sending it immediately means
        // a joiner hears it rather than waiting for the next track change.
        broadcastCurrentQueue()
        observeLocalTrackChanges()
    }

    /// Broadcasts whenever this device changes track by any route.
    ///
    /// Hooking the play call sites instead would miss the ones that matter most —
    /// a skip from the lock screen, from CarPlay, or the queue advancing on its own
    /// at the end of a song. Observing the engine catches all of them, because the
    /// engine is the one thing they all go through.
    private func observeLocalTrackChanges() {
        withObservationTracking {
            _ = PlaybackEngine.shared.queue.current?.id
        } onChange: { [weak self] in
            // `onChange` fires *before* the new value is readable, so the work has to
            // happen after this returns.
            Task { @MainActor in
                guard let self, self.isActive else { return }
                self.broadcastCurrentQueue()
                self.observeLocalTrackChanges()
            }
        }
    }

    private func teardown() {
        for task in tasks { task.cancel() }
        tasks.removeAll()
        cancellables.removeAll()
        messenger = nil
        session = nil
        isActive = false
        participantCount = 0

        // Re-subscribe: the eligibility stream is not session-scoped, and dropping
        // it here would leave the SharePlay button permanently hidden after one call.
        stateObserver.$isEligibleForGroupSession
            .receive(on: DispatchQueue.main)
            .sink { [weak self] eligible in self?.isEligible = eligible }
            .store(in: &cancellables)
    }

    // MARK: - Queue exchange

    /// Tells the others what this device is playing.
    func broadcastCurrentQueue() {
        guard isActive, !isApplyingRemoteQueue, let messenger else { return }
        let entries = PlaybackEngine.shared.queue.entries
        guard !entries.isEmpty else { return }
        let index = entries.firstIndex { $0.id == PlaybackEngine.shared.queue.current?.id } ?? 0
        let message = QueueMessage(trackIds: entries.map(\.track.id), startIndex: index)
        Task { try? await messenger.send(message) }
    }

    private func apply(_ message: QueueMessage) async {
        guard let client else { return }

        // Resolved against *this* participant's own server session, so the stream
        // URLs carry their token rather than the sender's.
        var tracks: [JellyfinItem] = []
        for id in message.trackIds {
            guard let item = try? await client.item(id: id) else { continue }
            tracks.append(item)
        }
        guard !tracks.isEmpty else { return }

        // Built through the bridge so unplayable rows are dropped by the same rule
        // as everywhere else — and so the index still addresses the right track
        // after they are.
        let (playable, sourceIndices) = JellyfinPlaybackBridge.playableTracks(from: tracks, client: client)
        guard !playable.isEmpty else { return }
        let start = sourceIndices.firstIndex { $0 >= message.startIndex } ?? 0

        isApplyingRemoteQueue = true
        defer { isApplyingRemoteQueue = false }
        PlaybackEngine.shared.play(playable, startingAt: start)
    }
}
