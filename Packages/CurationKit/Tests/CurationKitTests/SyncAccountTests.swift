import Foundation
import GRDB
import Testing
@testable import CurationKit

@Suite("Account ownership and queue depth")
struct SyncAccountTests {
    private func stocked(_ store: CurationStore) throws {
        let list = try store.createPlaylist(name: "Late Night")
        try store.addTracks([TrackLink(jellyfinId: "t0", contentKey: "k0")], to: list.id)
        try store.record(Like(jellyfinId: "t0", contentKey: "k0", liked: true, updatedAt: 1, originDevice: "phone"))
        try store.append(PlayEvent(jellyfinId: "t0", contentKey: "k0", startedAt: 1, originDevice: "phone"))
        try store.saveQueue(deviceName: "iPhone", trackIds: ["t0"], position: 0, elapsedMs: 0)
    }

    // MARK: - Queue depth

    @Test("the pending count matches the pending rows")
    func countMatchesRows() throws {
        let store = try CurationStore.inMemory(deviceId: "phone")
        #expect(try store.pendingOpCount() == 0)
        try stocked(store)
        let rows = try store.pendingOps(limit: 1_000).count
        #expect(try store.pendingOpCount() == rows)
    }

    @Test("acknowledged ops stop being counted")
    func acknowledgedStopCounting() throws {
        let store = try CurationStore.inMemory(deviceId: "phone")
        try stocked(store)
        try store.markSynced(try store.pendingOps(limit: 1_000).map(\.opId))
        #expect(try store.pendingOpCount() == 0)
    }

    /// The trigger for "local changes settled" hangs off this stream, so a write that
    /// does not wake it is a change that sits in the queue until something else
    /// happens to sync.
    @Test("the stream reports the queue growing")
    func streamObservesWrites() async throws {
        let store = try CurationStore.inMemory(deviceId: "phone")
        var counts = store.pendingOpCounts().makeAsyncIterator()

        #expect(await counts.next() == 0)
        try store.createPlaylist(name: "Focus")

        // The observation coalesces, so the next value is whatever the queue holds by
        // the time it is delivered — the assertion is that it noticed, not how many
        // notifications it sent.
        var seen = await counts.next() ?? 0
        while seen == 0 { seen = await counts.next() ?? 0 }
        #expect(seen >= 1)
    }

    // MARK: - Account ownership

    /// This used to adopt silently, which handed the previous person's playlists and
    /// history to whoever signed in next. It now asks, and the data is untouched
    /// either way until it is answered — so nothing is lost by the question itself.
    @Test("an unclaimed store with data asks, and touches nothing until answered")
    func firstClaimKeepsEverything() throws {
        let store = try CurationStore.inMemory(deviceId: "phone")
        try stocked(store)
        let pending = try store.pendingOpCount()

        #expect(try store.adoptAccount("user-a") == .unknownOwner)
        #expect(try store.accountId() == nil)
        #expect(try store.pendingOpCount() == pending)

        try store.keepAndClaim(accountId: "user-a")
        #expect(try store.accountId() == "user-a")
        #expect(try store.pendingOpCount() == pending)
    }

    /// Signing out and back in as the same person is the ordinary case, and the store
    /// is the only copy of anything not yet pushed.
    @Test("re-adopting the same account keeps unpushed work")
    func sameAccountKeepsPendingWork() throws {
        let store = try CurationStore.inMemory(deviceId: "phone")
        try store.adoptAccount("user-a")
        try stocked(store)
        let pending = try store.pendingOpCount()

        #expect(try store.adoptAccount("user-a") == .unchanged)
        #expect(try store.pendingOpCount() == pending)
        #expect(try store.read { try Playlist.fetchCount($0) } == 1)
    }

    @Test("a different account erases everything it inherited")
    func differentAccountErases() throws {
        let store = try CurationStore.inMemory(deviceId: "phone")
        try store.adoptAccount("user-a")
        try stocked(store)
        try store.quarantine(
            Op(entity: "playlist", entityId: "x", operation: .upsert, payload: "{}", createdAt: 1),
            reason: .deleteWithoutFlag,
            at: 1
        )

        #expect(try store.adoptAccount("user-b") == .erased)
        #expect(try store.accountId() == "user-b")
        #expect(try store.pendingOpCount() == 0)
        #expect(try store.quarantineCount() == 0)
        let remaining = try store.read { db in
            [
                try Playlist.fetchCount(db),
                try PlaylistItem.fetchCount(db),
                try Like.fetchCount(db),
                try PlayEvent.fetchCount(db),
                try QueueState.fetchCount(db),
                try TrackRef.fetchCount(db),
            ]
        }
        #expect(remaining == [0, 0, 0, 0, 0, 0])
    }

    /// The sharpest edge of the lot: sequences are scoped per user, so a cursor of
    /// 4000 carried into a second account skips that account's first four thousand
    /// ops and nothing ever offers them again.
    @Test("a different account forgets the pull cursor")
    func differentAccountForgetsCursor() throws {
        let store = try CurationStore.inMemory(deviceId: "phone")
        try store.adoptAccount("user-a")
        try store.setSyncCursor("4000")

        try store.adoptAccount("user-b")
        #expect(try store.pullCursor() == nil)
    }

    /// The mark and the rows it vouches for have to go together. Erasing `track` while
    /// leaving `trackIndexCompletedAt` behind means `indexIfNeeded` reads the mark,
    /// concludes the library has already been walked and never runs again — so every
    /// smart playlist evaluates against an empty universe and says the rules have no
    /// hits, which is the one thing that mark exists to rule out. Nothing in the app can
    /// recover it.
    @Test("a different account forgets that the library was ever indexed")
    func differentAccountForgetsTheIndexMark() throws {
        let store = try CurationStore.inMemory(deviceId: "phone")
        try store.adoptAccount("user-a")
        try stocked(store)
        try store.recordLibraryIndex(at: 5_000)
        #expect(try store.libraryIndexedAt() == 5_000)

        try store.adoptAccount("user-b")
        #expect(try store.libraryIndexedAt() == nil)
        #expect(try store.read { try TrackRef.fetchCount($0) } == 0)
    }

    @Test("the same account keeps its place in the log")
    func sameAccountKeepsCursor() throws {
        let store = try CurationStore.inMemory(deviceId: "phone")
        try store.adoptAccount("user-a")
        try store.setSyncCursor("4000")

        try store.adoptAccount("user-a")
        #expect(try store.pullCursor() == PullCursor(4000))
    }
}

/// A store written before account claims existed carries no owner, and guessing is
/// wrong in both directions — adopting hands one person's library to the next signer,
/// erasing destroys the library of somebody who merely signed out and back in.
@Suite("Unclaimed stores")
struct UnclaimedStoreTests {
    private func store() throws -> CurationStore { try .inMemory(deviceId: "phone") }

    private func seed(_ store: CurationStore) throws {
        _ = try store.createPlaylist(name: "From Before")
    }

    @Test("an unclaimed store holding data asks rather than guessing")
    func asks() throws {
        let store = try store()
        try seed(store)
        #expect(try store.adoptAccount("user-a") == .unknownOwner)
        // Still unclaimed: claiming and then asking would let a sync push one
        // person's library into another person's log before they could say no.
        #expect(try store.accountId() == nil)
    }

    /// Nobody's data means no question, so a fresh install claims in silence.
    @Test("an unclaimed but empty store is claimed without asking")
    func emptyStoreIsSilent() throws {
        let store = try store()
        #expect(try store.adoptAccount("user-a") == .unchanged)
        #expect(try store.accountId() == "user-a")
    }

    @Test("keeping claims the store and leaves the data alone")
    func keeping() throws {
        let store = try store()
        try seed(store)
        _ = try store.adoptAccount("user-a")

        try store.keepAndClaim(accountId: "user-a")

        #expect(try store.accountId() == "user-a")
        #expect(try store.playlists().count == 1)
        // The op from before the claim still has to reach the server — it is this
        // person's work, and discarding it would lose whatever was never pushed.
        #expect(try store.pendingOps().isEmpty == false)
    }

    @Test("starting fresh erases everything, including the pending ops")
    func startingFresh() throws {
        let store = try store()
        try seed(store)
        _ = try store.adoptAccount("user-a")

        try store.eraseAndClaim(accountId: "user-a")

        #expect(try store.accountId() == "user-a")
        #expect(try store.playlists().isEmpty)
        // The sharp edge: unpushed ops belonging to the previous person would
        // otherwise be pushed into this account's log on the very first sync.
        #expect(try store.pendingOps().isEmpty)
    }

    /// A track cache is a rebuildable copy of what Jellyfin already knows and says
    /// nothing about anyone's listening, so it is not evidence worth interrupting for.
    @Test("a store holding only a track cache is not worth asking about")
    func trackCacheAloneIsNotData() throws {
        let store = try store()
        try store.writeLocal { db in
            try TrackRef(
                jellyfinId: "t1",
                contentKey: "k",
                title: "Song",
                artist: "Artist",
                album: "Album",
                lastSeenAt: 1
            ).insert(db)
        }
        #expect(try store.adoptAccount("user-a") == .unchanged)
    }

    @Test("a store claimed by somebody else is still erased without asking")
    func differentAccountStillErases() throws {
        let store = try store()
        _ = try store.adoptAccount("user-a")
        try seed(store)
        #expect(try store.adoptAccount("user-b") == .erased)
        #expect(try store.playlists().isEmpty)
    }
}
