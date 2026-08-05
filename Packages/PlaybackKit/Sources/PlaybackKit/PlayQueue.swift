import Foundation

/// One slot in the queue.
///
/// Carries its own identity because a playlist may legitimately contain the same
/// song twice, and "remove this one" / "where am I after un-shuffling" both need to
/// tell those two slots apart.
public struct QueueEntry: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let track: Track

    init(_ track: Track) {
        self.id = UUID()
        self.track = track
    }
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

    // MARK: - Loading

    /// Replaces the queue. `startingAt` is an index into `tracks` as given, before
    /// any shuffling — so "shuffle this album starting from track 4" still begins on
    /// track 4 and shuffles the rest.
    public mutating func load(_ tracks: [Track], startingAt index: Int = 0, shuffled: Bool = false) {
        let newEntries = tracks.map(QueueEntry.init)
        entries = newEntries
        unshuffledEntries = nil
        position = newEntries.isEmpty ? nil : min(max(index, 0), newEntries.count - 1)
        if shuffled { setShuffled(true) }
    }

    public mutating func clear() {
        entries = []
        unshuffledEntries = nil
        position = nil
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
            var rest = entries
            rest.removeAll { $0.id == current.id }
            rest.shuffle()
            entries = [current] + rest
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
        var tail = Array(entries[(position + 1)...])
        tail.shuffle()
        entries.replaceSubrange((position + 1)..., with: tail)
    }

    // MARK: - Editing

    /// "Play Next" — insert directly after the current track.
    public mutating func playNext(_ tracks: [Track]) {
        let newEntries = tracks.map(QueueEntry.init)
        guard !newEntries.isEmpty else { return }
        guard let position else {
            load(tracks)
            return
        }
        entries.insert(contentsOf: newEntries, at: position + 1)
        // Keep the saved order in sync, or un-shuffling would drop these.
        unshuffledEntries?.append(contentsOf: newEntries)
    }

    /// "Play Last" — append to the end.
    public mutating func append(_ tracks: [Track]) {
        let newEntries = tracks.map(QueueEntry.init)
        guard !newEntries.isEmpty else { return }
        entries.append(contentsOf: newEntries)
        unshuffledEntries?.append(contentsOf: newEntries)
        if position == nil { position = 0 }
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
    public mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {
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
