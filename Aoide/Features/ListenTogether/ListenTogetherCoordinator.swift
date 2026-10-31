import CurationKit
import Foundation
import MeleteKit
import PlaybackKit
import os

/// Listening together through Melete: a session several devices play in step,
/// whatever they run, each streaming for itself. Not SharePlay, which needs a
/// FaceTime call and Apple devices on both ends.
///
/// **Following.** While in a session this asks for it every ``pollEvery`` — as
/// often as the server looks for changes itself — and moves the player to where
/// it says (``ListenPlan``): the same queue is jumped, sought, played or paused
/// within; another is loaded in its place.
///
/// **Leading.** The engine is observed, so every change by any route (the lock
/// screen, CarPlay, the end of a track) is seen. The player's state is sent,
/// against the version last seen, unless the player is already where the
/// session says. That rule is what stops a change from echoing: one that
/// arrived from the session leaves the player in step, so nothing goes back. A
/// change refused for an old version means someone else acted first: the
/// session is fetched and followed.
///
/// Infinity holds back while in a session: every device would add its own songs.
@MainActor
@Observable
final class ListenTogetherCoordinator {
    static let shared = ListenTogetherCoordinator()

    /// How often the session is asked about while in one.
    static let pollEvery: Duration = .seconds(2)

    private(set) var session: ListenSession?
    /// The code being typed, to join with.
    var code = ""
    private(set) var isBusy = false
    /// What went wrong last, in a sentence.
    private(set) var problem: String?

    var isInSession: Bool { session != nil }

    @ObservationIgnored private var client: MeleteClient?
    /// The server's clock minus this one's, in milliseconds.
    @ObservationIgnored private var offsetMs: Int64 = 0
    @ObservationIgnored private var isPushing = false
    /// The player changed again while a change was on its way: send again after.
    @ObservationIgnored private var isDirty = false
    /// The session's queue is being loaded: what the player does meanwhile is
    /// the session's doing, not a change to send.
    @ObservationIgnored private var isApplying = false
    @ObservationIgnored private var polling: Task<Void, Never>?
    @ObservationIgnored private var isObserving = false
    @ObservationIgnored private let log = Logger(subsystem: AppIdentity.bundle, category: "listen-together")

    private var engine: PlaybackEngine { .shared }

    /// Who to ask, from sign-in until sign-out. A new sign-in starts outside
    /// any session: the server drops a signed-out device from its sessions.
    func connect(client: MeleteClient?) {
        self.client = client
        polling?.cancel()
        polling = nil
        session = nil
        problem = nil
        isBusy = false
    }

    // MARK: - Asking

    func start() async {
        guard let client else { return }
        guard let state = local.state else {
            problem = "This queue has songs that aren't on the server."
            return
        }
        await ask { try await client.startListening(state) }
    }

    func join() async {
        guard let client else { return }
        let code = code.trimmingCharacters(in: .whitespaces)
        guard !code.isEmpty else { return }
        await ask { try await client.joinListening(code: code) }
        if isInSession { self.code = "" }
    }

    /// Leaves, or (`forEveryone`, for whoever started it) ends the session.
    func leave(forEveryone: Bool) async {
        guard let client, let id = session?.id else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            if forEveryone {
                try await client.endListening(id: id)
            } else {
                try await client.leaveListening(id: id)
            }
            stop()
        } catch MeleteError.notFound {
            stop()
        } catch {
            problem = Self.words(for: error)
        }
    }

    /// A start or a join, then following what it answered.
    private func ask(_ request: () async throws -> Listening) async {
        isBusy = true
        problem = nil
        defer { isBusy = false }
        do {
            let sent = Date().millis
            let listening = try await request()
            adopt(listening, sent: sent)
            await follow()
            beginPolling()
            observeEngine()
        } catch MeleteError.notFound {
            problem = "No session has that code."
        } catch {
            problem = Self.words(for: error)
        }
    }

    private func adopt(_ listening: Listening, sent: Int64) {
        let received = Date().millis
        offsetMs = listening.serverTime - (sent + (received - sent) / 2)
        session = listening.session
    }

    private var serverNow: Int64 { Date().millis + offsetMs }

    private func stop() {
        polling?.cancel()
        polling = nil
        session = nil
    }

    private static func words(for error: any Error) -> String {
        switch error {
        case MeleteError.http(status: 429, _, _):
            "Too many wrong codes. Try again in 15 minutes."
        case MeleteError.forbidden:
            "Listening together isn't open to you, as you can see only some music libraries."
        default:
            (error as? MeleteError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: - Following

    private func beginPolling() {
        guard polling == nil else { return }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollEvery)
                await self?.poll()
            }
        }
    }

    private func poll() async {
        guard let client, let id = session?.id, !isPushing, !isApplying else { return }
        do {
            let sent = Date().millis
            adopt(try await client.listening(id: id), sent: sent)
            await follow()
        } catch MeleteError.notFound {
            stop()
            problem = "Listening together has ended."
        } catch is CancellationError {
            return
        } catch {
            // Gone for a moment, most likely: the next poll asks again.
            log.error("Couldn't read the session: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Moves the player to where the session is now.
    private func follow() async {
        guard let session else { return }
        switch ListenPlan(session: session, local: local, serverNow: serverNow) {
        case .nothing:
            return
        case .adjust(let jump, let seek, let play):
            if let jump, engine.queue.entries.indices.contains(jump) {
                engine.jump(to: engine.queue.entries[jump].id)
            }
            if let seek { engine.seek(to: .milliseconds(seek)) }
            if play == true { engine.resume() }
            if play == false { engine.pause() }
        case .rebuild:
            await load(session)
        }
    }

    /// Loads the session's queue in place of this one, at its track and place.
    private func load(_ session: ListenSession) async {
        guard let client else { return }
        isApplying = true
        defer { isApplying = false }
        let ids = session.queue.map(String.init)
        guard let items = try? await client.items(ids: ids) else { return }
        let byId = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let ordered = ids.compactMap { byId[$0] }
        let mapped = MeletePlaybackBridge.playableTracks(from: ordered, client: client)
        guard !mapped.tracks.isEmpty else { return }
        let start = mapped.sourceIndices.firstIndex { $0 >= session.index } ?? 0
        // Left `.unknown`: somebody else chose this, as with SharePlay.
        PlaybackContext.attributing(.unknown) {
            engine.restore(mapped.tracks, startingAt: start, elapsed: .milliseconds(session.position(at: serverNow)))
        }
        if session.playing { engine.resume() }
    }

    // MARK: - Leading

    /// The player as it stands. Loading counts as playing: it's on its way.
    private var local: ListenLocal {
        let elapsedMs = Int64((engine.elapsed / .milliseconds(1)).rounded())
        return ListenLocal(
            ids: engine.queue.entries.map(\.track.id),
            index: engine.queue.position ?? 0,
            positionMs: max(0, elapsedMs),
            playing: engine.state == .playing || engine.state == .buffering
        )
    }

    /// Sees every change the engine makes, whatever made it.
    private func observeEngine() {
        guard !isObserving else { return }
        isObserving = true
        withObservationTracking {
            _ = engine.queue.entries.map(\.id)
            _ = engine.queue.position
            _ = engine.state
            _ = engine.elapsed
        } onChange: { [weak self] in
            // `onChange` fires before the new value is readable.
            Task { @MainActor in
                guard let self else { return }
                self.isObserving = false
                guard self.isInSession else { return }
                await self.share()
                self.observeEngine()
            }
        }
    }

    /// Sends the player's state, unless it's where the session says already.
    private func share() async {
        guard let client, let session, !isApplying else { return }
        let local = local
        guard ListenPlan(session: session, local: local, serverNow: serverNow) != .nothing else { return }
        guard !isPushing else {
            isDirty = true
            return
        }
        guard let state = local.state else { return }
        isPushing = true
        defer { isPushing = false }
        do {
            let sent = Date().millis
            adopt(try await client.changeListening(id: session.id, version: session.version, state: state), sent: sent)
        } catch let error as MeleteError where error.isStale {
            // Someone else acted first: theirs stands.
            isDirty = false
            isPushing = false
            await poll()
            return
        } catch MeleteError.notFound {
            stop()
            problem = "Listening together has ended."
            return
        } catch {
            log.error("Couldn't send the change: \(error.localizedDescription, privacy: .public)")
            return
        }
        if isDirty {
            isDirty = false
            isPushing = false
            await share()
        }
    }
}
