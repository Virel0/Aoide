import Foundation
import Testing
@testable import JellyfinKit

private func decode(_ json: String) throws -> LyricsTrack {
    LyricsTrack(try JSONDecoder.jellyfin.decode(LyricsDocument.self, from: Data(json.utf8)))
}

/// Jellyfin serves three quite different shapes from one endpoint, and which one
/// you get depends on how the user's lyric file was authored.
@Suite("Lyrics wire shapes")
struct LyricsWireTests {
    @Test("plain LRC decodes as synced lines with no word timing")
    func plainLRC() throws {
        // Jellyfin returns Cues as an empty array for a plain .lrc — one timestamp
        // per line is all the file contains.
        let track = try decode("""
        {"Lyrics":[
          {"Text":"First line","Start":10000000,"Cues":[]},
          {"Text":"Second line","Start":25000000,"Cues":[]}
        ]}
        """)
        #expect(track.lines.count == 2)
        #expect(track.isSynced)
        #expect(!track.hasWordTiming)
        #expect(track.lines[0].start == .seconds(1))
        #expect(track.lines[1].start == .seconds(2.5))
    }

    @Test("plain text decodes as unsynced lines that can still be shown")
    func plainText() throws {
        let track = try decode(#"{"Lyrics":[{"Text":"No timings here"},{"Text":"Second"}]}"#)
        #expect(track.lines.count == 2)
        #expect(!track.isSynced)
        #expect(track.lines[0].start == nil)
        #expect(track.plainText == "No timings here\nSecond")
    }

    @Test("enhanced LRC decodes per-word timings")
    func enhancedLRC() throws {
        let track = try decode("""
        {"Lyrics":[{"Text":"Hello big world","Start":10000000,"Cues":[
          {"Position":0,"EndPosition":6,"Start":10000000},
          {"Position":6,"EndPosition":10,"Start":15000000},
          {"Position":10,"EndPosition":15,"Start":18000000,"End":20000000}
        ]}]}
        """)
        #expect(track.hasWordTiming)
        #expect(track.lines[0].words.map(\.text) == ["Hello", "big", "world"])
    }

    @Test("an empty response is not an empty-looking track")
    func emptyResponse() throws {
        #expect(try decode(#"{"Lyrics":[]}"#).isEmpty)
        #expect(try decode("{}").isEmpty)
    }

    @Test("a missing Text field doesn't fail the whole document")
    func missingText() throws {
        let track = try decode(#"{"Lyrics":[{"Start":10000000}]}"#)
        #expect(track.lines.count == 1)
        #expect(track.lines[0].text.isEmpty)
    }
}

@Suite("Word cue slicing")
struct LyricCueTests {
    /// `position`/`endPosition` are .NET UTF-16 code-unit offsets. Swift's
    /// `String.Index` is grapheme-based, so slicing with them directly is wrong the
    /// moment a line contains an emoji or a combining accent.
    @Test("slices by UTF-16 offset, not by Character")
    func utf16Offsets() throws {
        // "🎵" is two UTF-16 code units but one Character.
        let track = try decode("""
        {"Lyrics":[{"Text":"🎵 hey","Start":0,"Cues":[
          {"Position":0,"EndPosition":2,"Start":0},
          {"Position":3,"EndPosition":6,"Start":5000000}
        ]}]}
        """)
        #expect(track.lines[0].words.map(\.text) == ["🎵", "hey"])
    }

    @Test("out-of-range cue offsets are clamped rather than trapping")
    func clampsOutOfRange() throws {
        let track = try decode("""
        {"Lyrics":[{"Text":"short","Start":0,"Cues":[
          {"Position":-5,"EndPosition":99,"Start":0}
        ]}]}
        """)
        #expect(track.lines[0].words.map(\.text) == ["short"])
    }

    @Test("an inverted cue range doesn't produce a negative slice")
    func invertedRange() throws {
        let track = try decode("""
        {"Lyrics":[{"Text":"abcdef","Start":0,"Cues":[
          {"Position":4,"EndPosition":1,"Start":0}
        ]}]}
        """)
        #expect(track.lines[0].words.isEmpty)
    }

    /// Contiguous cues each carry their own trailing space; rendering them
    /// untrimmed produces visible double gaps.
    @Test("trims each word and drops ones that are only whitespace")
    func trimsWords() throws {
        let track = try decode("""
        {"Lyrics":[{"Text":"one two","Start":0,"Cues":[
          {"Position":0,"EndPosition":4,"Start":0},
          {"Position":4,"EndPosition":7,"Start":5000000},
          {"Position":7,"EndPosition":7,"Start":9000000}
        ]}]}
        """)
        #expect(track.lines[0].words.map(\.text) == ["one", "two"])
    }

    @Test("a word ends where the next one starts")
    func endsAtNextStart() throws {
        let track = try decode("""
        {"Lyrics":[{"Text":"aa bb","Start":0,"Cues":[
          {"Position":0,"EndPosition":3,"Start":0},
          {"Position":3,"EndPosition":5,"Start":5000000}
        ]}]}
        """)
        #expect(track.lines[0].words[0].sweepEnd == .milliseconds(500))
    }

    /// Otherwise the last word before an instrumental break sweeps for the whole gap.
    @Test("a word before a long pause has its sweep clamped")
    func clampsSweep() throws {
        let track = try decode("""
        {"Lyrics":[{"Text":"aa bb","Start":0,"Cues":[
          {"Position":0,"EndPosition":3,"Start":0},
          {"Position":3,"EndPosition":5,"Start":300000000}
        ]}]}
        """)
        #expect(track.lines[0].words[0].sweepEnd == .milliseconds(1200))
    }
}

@Suite("Active line lookup")
struct LyricIndexTests {
    private func synced() throws -> LyricsTrack {
        try decode("""
        {"Lyrics":[
          {"Text":"a","Start":10000000},
          {"Text":"b","Start":50000000},
          {"Text":"c","Start":90000000}
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
        let track = try decode(#"{"Lyrics":[{"Text":"a"},{"Text":"b"}]}"#)
        #expect(track.index(at: .seconds(30)) == nil)
    }

    @Test("an empty track doesn't crash the lookup")
    func empty() throws {
        #expect(try decode(#"{"Lyrics":[]}"#).index(at: .seconds(1)) == nil)
    }
}
