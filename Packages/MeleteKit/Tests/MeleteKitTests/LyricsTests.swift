import Foundation
import Testing
@testable import MeleteKit

private func decode(_ json: String) throws -> LyricsTrack {
    LyricsTrack(try JSONDecoder.melete.decode(LyricsDocument.self, from: Data(json.utf8)))
}

/// Melete sends lines with their starts for synced lyrics and without for plain
/// ones; it has no per-word timings.
@Suite("Lyrics wire shapes")
struct LyricsWireTests {
    @Test("synced lyrics decode as lines with their starts and no word timing")
    func synced() throws {
        let track = try decode("""
        {"track_id":2,"source":"file","synced":true,"lines":[
          {"start_seconds":1.0,"text":"First line"},
          {"start_seconds":2.5,"text":"Second line"}
        ]}
        """)
        #expect(track.lines.count == 2)
        #expect(track.isSynced)
        #expect(!track.hasWordTiming)
        #expect(track.lines[0].start == .seconds(1))
        #expect(track.lines[1].start == .seconds(2.5))
    }

    @Test("plain lyrics decode as unsynced lines that can still be shown")
    func plain() throws {
        let track = try decode(#"{"lines":[{"start_seconds":null,"text":"No timings here"},{"text":"Second"}]}"#)
        #expect(track.lines.map(\.text) == ["No timings here", "Second"])
        #expect(!track.isSynced)
    }

    @Test("an empty answer is an empty track")
    func empty() throws {
        #expect(try decode(#"{"lines":[]}"#).isEmpty)
    }

    @Test("a start that can't be a time leaves the line untimed")
    func badStart() throws {
        #expect(try decode(#"{"lines":[{"start_seconds":-2,"text":"a"}]}"#).lines[0].start == nil)
    }
}

@Suite("Active line lookup")
struct LyricIndexTests {
    private func synced() throws -> LyricsTrack {
        try decode("""
        {"lines":[
          {"text":"a","start_seconds":1},
          {"text":"b","start_seconds":5},
          {"text":"c","start_seconds":9}
        ]}
        """)
    }

    @Test("before the first line there is no active line")
    func beforeStart() throws {
        #expect(try synced().index(at: .milliseconds(500)) == nil)
    }

    @Test("exactly on a line's start selects that line")
    func onBoundary() throws {
        #expect(try synced().index(at: .seconds(5)) == 1)
    }

    @Test("between lines stays on the earlier one")
    func betweenLines() throws {
        #expect(try synced().index(at: .seconds(7)) == 1)
    }

    @Test("past the last line stays on the last line")
    func pastEnd() throws {
        #expect(try synced().index(at: .seconds(600)) == 2)
    }

    @Test("unsynced lyrics have no active line at any time")
    func unsynced() throws {
        let track = try decode(#"{"lines":[{"text":"a"},{"text":"b"}]}"#)
        #expect(track.index(at: .seconds(30)) == nil)
    }

    @Test("an empty track doesn't crash the lookup")
    func empty() throws {
        #expect(try decode(#"{"lines":[]}"#).index(at: .seconds(1)) == nil)
    }
}
