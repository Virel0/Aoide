import CurationKit
import Foundation
import JellyfinKit
import os

/// Decides *when* the sync engine runs, and holds the only account of what happened.
///
/// A singleton, connected and disconnected from `AppSession` alongside the playback
/// bridge, for the same reason that one is: CarPlay is a second live scene that can
/// come up before the phone UI has ever run, so anything owned by a view would not
/// exist yet. Nothing here travels through the environment, so no sheet boundary can
/// lose it.
///
/// What this deliberately is *not* is a timer. A clock wakes the radio on a schedule
/// that has nothing to do with whether anything happened, which on a phone is battery
/// spent for no listener-visible return. The three automatic moments below are the
/// ones where a sync can actually change something: a session appearing, the app
/// coming back, and local writes stopping.
@MainActor
@Observable
final class SyncCoordinator {
    static let shared = SyncCoordinator()

    /// Why a sync was asked for. Only the log reads it, and it earns its place there:
    /// the same failure means very different things depending on which of these
    /// produced it.
    enum Trigger: String {
        /// A session was established — restored from the keychain at launch, or a
        /// fresh login.
        case signedIn
        /// The app came back to the foreground. Whatever the other devices did while
        /// this one was asleep arrives here.
        case foreground
        /// Local writes stopped arriving. See `scheduleSettledSync`.
        case localChanges
        /// Somebody pressed the button.
        case manual
    }

    /// Why the last sync did not work. Never raised as an alert — a failed sync is
    /// not something the listener did, and there is nothing for them to fix.
    enum Failure: Equatable {
        case offline
        /// The server answered but has no sidecar. Different words are owed for this
        /// one: it is not "not right now", it is "not on this server".
        case unsupported
        case unavailable(String)

        var text: String {
            switch self {
            case .offline: "Offline"
            case .unsupported: "This server doesn't have Aoide sync"
            case .unavailable(let detail): detail
            }
        }
    }

    // MARK: - What a screen can see

    /// Ops written on this device that the server has not acknowledged.
    private(set) var pending = 0
    /// Ops that can never sync. Zero is the only good number — see `SettingsView`.
    private(set) var quarantined = 0
    private(set) var lastSuccess: Date?
    private(set) var lastReport: SyncReport?
    private(set) var failure: Failure?
    private(set) var isSyncing = false
    /// Live progress. A first sync on a device with years of history is many round
    /// trips, and a spinner that says nothing for two minutes reads as broken.
    private(set) var phase: SyncPhase = .idle

    /// Bumped whenever a sync wrote a row somebody might be looking at.
    ///
    /// Screens read the curation store into plain arrays and refill them from `.task`
    /// and pull-to-refresh, and neither of those fires when the app returns from the
    /// background — which is the exact moment a sync lands another device's changes.
    /// Without this, making a playlist on one device and foregrounding the other
    /// applies the row and leaves the list on screen showing the old set until the
    /// listener happens to pull down: the change is on disk and invisible.
    ///
    /// A counter rather than an observation on the tables themselves. GRDB can watch
    /// `playlist` and `playlistItem` directly and one day should, but that means every
    /// screen's model becoming a live query; this says the one thing they all need to
    /// hear — "something arrived, read again" — and it cannot fire for a device's own
    /// writes, which the screens already know about.
    private(set) var appliedRevision = 0

    /// False when nobody is signed in, or the store failed to open.
    var isAvailable: Bool { engine != nil }

    // MARK: - Innards

    private let log = Logger(subsystem: "com.example.aoide", category: "sync")

    private var engine: SyncEngine?
    private var store: CurationStore?
    private var runningSync: Task<Void, Never>?
    private var queueWatcher: Task<Void, Never>?
    private var settleTask: Task<Void, Never>?
    private var settleCeilingAt: ContinuousClock.Instant?
    private var earliestNextSync: ContinuousClock.Instant?
    private var consecutiveFailures = 0
    /// Distinguishes "the sync I started has finished" from "somebody disconnected and
    /// reconnected while it was in flight", which would otherwise let the returning
    /// task clear a handle that belongs to a newer sync.
    private var generation = 0

    /// How long local writes have to stop before a sync is worth starting.
    ///
    /// Long enough that dragging twenty tracks around a playlist is one sync rather
    /// than twenty; short enough that putting the phone down and picking up the other
    /// device finds the change already there.
    private static let quietWindow = Duration.seconds(6)

    /// The longest the quiet window may push a sync back.
    ///
    /// Required, not belt-and-braces: playback writes on its own schedule — the queue
    /// row is saved roughly every ten seconds while something plays — so during a long
    /// listen the quiet window never elapses, and without a ceiling a sync would never
    /// happen at all.
    private static let settleCeiling = Duration.seconds(90)

    /// The floor between two automatic syncs, doubling after each failure up to about
    /// ten minutes.
    ///
    /// Nothing fires when it expires; it only stops two triggers landing together from
    /// meaning two round trips, and stops a server that is up but broken from being
    /// asked again every few seconds for as long as music is playing. Pressing Sync Now
    /// ignores it — being ignored is what makes a button feel broken.
    private static let minimumInterval = Duration.seconds(20)

    private static let lastSuccessKey = "aoide.sync.lastSuccess"

    private init() {
        // Restored, because a launch-fresh "Never" would be a lie about a device that
        // has been syncing for months.
        lastSuccess = UserDefaults.standard.object(forKey: Self.lastSuccessKey) as? Date
    }

    // MARK: - Session lifecycle

    /// Wires the engine to a signed-in server and syncs once.
    func connect(client: JellyfinClient) {
        disconnect()

        // Absent when the store failed to open. Never force-unwrapped: music plays
        // without it, and so does everything else — there is simply nothing to sync.
        guard let store = CurationDatabase.shared else {
            log.error("No curation store; sync is unavailable this launch.")
            return
        }

        self.store = store
        // One value in both roles: ops and cover bytes go to the same sidecar with
        // the same credentials, and two would be two things to keep in step.
        let transport = JellyfinSyncTransport(client: client)
        engine = SyncEngine(
            store: store,
            transport: transport,
            images: transport,
            imageBytes: PlaylistImageStore.shared,
            onPhaseChange: Self.publishPhase
        )
        watchQueueDepth(store)
        refreshCounts()
        syncSoon(.signedIn)
    }

    /// Stops syncing, without touching what is on disk.
    ///
    /// Nothing is erased here, on purpose. Signing out and back in as the same person
    /// is the ordinary case — an expired token does it unasked — and this store is the
    /// only copy of anything not yet pushed. What is account-scoped is erased on the
    /// way *in* instead, and only once the account has actually changed; see
    /// `CurationStore.adoptAccount`.
    ///
    /// The in-flight sync is cancelled rather than awaited. Signing out must not wait
    /// on the network, and cancelling a push is safe by construction: an op the server
    /// accepted but which was cancelled before `markSynced` ran is still pending
    /// locally, so the next sync sends it again and the server accepts and ignores it.
    func disconnect() {
        generation &+= 1
        runningSync?.cancel()
        queueWatcher?.cancel()
        settleTask?.cancel()
        runningSync = nil
        queueWatcher = nil
        settleTask = nil
        settleCeilingAt = nil
        earliestNextSync = nil
        consecutiveFailures = 0
        engine = nil
        store = nil
        isSyncing = false
        phase = .idle
        pending = 0
        quarantined = 0
        failure = nil
    }

    /// Forgets everything the last account's syncs left behind. Called when the store
    /// is handed to a different user.
    ///
    /// The published copies go with the stored one. `disconnect()` deliberately keeps
    /// them — signing out and back in as the same person should not lose the history —
    /// so without this the *running* process still shows "Last Sync: 2 minutes ago" and
    /// "applied 12" to somebody who has just had the store erased under them and has
    /// never synced on this device. Removing the `UserDefaults` key alone only fixed it
    /// at the next launch, which is not when anybody looks.
    func forgetAccountStatus() {
        UserDefaults.standard.removeObject(forKey: Self.lastSuccessKey)
        lastSuccess = nil
        lastReport = nil
    }

    // MARK: - Triggers

    /// Asks for a sync. Returns immediately, and reports whether one actually started.
    @discardableResult
    func syncSoon(_ trigger: Trigger) -> Bool {
        guard engine != nil else { return false }
        guard runningSync == nil else { return false }
        if trigger != .manual, let earliest = earliestNextSync, .now < earliest { return false }

        generation &+= 1
        let started = generation
        runningSync = Task { [weak self] in
            await self?.run(trigger)
            // Only clear the handle if it is still ours. A disconnect-and-reconnect
            // during a cancelled sync would otherwise let this task release a slot
            // that now belongs to a newer one, and two syncs would overlap.
            guard let self, self.generation == started else { return }
            self.runningSync = nil
        }
        return true
    }

    /// The Sync Now button.
    func syncNow() { syncSoon(.manual) }

    /// Fetches cover bytes this device does not have.
    ///
    /// Deliberately not part of a sync. A device joining an account would otherwise
    /// download every cover in the library before it finished syncing, most of which
    /// it will never draw — so these are pulled when something is about to show one.
    func fetchImage(hash: String) async -> Data? {
        guard let client = AppSession.shared.client else { return nil }
        return try? await JellyfinSyncTransport(client: client).downloadImage(sha256: hash)
    }

    /// Watches the outbound queue and syncs once writing has stopped.
    ///
    /// The trigger is the queue table itself rather than a call from each writer.
    /// There are a dozen places that record an op and a thirteenth will be written
    /// eventually; one that forgot to announce itself would be a change that never
    /// syncs, with nothing to notice it by.
    private func watchQueueDepth(_ store: CurationStore) {
        queueWatcher = Task { [weak self] in
            for await count in store.pendingOpCounts() {
                guard let self else { return }
                let grew = count > self.pending
                self.pending = count
                // Growth only. The queue also shrinks — that is a sync acknowledging
                // its own work — and reacting to that would be a loop.
                if grew { self.scheduleSettledSync() }
            }
        }
    }

    /// Restarts the quiet window, without letting it slide past the ceiling.
    private func scheduleSettledSync() {
        let ceiling = settleCeilingAt ?? ContinuousClock.now.advanced(by: Self.settleCeiling)
        settleCeilingAt = ceiling
        arm(at: min(ContinuousClock.now.advanced(by: Self.quietWindow), ceiling))
    }

    private func arm(at wake: ContinuousClock.Instant) {
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(until: wake, clock: .continuous)
            guard !Task.isCancelled, let self else { return }
            self.settleTask = nil
            self.settleCeilingAt = nil
            if self.syncSoon(.localChanges) { return }

            // Refused, for one of two reasons, and both have to arm again or the work
            // sits here unsent.
            //
            // A sync already in flight looked like it needed nothing from us, on the
            // grounds that anything written since would have bumped the queue depth and
            // re-armed. It does not: the growth that armed *this* task is that same
            // write, the watcher only reacts to the depth *increasing*, and applying
            // inbound ops never touches the `op` table — so nothing arms a second time.
            // A rename made a second into a thirty-second first sync then waits for the
            // next foreground, or for some unrelated write, before it goes anywhere.
            //
            // The interval floor is the other: the work is queued and nothing else is
            // coming, so wait exactly as long as the floor has left rather than polling
            // at it.
            guard self.pending > 0 else { return }
            if self.runningSync != nil {
                self.arm(at: ContinuousClock.now.advanced(by: Self.quietWindow))
            } else if let earliest = self.earliestNextSync, ContinuousClock.now < earliest {
                self.arm(at: earliest)
            }
        }
    }

    // MARK: - Running one

    private func run(_ trigger: Trigger) async {
        guard let engine else { return }

        // `isOnline` is nil until the monitor's first answer, and nil is not "no" — at
        // launch the honest thing is to try. Only a definite offline skips.
        //
        // It still takes the floor, even though skipping costs nothing: a phone on a
        // plane goes on writing a queue row every ten seconds, and without this each
        // one would walk the whole trigger path to reach the same answer. It does not
        // count towards the *backoff* though — there was no failure to back off from.
        if Reachability.shared.isOnline == false {
            failure = .offline
            earliestNextSync = ContinuousClock.now.advanced(by: backoffInterval)
            log.debug("Sync (\(trigger.rawValue, privacy: .public)) skipped: offline.")
            return
        }

        isSyncing = true
        defer {
            isSyncing = false
            phase = .idle
            earliestNextSync = ContinuousClock.now.advanced(by: backoffInterval)
            refreshCounts()
        }

        do {
            let report = try await engine.sync()
            lastSuccess = Date()
            lastReport = report
            failure = nil
            consecutiveFailures = 0
            if report.applied > 0 || report.supersededLikes > 0 { appliedRevision &+= 1 }
            UserDefaults.standard.set(lastSuccess, forKey: Self.lastSuccessKey)
            log.info("""
                Sync (\(trigger.rawValue, privacy: .public)) ok: \
                pushed \(report.pushed, privacy: .public), \
                pulled \(report.pulled, privacy: .public), \
                applied \(report.applied, privacy: .public), \
                quarantined \(report.quarantined, privacy: .public), \
                unreadable \(report.unreadable, privacy: .public)
                """)
        } catch is CancellationError {
            // Signing out, or the app going away. Not a failure, and not worth a word.
        } catch SyncError.alreadyRunning {
            // Two triggers landed together. The first one is doing the work.
        } catch {
            // Everything else leaves its ops pending and is tried again at the next
            // trigger. Nothing is surfaced beyond Settings: there is no action for the
            // listener to take, and an alert over the top of playing music would be
            // the worst imaginable reply to "your phone briefly lost wifi".
            consecutiveFailures += 1
            failure = Self.describe(error)
            log.error("Sync (\(trigger.rawValue, privacy: .public)) failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Doubles per consecutive failure, capping at about ten minutes.
    private var backoffInterval: Duration {
        Self.minimumInterval * Double(1 << min(consecutiveFailures, 5))
    }

    private static func describe(_ error: any Error) -> Failure {
        if JellyfinClient.isSidecarAbsent(error) { return .unsupported }

        if let jellyfin = error as? JellyfinError {
            // Deliberately does *not* sign the session out on a 401, unlike the library
            // screens. Those run because somebody is looking at them, so a rejected
            // token explains a screen that is visibly broken. This runs unasked, and
            // throwing a listener back to a login form because a background request
            // failed would be an ejection with no cause they can see.
            if jellyfin == .unauthorized || jellyfin == .forbidden {
                return .unavailable("Your login was refused. Sign out and back in.")
            }
            return .unavailable(jellyfin.errorDescription ?? "Couldn't reach the server")
        }
        if case SyncError.pushStalled(let count, let accepted, let rejected, let unmatched) = error {
            // The bare count is true and useless: it describes this device's
            // predicament and says nothing about the cause. These three separate the
            // cases that look identical from here — a server acknowledging nothing, a
            // server rejecting in a shape this build cannot read, and a server naming
            // ops it was never sent.
            let plural = count == 1 ? "" : "s"
            if accepted == 0, rejected == 0, unmatched == 0 {
                return .unavailable(
                    "Stuck sending \(count) change\(plural) — your server accepted and refused none of them."
                )
            }
            if unmatched > 0 {
                return .unavailable(
                    "Stuck sending \(count) change\(plural) — your server refused \(unmatched) it wasn't sent."
                )
            }
            return .unavailable(
                "Stuck sending \(count) change\(plural) — \(accepted) accepted, \(rejected) refused."
            )
        }
        // A reachable server answering 200 with something this build can't read. It
        // used to fall through to "Couldn't reach the server", which sends whoever is
        // looking to check their wifi over a fault in the reply — and push keeps
        // working throughout, so the device diverges in one direction while appearing
        // to have a flaky connection.
        if error is DecodingError {
            return .unavailable("The server's reply couldn't be read")
        }
        return .unavailable("Couldn't reach the server")
    }

    /// Re-reads the counts. For screens that change them without syncing — discarding
    /// a quarantined op is the only one.
    func refreshStatus() { refreshCounts() }

    /// Both are cheap indexed counts, and both can only fail if the database has gone
    /// away underneath us — in which case the numbers already on screen are as good a
    /// guess as any, and there is nothing anyone could do about it.
    ///
    /// Off the main actor even so, because cheap is not the same as quick here: the
    /// store is a serial `DatabaseQueue`, and `apply` holds it for a whole pulled batch
    /// — up to 500 ops of decode, merge and save in one transaction. A count queued
    /// behind that waits for all of it, and the first sync on a device with years of
    /// history runs those back to back. Settings opening mid-sync is exactly when
    /// somebody looks.
    private func refreshCounts() {
        guard let store else { return }
        Task { [weak self] in
            let counts = await Task.detached {
                (try? store.pendingOpCount(), try? store.quarantineCount())
            }.value
            // The session may have changed while that was queued; these numbers belong
            // to the store they were read from, not to whichever one is current.
            guard let self, self.store === store else { return }
            if let pending = counts.0 { self.pending = pending }
            if let quarantined = counts.1 { self.quarantined = quarantined }
        }
    }

    /// Built at type scope so that it captures nothing. The engine is an actor and
    /// calls this from its own executor, so the closure has to be safe to form off the
    /// main actor and hop explicitly — reaching the singleton inside the hop is what
    /// keeps it capture-free.
    private static let publishPhase: @Sendable (SyncPhase) -> Void = { phase in
        Task { @MainActor in
            guard SyncCoordinator.shared.isSyncing else { return }
            SyncCoordinator.shared.phase = phase
        }
    }
}

// MARK: - Words for a screen

extension SyncCoordinator {
    /// What goes next to "Last Sync".
    ///
    /// Relative rather than absolute: the question anyone is actually asking is "is
    /// this current", and "2 minutes ago" answers it without arithmetic.
    var lastSuccessSummary: String {
        guard let lastSuccess else { return "Never" }
        return lastSuccess.formatted(.relative(presentation: .named))
    }

    var pendingSummary: String {
        pending == 0 ? "Nothing" : "\(pending) change\(pending == 1 ? "" : "s")"
    }

    /// The line under the section. Changes with the situation rather than repeating a
    /// fixed sentence nobody reads twice.
    var statusDetail: String? {
        if isSyncing {
            switch phase {
            case .pushing(let pushed): return "Sending \(pushed)…"
            case .pulling(let applied): return "Receiving \(applied)…"
            default: return "Syncing…"
            }
        }
        if let failure { return failure.text }
        guard let report = lastReport, !report.isEmpty else { return nil }
        var parts: [String] = []
        if report.pushed > 0 { parts.append("sent \(report.pushed)") }
        if report.applied > 0 { parts.append("applied \(report.applied)") }
        // Said out loud because these leave no trace anywhere else: an op this build
        // cannot even read as an op has no id to file under, so it is skipped rather
        // than quarantined and the "Not Syncing" screen will never mention it.
        if report.unreadable > 0 { parts.append("couldn't read \(report.unreadable)") }
        guard !parts.isEmpty else { return nil }
        return "Last time: " + parts.joined(separator: ", ") + "."
    }
}
