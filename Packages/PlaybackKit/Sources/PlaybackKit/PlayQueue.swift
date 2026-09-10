import Foundation

/// One slot in the queue.
///
/// Carries its own identity because a playlist may legitimately contain the same
/// song twice, and "remove this one" / "where am I after un-shuffling" both need to
/// tell those two slots apart.
public struct QueueEntry: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let track: Track
    /// Put here on purpose, by Play Next or Play Last, rather than arriving as
    /// part of whatever album or playlist is running. See ``PlayQueue/lane``.
    public let isManual: Bool

    init(_ track: Track, isManual: Bool = false) {
        self.id = UUID()
        self.track = track
        self.isManual = isManual
    }
}

/// One track to load into the player, ahead of when it is needed.
///
/// `occurrence` counts how many times this entry has already appeared earlier in
/// the same window — non-zero only under repeat-one, where the same entry is
/// rendered twice in a row and each rendering needs its own `AVPlayerItem`.
/// It describes the window rather than identifying an item: the engine tracks
/// loaded items by object identity, since position in the window already says
/// which rendering is which.
public struct RenderSlot: Hashable, Sendable {
    public let entryId: UUID
    public let track: Track
    public let occurrence: Int
}

/// What the caller should do after a queue movement.
public enum AdvanceOutcome: Equatable, Sendable {
    /// Position changed — play whatever is now current.
    case moved
    /// Repeat-one is on: play the same track again from the top.
    case repeatCurrent
    /// Nothing left to play.
    case ended
}

/// The queue model, with no dependency on AVFoundation.
///
/// All the semantics that are easy to get subtly wrong — shuffle preserving the
/// current song, repeat-one applying to auto-advance but not to a deliberate skip,
/// wrapping at the ends — live here so they can be tested without a player.
public struct PlayQueue: Sendable {
    /// Entries in the order they will actually play.
    public private(set) var entries: [QueueEntry] = []

    /// The pre-shuffle order, retained so turning shuffle off restores it.
    private var unshuffledEntries: [QueueEntry]?

    /// Index into ``entries``. `nil` when the queue is empty.
    public private(set) var position: Int?

    public var repeatMode: RepeatMode = .off

    public var isShuffled: Bool { unshuffledEntries != nil }

    public init() {}

    // MARK: - Reading

    public var current: QueueEntry? {
        guard let position, entries.indices.contains(position) else { return nil }
        return entries[position]
    }

    public var currentTrack: Track? { current?.track }

    public var isEmpty: Bool { entries.isEmpty }

    /// Everything queued after the current track, in play order.
    public var upNext: [QueueEntry] {
        guard let position, position + 1 < entries.count else { return [] }
        return Array(entries[(position + 1)...])
    }

    /// The tracks the listener put here themselves, which play before the album
    /// or playlist resumes.
    ///
    /// A run rather than a set: it is the entries marked manual that sit
    /// *immediately* after the current one. Once one has played it leaves the
    /// lane by falling behind the playhead, which is what makes the lane empty
    /// itself without anything having to tidy up.
    public var lane: [QueueEntry] {
        Array(upNext.prefix { $0.isManual })
    }

    /// What follows the lane: the rest of whatever was playing.
    public var contextUpNext: [QueueEntry] {
        Array(upNext.dropFirst(lane.count))
    }

    /// Index just past the lane, which is where Play Last inserts.
    private var laneEnd: Int {
        guard let position else { return entries.count }
        return position + 1 + lane.count
    }

    /// The next `count` things that will play, current first, without mutating
    /// anything.
    ///
    /// Gapless playback needs the following track decoded *before* the boundary
    /// arrives, so the player has to be told what's coming. Rather than restating
    /// the repeat and shuffle rules — and letting them drift from the ones above —
    /// this walks a copy of the queue through ``advanceAutomatically()``, which is
    /// the same code path a natural track ending takes.
    ///
    /// Under repeat-one the same entry legitimately appears more than once; the
    /// `occurrence` index distinguishes those renderings, because the player needs
    /// two separate items for them and would otherwise treat them as one.
    public func renderWindow(count: Int) -> [RenderSlot] {
        guard count > 0, let current else { return [] }

        var occurrences: [UUID: Int] = [current.id: 0]
        var window = [RenderSlot(entryId: current.id, track: current.track, occurrence: 0)]

        // A copy — `PlayQueue` is a value type, so this look-ahead cannot disturb
        // what is actually playing.
        var probe = self
        while window.count < count {
            guard probe.advanceAutomatically() != .ended, let entry = probe.current else { break }
            let n = (occurrences[entry.id] ?? -1) + 1
            occurrences[entry.id] = n
            window.append(RenderSlot(entryId: entry.id, track: entry.track, occurrence: n))
        }
        return window
    }

    // MARK: - Loading

    /// Replaces the queue. `startingAt` is an index into `tracks` as given, before
    /// any shuffling — so "shuffle this album starting from track 4" still begins on
    /// track 4 and shuffles the rest.
    public mutating func load(_ tracks: [Track], startingAt index: Int = 0, shuffled: Bool = false) {
        // What the listener queued by hand outlives the thing that was playing.
        // Picking a new album is a statement about the album, not a decision to
        // throw away the three songs they lined up a minute ago — and a lane
        // that evaporates exactly when somebody starts something else is a lane
        // that cannot be relied on.
        let kept = lane
        let newEntries = tracks.map { QueueEntry($0) }
        entries = newEntries
        unshuffledEntries = nil
        position = newEntries.isEmpty ? nil : min(max(index, 0), newEntries.count - 1)
        if shuffled { setShuffled(true) }
        if !kept.isEmpty, let position {
            entries.insert(contentsOf: kept, at: position + 1)
            if var saved = unshuffledEntries {
                saved.insert(contentsOf: kept, at: min(position + 1, saved.count))
                unshuffledEntries = saved
            }
        } else if !kept.isEmpty {
            entries = kept
            position = 0
        }
    }

    public mutating func clear() {
        entries = []
        unshuffledEntries = nil
        position = nil
    }

    /// Drops everything after the current track, which keeps playing.
    ///
    /// The queue's "now" is left alone: clearing is about what comes next, and a
    /// clear that also stopped the music would be the one thing nobody meant.
    public mutating func clearUpNext() {
        guard let position else { return }
        let kept = Set(entries.prefix(position + 1).map(\.id))
        entries.removeAll { !kept.contains($0.id) }
        unshuffledEntries?.removeAll { !kept.contains($0.id) }
    }

    // MARK: - Movement

    /// The current track finished on its own.
    public mutating func advanceAutomatically() -> AdvanceOutcome {
        guard position != nil else { return .ended }

        // Repeat-one applies to natural end-of-track only. A deliberate skip should
        // still move on, which is why `skipToNext` doesn't share this path.
        if repeatMode == .one { return .repeatCurrent }
        return moveForward(wrapping: repeatMode == .all)
    }

    /// The user pressed next.
    public mutating func skipToNext() -> AdvanceOutcome {
        guard position != nil else { return .ended }
        // Wrap on an explicit skip whenever any repeat mode is on — with repeat-one
        // engaged, being unable to leave the last track would be a trap.
        return moveForward(wrapping: repeatMode != .off)
    }

    /// The user pressed previous. Whether this should instead restart the current
    /// track depends on elapsed time, which is the player's business, not the queue's.
    public mutating func skipToPrevious() -> AdvanceOutcome {
        guard let position else { return .ended }
        if position > 0 {
            self.position = position - 1
            return .moved
        }
        if repeatMode != .off, !entries.isEmpty {
            self.position = entries.count - 1
            return .moved
        }
        return .ended
    }

    private mutating func moveForward(wrapping: Bool) -> AdvanceOutcome {
        guard let position else { return .ended }
        if position + 1 < entries.count {
            self.position = position + 1
            return .moved
        }
        if wrapping, !entries.isEmpty {
            self.position = 0
            return .moved
        }
        return .ended
    }

    /// Jump straight to a slot — tapping a row in the Up Next list.
    public mutating func jump(to entryId: UUID) -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == entryId }) else { return false }
        position = index
        return true
    }

    // MARK: - Shuffle

    /// Turning shuffle on keeps the current song playing and shuffles everything
    /// else around it. Turning it off restores the original order and resumes from
    /// wherever the current song sits in it — matching Apple Music.
    public mutating func setShuffled(_ shuffled: Bool) {
        guard shuffled != isShuffled else { return }

        if shuffled {
            let original = entries
            guard let current else {
                unshuffledEntries = original
                entries.shuffle()
                return
            }
            // The lane is not shuffled. Somebody who queued three songs and
            // then hit shuffle meant "surprise me afterwards", not "scatter the
            // three things I just chose".
            let keptLane = lane
            let untouched = Set([current.id] + keptLane.map(\.id))
            var rest = entries
            rest.removeAll { untouched.contains($0.id) }
            rest.shuffle()
            entries = [current] + keptLane + rest
            position = 0
            unshuffledEntries = original
        } else {
            guard let original = unshuffledEntries else { return }
            let currentId = current?.id
            entries = original
            unshuffledEntries = nil
            position = currentId.flatMap { id in original.firstIndex { $0.id == id } } ?? position
        }
    }

    /// Reshuffles the tracks after the current one, leaving it playing.
    public mutating func reshuffle() {
        guard isShuffled, let position, position + 1 < entries.count else { return }
        // Everything past the lane, for the same reason shuffle skips it.
        let start = laneEnd
        guard start < entries.count else { return }
        var tail = Array(entries[start...])
        tail.shuffle()
        entries.replaceSubrange(start..., with: tail)
        _ = position
    }

    // MARK: - Editing

    /// "Play Next" — the front of the lane, ahead of anything queued earlier.
    public mutating func playNext(_ tracks: [Track]) {
        let newEntries = tracks.map { QueueEntry($0, isManual: true) }
        guard !newEntries.isEmpty else { return }
        guard let position else {
            load(tracks)
            return
        }
        entries.insert(contentsOf: newEntries, at: position + 1)
        // Mirror the *placement*, not just the membership. Appending here meant
        // that turning shuffle off flung freshly queued songs to the end of a
        // restored order — out of Up Next entirely, hours away.
        if let saved = unshuffledEntries {
            let anchor = current.map { c in saved.firstIndex { $0.id == c.id } } ?? nil
            if let anchor {
                unshuffledEntries?.insert(contentsOf: newEntries, at: anchor + 1)
            } else {
                unshuffledEntries?.append(contentsOf: newEntries)
            }
        }
    }

    /// "Play Last" — the back of the lane, not the back of the queue.
    ///
    /// The end of the queue is the wrong place and always was: asking for a song
    /// while a twenty-track album is running used to mean hearing it in an hour.
    /// It goes after everything else queued by hand, and before the album picks
    /// up again.
    public mutating func append(_ tracks: [Track]) {
        let newEntries = tracks.map { QueueEntry($0, isManual: true) }
        guard !newEntries.isEmpty else { return }
        guard position != nil else {
            entries.append(contentsOf: newEntries)
            unshuffledEntries?.append(contentsOf: newEntries)
            position = 0
            return
        }
        entries.insert(contentsOf: newEntries, at: laneEnd)
        // Mirrored into the pre-shuffle order for the same reason `playNext`
        // mirrors: turning shuffle off must not fling a queued song to the end.
        if let saved = unshuffledEntries {
            let anchor = current.flatMap { c in saved.firstIndex { $0.id == c.id } }
            let lastLaneId = lane.last?.id
            let laneAnchor = lastLaneId.flatMap { id in saved.firstIndex { $0.id == id } }
            let at = (laneAnchor ?? anchor).map { $0 + 1 } ?? saved.count
            unshuffledEntries?.insert(contentsOf: newEntries, at: at)
        }
    }

    /// Removing the currently playing entry leaves `position` pointing at whatever
    /// slid into its place, so playback continues rather than stopping dead.
    public mutating func remove(entryId: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == entryId }) else { return }
        entries.remove(at: index)
        unshuffledEntries?.removeAll { $0.id == entryId }

        guard let position else { return }
        if entries.isEmpty {
            self.position = nil
        } else if index < position {
            self.position = position - 1
        } else if index == position {
            self.position = min(position, entries.count - 1)
        }
    }

    /// Reorders the Up Next list by drag.
    ///
    /// Ignores the whole gesture if any index is out of range rather than partially
    /// applying it. A drag can be delivered against a stale index space — a track
    /// boundary moves the queue underneath an open Up Next list — and performing a
    /// *different* reorder than the user drew is worse than performing none.
    public mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        guard source.allSatisfy({ entries.indices.contains($0) }) else { return }
        guard (0...entries.count).contains(destination) else { return }

        let currentId = current?.id
        entries.moveElements(fromOffsets: source, toOffset: destination)
        if let currentId {
            position = entries.firstIndex { $0.id == currentId } ?? position
        }
    }
}

private extension Array {
    /// SwiftUI ships `move(fromOffsets:toOffset:)`, but PlaybackKit deliberately
    /// doesn't import SwiftUI — the queue model has to stay usable from CarPlay
    /// and from tests. Same semantics: `destination` is an offset in the list as it
    /// looks *before* the removals, so it has to be adjusted for elements pulled
    /// out ahead of it.
    mutating func moveElements(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.map { self[$0] }
        for index in source.sorted(by: >) {
            remove(at: index)
        }
        let adjusted = destination - source.count { $0 < destination }
        insert(contentsOf: moving, at: Swift.min(Swift.max(adjusted, 0), count))
    }
}
