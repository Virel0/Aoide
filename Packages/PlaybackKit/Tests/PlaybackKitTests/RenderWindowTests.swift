import Foundation
import Testing
@testable import PlaybackKit

private func makeTracks(_ names: String...) -> [Track] {
    names.map { name in
        Track(
            id: name,
            title: name,
            artist: "Artist",
            album: "Album",
            duration: .seconds(180),
            streamURL: URL(string: "https://example.com/\(name).mp3")!
        )
    }
}

private extension Array where Element == RenderSlot {
    var titles: [String] { map(\.track.title) }
}

/// The render window decides what the player has decoded before a track ends.
/// Getting it wrong is either an audible gap (too little queued) or the wrong song
/// playing (queued the wrong thing), so it is worth pinning down precisely.
@Suite("Render window")
struct RenderWindowTests {
    @Test("returns the current track first")
    func currentFirst() {
        var queue = PlayQueue()
        queue.load(makeTracks("a", "b", "c"), startingAt: 1)
        #expect(queue.renderWindow(count: 3).titles == ["b", "c"])
    }

    @Test("stops at the end of the queue when repeat is off")
    func stopsAtEnd() {
        var queue = PlayQueue()
        queue.load(makeTracks("a", "b"))
        #expect(queue.renderWindow(count: 5).titles == ["a", "b"])
    }

    @Test("wraps under repeat-all so the last-to-first boundary is gapless too")
    func wrapsUnderRepeatAll() {
        var queue = PlayQueue()
        queue.load(makeTracks("a", "b"), startingAt: 1)
        queue.repeatMode = .all
        #expect(queue.renderWindow(count: 3).titles == ["b", "a", "b"])
    }

    /// The case that motivated the occurrence index: without a second item queued,
    /// repeat-one has to rebuild at the boundary and you hear the seam.
    @Test("repeat-one queues the same track again rather than stopping")
    func repeatOneQueuesItself() {
        var queue = PlayQueue()
        queue.load(makeTracks("a", "b"))
        queue.repeatMode = .one
        let window = queue.renderWindow(count: 3)
        #expect(window.titles == ["a", "a", "a"])
    }

    @Test("repeated renderings of one entry stay distinguishable")
    func occurrencesAreDistinct() {
        var queue = PlayQueue()
        queue.load(makeTracks("a"))
        queue.repeatMode = .one
        let window = queue.renderWindow(count: 3)
        #expect(window.map(\.occurrence) == [0, 1, 2])
        #expect(Set(window).count == 3, "identical slots would collapse and the second item would never be enqueued")
        #expect(Set(window.map(\.entryId)).count == 1, "they are still the same queue entry")
    }

    @Test("a fresh entry restarts at occurrence zero")
    func occurrenceResets() {
        var queue = PlayQueue()
        queue.load(makeTracks("a", "b", "c"))
        #expect(queue.renderWindow(count: 3).map(\.occurrence) == [0, 0, 0])
    }

    @Test("looking ahead does not disturb what is playing")
    func doesNotMutate() {
        var queue = PlayQueue()
        queue.load(makeTracks("a", "b", "c"))
        queue.repeatMode = .all
        _ = queue.renderWindow(count: 10)
        #expect(queue.currentTitleForTest == "a")
        #expect(queue.position == 0)
    }

    @Test("follows the shuffled order, not the original one")
    func followsShuffle() {
        var queue = PlayQueue()
        queue.load(makeTracks("a", "b", "c", "d"), startingAt: 0, shuffled: true)
        let window = queue.renderWindow(count: 4)
        #expect(window.titles.first == "a")
        #expect(window.titles == queue.entries.prefix(4).map(\.track.title))
    }

    @Test("an empty queue produces no window rather than crashing")
    func emptyQueue() {
        #expect(PlayQueue().renderWindow(count: 3).isEmpty)
    }

    @Test("a non-positive count produces nothing")
    func zeroCount() {
        var queue = PlayQueue()
        queue.load(makeTracks("a", "b"))
        #expect(queue.renderWindow(count: 0).isEmpty)
        #expect(queue.renderWindow(count: -1).isEmpty)
    }

    @Test("never returns more than asked for, even when repeating forever")
    func honoursCount() {
        var queue = PlayQueue()
        queue.load(makeTracks("a", "b"))
        queue.repeatMode = .all
        #expect(queue.renderWindow(count: 7).count == 7)
    }

    @Test("a single track with repeat off queues only itself")
    func singleTrackNoRepeat() {
        var queue = PlayQueue()
        queue.load(makeTracks("a"))
        #expect(queue.renderWindow(count: 3).titles == ["a"])
    }

    @Test("carries the stream URL the player will actually load")
    func carriesStreamURL() {
        var queue = PlayQueue()
        queue.load(makeTracks("a", "b"))
        let window = queue.renderWindow(count: 2)
        #expect(window[1].track.streamURL.absoluteString == "https://example.com/b.mp3")
    }
}

private extension PlayQueue {
    var currentTitleForTest: String? { currentTrack?.title }
}
