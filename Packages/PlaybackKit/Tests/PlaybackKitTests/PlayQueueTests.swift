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

    /// Play Next inserted into the live order but only appended to the saved one,
    /// so turning shuffle off flung freshly queued songs to the end — out of Up
    /// Next entirely, potentially hours away.
    @Test("play-next keeps its place when shuffle is turned off")
    func playNextSurvivesUnshuffle() {
        var queue = PlayQueue()
        queue.load(makeTracks("a", "b", "c", "d", "e"), startingAt: 0, shuffled: true)
        queue.playNext(makeTracks("x"))
        #expect(queue.upNext.first?.track.title == "x")

        queue.setShuffled(false)
        let position = try! #require(queue.titles.firstIndex(of: "x"))
        let current = try! #require(queue.position)
        #expect(position == current + 1, "should still be the very next thing to play")
    }

    @Test("play-next still appends when there is no saved order to place it in")
    func playNextUnshuffled() {
        var queue = PlayQueue()
        queue.load(makeTracks("a", "b"))
        queue.playNext(makeTracks("x"))
        #expect(queue.titles == ["a", "x", "b"])
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

    /// A drag is delivered in the index space of the rows SwiftUI last rendered.
    /// A track boundary landing mid-drag shifts the queue underneath it, and the
    /// resulting index used to run straight into an unguarded subscript.
    @Test("an out-of-range drag index is ignored rather than crashing")
    func rejectsStaleDragIndex() {
        var queue = PlayQueue()
        queue.load(makeTracks("a", "b", "c"))
        let before = queue.titles

        queue.move(fromOffsets: IndexSet(integer: 99), toOffset: 1)
        #expect(queue.titles == before)

        queue.move(fromOffsets: IndexSet([0, 42]), toOffset: 1)
        #expect(queue.titles == before, "a partially-valid set must be ignored whole, not applied in part")

        queue.move(fromOffsets: IndexSet(integer: 0), toOffset: 99)
        #expect(queue.titles == before)
    }

    @Test("a drag on an empty queue is a no-op")
    func moveOnEmptyQueue() {
        var queue = PlayQueue()
        queue.move(fromOffsets: IndexSet(integer: 0), toOffset: 0)
        #expect(queue.isEmpty)
    }

    @Test("moving to the very end is still allowed")
    func moveToEnd() {
        var queue = PlayQueue()
        queue.load(makeTracks("a", "b", "c"))
        queue.move(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        #expect(queue.titles == ["b", "c", "a"])
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

@Suite("Clearing up next")
struct ClearUpNextTests {
    private func tracks(_ names: String...) -> [Track] {
        names.map { Track(id: $0, title: $0, artist: "a", album: "b", duration: .seconds(1), streamURL: URL(string: "https://x/\($0)")!) }
    }

    @Test("keeps the current track and everything before it")
    func keepsCurrentAndHistory() {
        var queue = PlayQueue()
        queue.load(tracks("a", "b", "c", "d"), startingAt: 1)
        queue.clearUpNext()
        #expect(queue.entries.map(\.track.id) == ["a", "b"])
        #expect(queue.current?.track.id == "b")
        #expect(queue.upNext.isEmpty)
    }

    @Test("under shuffle, the original order forgets the same tracks")
    func shuffled() {
        var queue = PlayQueue()
        queue.load(tracks("a", "b", "c", "d", "e"), startingAt: 0, shuffled: true)
        let current = queue.current?.track.id
        queue.clearUpNext()
        #expect(queue.upNext.isEmpty)
        queue.setShuffled(false)
        // Un-shuffling reveals the original order, which must hold no track that was cleared.
        #expect(queue.entries.map(\.track.id) == [current])
    }

    @Test("an empty queue is left alone")
    func empty() {
        var queue = PlayQueue()
        queue.clearUpNext()
        #expect(queue.isEmpty)
    }
}

@Suite("Interruption policy")
struct InterruptionPolicyTests {
    @Test("music that was playing comes back, whatever the system flag says")
    func resumesWhatWasPlaying() {
        // iOS routinely omits `shouldResume` for a phone call, which is exactly
        // the case that used to end a listening session for good.
        #expect(InterruptionPolicy.shouldResume(systemSaysResume: false, wasPlayingWhenInterrupted: true))
        #expect(InterruptionPolicy.shouldResume(systemSaysResume: true, wasPlayingWhenInterrupted: true))
    }

    @Test("the system's word is honoured even if we were paused")
    func honoursTheFlag() {
        #expect(InterruptionPolicy.shouldResume(systemSaysResume: true, wasPlayingWhenInterrupted: false))
    }

    @Test("something already paused stays paused")
    func staysPaused() {
        #expect(!InterruptionPolicy.shouldResume(systemSaysResume: false, wasPlayingWhenInterrupted: false))
    }
}

/// Mirrored by the desktop's `loudness.test.ts`; the two must not drift, or one
/// album plays at two levels on two devices.
@Suite("Loudness normalisation")
struct LoudnessNormalisationTests {
    private func close(_ a: Double?, _ b: Double, _ tolerance: Double = 0.001) -> Bool {
        guard let a else { return false }
        return abs(a - b) <= tolerance
    }

    @Test("a loud master is turned down to the reference")
    func attenuates() {
        #expect(close(LoudnessNormalisation.gainDb(loudnessLufs: -9), -9))
        #expect(close(LoudnessNormalisation.gainDb(loudnessLufs: -14), -4))
    }

    @Test("a quiet master is left alone rather than amplified")
    func neverBoosts() {
        #expect(LoudnessNormalisation.gainDb(loudnessLufs: -24) == nil)
        #expect(LoudnessNormalisation.gainDb(loudnessLufs: -18) == nil)
    }

    @Test("a quiet track is left alone even when its peak is already over")
    func leavesQuietTracksAlone() {
        // The desktop settled this one: the peak rule stops *us* pushing a
        // signal over full scale, and a file we have decided not to touch is
        // not ours to limit. Both apps must answer the same here.
        #expect(LoudnessNormalisation.gainDb(loudnessLufs: -20, truePeakDbfs: 1.5) == nil)
    }

    @Test("a peak under full scale changes nothing about the attenuation")
    func respectsTruePeak() {
        #expect(close(LoudnessNormalisation.gainDb(loudnessLufs: -9, truePeakDbfs: -0.3), -9))
    }

    @Test("nothing measured means nothing applied")
    func unmeasured() {
        #expect(LoudnessNormalisation.gainDb(loudnessLufs: nil) == nil)
        #expect(LoudnessNormalisation.gainDb(loudnessLufs: .nan) == nil)
        #expect(LoudnessNormalisation.volumeFactor(loudnessLufs: nil) == nil)
    }

    @Test("the linear factor matches the decibels, and never exceeds one")
    func linear() {
        let factor = try! #require(LoudnessNormalisation.volumeFactor(loudnessLufs: -12))
        #expect(abs(factor - pow(10, -6.0 / 20)) < 0.0001)
        #expect(factor < 1)
    }

    /// The same nine inputs the desktop answers, with the same nine answers.
    ///
    /// "Both apps agree" is a claim, and this table is the only thing that makes
    /// it one: it is duplicated verbatim in the desktop's
    /// `loudness-parity.test.ts`, so either side changing its arithmetic breaks
    /// its own copy. Rounding is included deliberately — two implementations a
    /// hundredth of a decibel apart are still two implementations.
    @Test("answers the desktop's table identically", arguments: [
        (-9.0, Double?.none, Double?(-9)),
        (-14.0, Double?.none, Double?(-4)),
        (-24.0, Double?.none, Double?.none),
        (-18.0, Double?.none, Double?.none),
        (-20.0, Double?(1.5), Double?.none),
        (-9.0, Double?(-0.3), Double?(-9)),
        (-6.0, Double?(2), Double?(-12)),
        (-30.0, Double?(0.5), Double?.none),
        (-8.333, Double?.none, Double?(-9.67)),
    ])
    func parityWithDesktop(_ lufs: Double, _ truePeak: Double?, _ expected: Double?) {
        let answer = LoudnessNormalisation.gainDb(loudnessLufs: lufs, truePeakDbfs: truePeak)
        if let expected {
            #expect(close(answer, expected))
        } else {
            #expect(answer == nil)
        }
    }

    @Test("the reference is the ReplayGain one, shared with every other side")
    func reference() {
        #expect(LoudnessNormalisation.referenceLufs == -18)
    }
}

/// The lane: what the listener put there by hand, ahead of whatever was running.
@Suite("The manual lane")
struct QueueLaneTests {
    private func tracks(_ names: String...) -> [Track] {
        names.map {
            Track(id: $0, title: $0, artist: "a", album: "b", duration: .seconds(1),
                  streamURL: URL(string: "https://x/\($0)")!)
        }
    }

    @Test("Play Last lands after the current track, not at the end of the album")
    func playLastJoinsTheLane() {
        var queue = PlayQueue()
        queue.load(tracks("a1", "a2", "a3", "a4"), startingAt: 0)
        queue.append(tracks("wanted"))
        // The whole point: an hour of album no longer sits in front of it.
        #expect(queue.upNext.map(\.track.id) == ["wanted", "a2", "a3", "a4"])
        #expect(queue.lane.map(\.track.id) == ["wanted"])
        #expect(queue.contextUpNext.map(\.track.id) == ["a2", "a3", "a4"])
    }

    @Test("Play Next goes to the front of the lane, Play Last to the back")
    func laneOrdering() {
        var queue = PlayQueue()
        queue.load(tracks("a1", "a2"), startingAt: 0)
        queue.append(tracks("second"))
        queue.append(tracks("third"))
        queue.playNext(tracks("first"))
        #expect(queue.lane.map(\.track.id) == ["first", "second", "third"])
        #expect(queue.contextUpNext.map(\.track.id) == ["a2"])
    }

    @Test("a lane track that has played leaves the lane")
    func laneEmptiesItself() {
        var queue = PlayQueue()
        queue.load(tracks("a1", "a2"), startingAt: 0)
        queue.append(tracks("q1", "q2"))
        #expect(queue.lane.count == 2)
        _ = queue.skipToNext()
        #expect(queue.current?.track.id == "q1")
        #expect(queue.lane.map(\.track.id) == ["q2"], "the one still ahead")
        _ = queue.skipToNext()
        _ = queue.skipToNext()
        #expect(queue.current?.track.id == "a2")
        #expect(queue.lane.isEmpty)
    }

    @Test("shuffle leaves the lane in place and shuffles the rest")
    func shuffleSparesTheLane() {
        var queue = PlayQueue()
        queue.load(tracks("a1", "a2", "a3", "a4", "a5", "a6"), startingAt: 0)
        queue.append(tracks("q1", "q2"))
        queue.setShuffled(true)
        #expect(queue.current?.track.id == "a1")
        #expect(queue.lane.map(\.track.id) == ["q1", "q2"], "chosen by hand, so not scattered")
        #expect(Set(queue.contextUpNext.map(\.track.id)) == ["a2", "a3", "a4", "a5", "a6"])
    }

    @Test("starting something else keeps what was queued by hand")
    func laneSurvivesANewContext() {
        var queue = PlayQueue()
        queue.load(tracks("a1", "a2"), startingAt: 0)
        queue.append(tracks("kept"))
        queue.load(tracks("b1", "b2", "b3"), startingAt: 0)
        #expect(queue.current?.track.id == "b1")
        #expect(queue.lane.map(\.track.id) == ["kept"], "queued a minute ago, still wanted")
        #expect(queue.contextUpNext.map(\.track.id) == ["b2", "b3"])
    }

    @Test("a track already played is not carried into the next context")
    func playedLaneTracksAreNotCarried() {
        var queue = PlayQueue()
        queue.load(tracks("a1", "a2"), startingAt: 0)
        queue.append(tracks("q1"))
        _ = queue.skipToNext()          // q1 is now playing
        queue.load(tracks("b1", "b2"), startingAt: 0)
        #expect(queue.lane.isEmpty, "it has had its turn")
        #expect(queue.entries.map(\.track.id) == ["b1", "b2"])
    }

    @Test("an empty queue still starts playing what was added")
    func appendToEmpty() {
        var queue = PlayQueue()
        queue.append(tracks("only"))
        #expect(queue.current?.track.id == "only")
    }

    @Test("album tracks are not manual, so nothing is mistaken for a choice")
    func contextIsNotManual() {
        var queue = PlayQueue()
        queue.load(tracks("a1", "a2"), startingAt: 0)
        #expect(queue.entries.allSatisfy { !$0.isManual })
        #expect(queue.lane.isEmpty)
    }
}

@Suite("Extending a running queue")
struct QueueExtensionTests {
    private func track(_ id: String) -> Track {
        Track(id: id, title: id, artist: "A", album: "B", duration: .seconds(180), streamURL: URL(string: "https://example.com/\(id)")!)
    }

    @Test("Found songs go behind everything, including the lane")
    func behindTheLane() {
        var queue = PlayQueue()
        queue.load([track("1"), track("2")])
        queue.playNext([track("hand")])
        queue.extend([track("found")])

        #expect(queue.entries.map(\.track.id) == ["1", "hand", "2", "found"])
        #expect(queue.entries.last?.isManual == false)
        #expect(queue.lane.map(\.track.id) == ["hand"])
    }

    @Test("They do not move the listener")
    func positionUnmoved() {
        var queue = PlayQueue()
        queue.load([track("1"), track("2")], startingAt: 1)
        queue.extend([track("found")])
        #expect(queue.currentTrack?.id == "2")
    }

    @Test("They shuffle like context, not like a choice")
    func shuffleMirrors() {
        var queue = PlayQueue()
        queue.load((1...8).map { track("\($0)") })
        queue.setShuffled(true)
        queue.extend([track("found")])
        // Present under shuffle, and still there when it is turned off — the
        // mirrored order has to learn about them too.
        #expect(queue.entries.contains { $0.track.id == "found" })
        queue.setShuffled(false)
        #expect(queue.entries.map(\.track.id) == ["1", "2", "3", "4", "5", "6", "7", "8", "found"])
    }

    @Test("Nothing to add changes nothing")
    func empty() {
        var queue = PlayQueue()
        queue.load([track("1")])
        queue.extend([])
        #expect(queue.entries.count == 1)
    }
}
