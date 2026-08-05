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

private extension PlayQueue {
    var currentTitle: String? { currentTrack?.title }
    var titles: [String] { entries.map(\.track.title) }
}

@Suite("Queue loading")
struct QueueLoadingTests {
    @Test("an empty queue has no current track")
    func empty() {
        let queue = PlayQueue()
        #expect(queue.isEmpty)
        #expect(queue.current == nil)
        #expect(queue.position == nil)
    }

    @Test("loading starts at the requested index")
    func startsAtIndex() {
        var queue = PlayQueue()
        queue.load(makeTracks("a", "b", "c"), startingAt: 1)
        #expect(queue.currentTitle == "b")
        #expect(queue.upNext.map(\.track.title) == ["c"])
    }

    @Test("an out-of-range start index is clamped rather than crashing")
    func clampsIndex() {
        var queue = PlayQueue()
        queue.load(makeTracks("a", "b"), startingAt: 99)
        #expect(queue.currentTitle == "b")
    }

    @Test("the same song twice stays two distinguishable slots")
    func duplicatesAreDistinct() {
        var queue = PlayQueue()
        queue.load(makeTracks("a", "a"))
        #expect(queue.entries[0].id != queue.entries[1].id)
    }
}

@Suite("Advancing")
struct AdvanceTests {
    @Test("auto-advance walks forward")
    func walksForward() {
        var queue = PlayQueue()
        queue.load(makeTracks("a", "b", "c"))
        let outcome = queue.advanceAutomatically()
        #expect(outcome == .moved)
        #expect(queue.currentTitle == "b")
    }

    @Test("auto-advance off the end stops when repeat is off")
    func stopsAtEnd() {
        var queue = PlayQueue()
        queue.load(makeTracks("a", "b"), startingAt: 1)
        let outcome2 = queue.advanceAutomatically()
        #expect(outcome2 == .ended)
    }

    @Test("repeat-all wraps to the start")
    func repeatAllWraps() {
        var queue = PlayQueue()
        queue.load(makeTracks("a", "b"), startingAt: 1)
        queue.repeatMode = .all
        let outcome3 = queue.advanceAutomatically()
        #expect(outcome3 == .moved)
        #expect(queue.currentTitle == "a")
    }

    @Test("repeat-one replays the same track on natural end")
    func repeatOneReplays() {
        var queue = PlayQueue()
        queue.load(makeTracks("a", "b"))
        queue.repeatMode = .one
        let outcome4 = queue.advanceAutomatically()
        #expect(outcome4 == .repeatCurrent)
        #expect(queue.currentTitle == "a")
    }

    @Test("pressing next escapes repeat-one instead of trapping the listener")
    func skipEscapesRepeatOne() {
        var queue = PlayQueue()
        queue.load(makeTracks("a", "b"))
        queue.repeatMode = .one
        let outcome = queue.skipToNext()
        #expect(outcome == .moved)
        #expect(queue.currentTitle == "b")
    }

    @Test("pressing next on the last track with repeat-one wraps rather than dead-ending")
    func skipWrapsUnderRepeatOne() {
        var queue = PlayQueue()
        queue.load(makeTracks("a", "b"), startingAt: 1)
        queue.repeatMode = .one
        let outcome2 = queue.skipToNext()
        #expect(outcome2 == .moved)
        #expect(queue.currentTitle == "a")
    }

    @Test("previous steps back")
    func previousSteps() {
        var queue = PlayQueue()
        queue.load(makeTracks("a", "b"), startingAt: 1)
        let outcome = queue.skipToPrevious()
        #expect(outcome == .moved)
        #expect(queue.currentTitle == "a")
    }

    @Test("previous from the first track reports ended so the player restarts it")
    func previousAtStart() {
        var queue = PlayQueue()
        queue.load(makeTracks("a", "b"))
        let outcome2 = queue.skipToPrevious()
        #expect(outcome2 == .ended)
        #expect(queue.currentTitle == "a")
    }

    @Test("previous from the first track wraps to the end when repeating")
    func previousWraps() {
        var queue = PlayQueue()
        queue.load(makeTracks("a", "b", "c"))
        queue.repeatMode = .all
        let outcome3 = queue.skipToPrevious()
        #expect(outcome3 == .moved)
        #expect(queue.currentTitle == "c")
    }
}

@Suite("Shuffle")
struct ShuffleTests {
    @Test("shuffling keeps the current song playing and puts it first")
    func keepsCurrentPlaying() {
        var queue = PlayQueue()
        queue.load(makeTracks("a", "b", "c", "d"), startingAt: 2)
        queue.setShuffled(true)
        #expect(queue.currentTitle == "c")
        #expect(queue.position == 0)
        #expect(queue.entries.count == 4)
    }

    @Test("un-shuffling restores the original order and finds the current song in it")
    func restoresOrder() {
        var queue = PlayQueue()
        queue.load(makeTracks("a", "b", "c", "d"), startingAt: 2)
        queue.setShuffled(true)
        queue.setShuffled(false)
        #expect(queue.titles == ["a", "b", "c", "d"])
        #expect(queue.currentTitle == "c")
        #expect(queue.position == 2)
    }

    @Test("shuffling loses no tracks")
    func losesNothing() {
        var queue = PlayQueue()
        queue.load(makeTracks("a", "b", "c", "d", "e"))
        queue.setShuffled(true)
        #expect(Set(queue.titles) == Set(["a", "b", "c", "d", "e"]))
    }

    @Test("setting the state it's already in is a no-op, not a reshuffle")
    func idempotent() {
        var queue = PlayQueue()
        queue.load(makeTracks("a", "b", "c"))
        queue.setShuffled(true)
        let after = queue.titles
        queue.setShuffled(true)
        #expect(queue.titles == after)
    }

    @Test("loading with shuffle on begins from the chosen track")
    func loadShuffled() {
        var queue = PlayQueue()
        queue.load(makeTracks("a", "b", "c", "d"), startingAt: 3, shuffled: true)
        #expect(queue.currentTitle == "d")
        #expect(queue.isShuffled)
    }
}

@Suite("Editing")
struct EditingTests {
    @Test("play-next lands directly after the current track")
    func playNext() {
        var queue = PlayQueue()
        queue.load(makeTracks("a", "b", "c"))
        queue.playNext(makeTracks("x"))
        #expect(queue.titles == ["a", "x", "b", "c"])
        #expect(queue.currentTitle == "a")
    }

    @Test("append goes to the end")
    func append() {
        var queue = PlayQueue()
        queue.load(makeTracks("a"))
        queue.append(makeTracks("z"))
        #expect(queue.titles == ["a", "z"])
    }

    @Test("appending to an empty queue makes the new track current")
    func appendToEmpty() {
        var queue = PlayQueue()
        queue.append(makeTracks("a"))
        #expect(queue.currentTitle == "a")
    }

    @Test("tracks queued while shuffled survive un-shuffling")
    func queuedTracksSurviveUnshuffle() {
        var queue = PlayQueue()
        queue.load(makeTracks("a", "b"), shuffled: true)
        queue.append(makeTracks("z"))
        queue.setShuffled(false)
        #expect(queue.titles.contains("z"))
    }

    @Test("removing an earlier track keeps the same song playing")
    func removeBeforeCurrent() {
        var queue = PlayQueue()
        queue.load(makeTracks("a", "b", "c"), startingAt: 2)
        queue.remove(entryId: queue.entries[0].id)
        #expect(queue.currentTitle == "c")
    }

    @Test("removing the current track advances to what took its place")
    func removeCurrent() {
        var queue = PlayQueue()
        queue.load(makeTracks("a", "b", "c"), startingAt: 1)
        queue.remove(entryId: queue.entries[1].id)
        #expect(queue.titles == ["a", "c"])
        #expect(queue.currentTitle == "c")
    }

    @Test("removing the last remaining track empties the queue cleanly")
    func removeOnly() {
        var queue = PlayQueue()
        queue.load(makeTracks("a"))
        queue.remove(entryId: queue.entries[0].id)
        #expect(queue.isEmpty)
        #expect(queue.position == nil)
        #expect(queue.current == nil)
    }

    @Test("jumping to a slot makes it current")
    func jump() {
        var queue = PlayQueue()
        queue.load(makeTracks("a", "b", "c"))
        let outcome = queue.jump(to: queue.entries[2].id)
        #expect(outcome)
        #expect(queue.currentTitle == "c")
    }

    @Test("jumping to an id that isn't in the queue changes nothing")
    func jumpUnknown() {
        var queue = PlayQueue()
        queue.load(makeTracks("a", "b"))
        let outcome2 = queue.jump(to: UUID())
        #expect(!outcome2)
        #expect(queue.currentTitle == "a")
    }

    @Test("reordering Up Next doesn't change which song is playing")
    func reorderKeepsCurrent() {
        var queue = PlayQueue()
        queue.load(makeTracks("a", "b", "c", "d"), startingAt: 0)
        queue.move(fromOffsets: IndexSet(integer: 3), toOffset: 1)
        #expect(queue.currentTitle == "a")
        #expect(queue.titles == ["a", "d", "b", "c"])
    }
}
