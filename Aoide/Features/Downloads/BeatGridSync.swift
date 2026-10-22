import Foundation
import JellyfinKit
import PlaybackKit
import os

/// Where each track's beats and bars are, as the sidecar measured them.
///
/// Only ever asked for tracks that are on this device, because only those can be
/// mixed — a grid for a track that will be streamed is a request nothing can use.
/// A server too old to have the endpoint is not an error: nothing is mixed, and
/// it is asked again in a while.
///
/// See `docs/beat-grid.md`. The rules that decide what to do with a grid are in
/// `PlaybackKit/DJTransition.swift`; this only fetches and remembers.
@MainActor
@Observable
final class BeatGridSync {
    static let shared = BeatGridSync()

    /// A grid, or a definite nothing: the server looked and this track has no
    /// grid worth having. Both are answers, and neither is asked twice.
    private(set) var byTrack: [String: BeatGrid?] = [:]

    private var pendingUntil: [String: Date] = [:]
    private var absentUntil: Date?
    private var inFlight: Set<String> = []
    private let log = Logger(subsystem: "com.example.aoide", category: "beatgrid")

    private struct Wire: Decodable {
        struct Grid: Decodable {
            struct Segment: Decodable {
                var startMs: Double
                var endMs: Double
                var anchorMs: Double
                var bpm: Double
                var residualMs: Double
                var beats: Int
            }
            var segments: [Segment]
            var beatsPerBar: Int?
            var downbeatIndex: Int?
            var mixInMs: Double?
            var mixOutMs: Double?
            var key: String?
            var keyConfidence: Double?
        }
        var grids: [String: Grid?]
        var pending: [String]?
    }

    private init() {
        if let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode([String: StoredGrid?].self, from: data) {
            byTrack = saved.mapValues { $0?.grid }
        }
    }

    func grid(for trackId: String) -> BeatGrid? {
        (byTrack[trackId] ?? nil).flatMap { AutoDJPreference.isOn ? $0 : nil }
    }

    /// Asks about tracks. Any of them, downloaded or not: with Auto DJ on the
    /// set has to know whether a record it is considering can follow the one
    /// playing, and a record it cannot yet play locally may be fetched before
    /// it is needed.
    func prefetch(ids: [String]) {
        guard AutoDJPreference.isOn, let client = AppSession.shared.client else { return }
        if let absentUntil, absentUntil > Date() { return }
        let now = Date()
        let wanted = ids.filter { id in
            byTrack[id] == nil
                && !inFlight.contains(id)
                && (pendingUntil[id] ?? .distantPast) <= now
        }
        guard !wanted.isEmpty else { return }
        for chunk in stride(from: 0, to: wanted.count, by: 200) {
            let slice = Array(wanted[chunk..<min(chunk + 200, wanted.count)])
            inFlight.formUnion(slice)
            Task { await fetch(slice, client: client) }
        }
    }

    private func fetch(_ ids: [String], client: JellyfinClient) async {
        defer { inFlight.subtract(ids) }
        do {
            let data = try await client.beatGrids(ids: ids)
            let wire = try JSONDecoder().decode(Wire.self, from: data)
            for (id, found) in wire.grids {
                byTrack[id] = found.map(Self.grid(from:))
            }
            // Measured lazily, exactly as the other two endpoints do it: asked
            // again shortly, and until then the track simply is not mixable.
            let retryAt = Date().addingTimeInterval(120)
            for id in wire.pending ?? [] { pendingUntil[id] = retryAt }
            save()
        } catch {
            if JellyfinClient.isSidecarAbsent(error) {
                absentUntil = Date().addingTimeInterval(3_600)
                log.info("This server has no beat grids; nothing will be mixed")
            } else {
                log.warning("Couldn't fetch beat grids: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private static func grid(from wire: Wire.Grid) -> BeatGrid {
        BeatGrid(
            segments: wire.segments.map {
                BeatGrid.Segment(
                    startMs: $0.startMs, endMs: $0.endMs, anchorMs: $0.anchorMs,
                    bpm: $0.bpm, residualMs: $0.residualMs, beats: $0.beats
                )
            },
            beatsPerBar: wire.beatsPerBar,
            downbeatIndex: wire.downbeatIndex,
            mixInMs: wire.mixInMs,
            mixOutMs: wire.mixOutMs,
            key: wire.key,
            keyConfidence: wire.keyConfidence
        )
    }

    // MARK: - Keeping them

    /// Named by generation, like the analysis cache, and for the same reason:
    /// sidecar 1.15.0.0 found that a short loud passage had been deciding whole
    /// tracks' tempi — one file read 73 BPM with its sung bridge and 128 without
    /// — and dropped every grid it had measured so the levelled estimator could
    /// take them again. Everything cached here came from the old one.
    @ObservationIgnored private let url: URL = {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("beat-grids.json"))
        return directory.appendingPathComponent("beat-grids-2.json")
    }()

    private func save() {
        let stored = byTrack.mapValues { $0.map(StoredGrid.init(grid:)) }
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// `BeatGrid` is PlaybackKit's and stays free of `Codable`, which is a
    /// storage concern rather than a playback one. This is the file's shape.
    private struct StoredGrid: Codable {
        struct Segment: Codable {
            var startMs: Double
            var endMs: Double
            var anchorMs: Double
            var bpm: Double
            var residualMs: Double
            var beats: Int
        }
        var segments: [Segment]
        var beatsPerBar: Int?
        var downbeatIndex: Int?
        var mixInMs: Double?
        var mixOutMs: Double?
        var key: String?
        var keyConfidence: Double?

        init(grid: BeatGrid) {
            segments = grid.segments.map {
                Segment(startMs: $0.startMs, endMs: $0.endMs, anchorMs: $0.anchorMs, bpm: $0.bpm, residualMs: $0.residualMs, beats: $0.beats)
            }
            beatsPerBar = grid.beatsPerBar
            downbeatIndex = grid.downbeatIndex
            mixInMs = grid.mixInMs
            mixOutMs = grid.mixOutMs
            key = grid.key
            keyConfidence = grid.keyConfidence
        }

        var grid: BeatGrid {
            BeatGrid(
                segments: segments.map {
                    BeatGrid.Segment(startMs: $0.startMs, endMs: $0.endMs, anchorMs: $0.anchorMs, bpm: $0.bpm, residualMs: $0.residualMs, beats: $0.beats)
                },
                beatsPerBar: beatsPerBar,
                downbeatIndex: downbeatIndex,
                mixInMs: mixInMs,
                mixOutMs: mixOutMs,
                key: key,
                keyConfidence: keyConfidence
            )
        }
    }
}

/// Auto DJ: whether records that can be mixed are mixed.
///
/// Off by default, and stricter than Crossfade in every way — see
/// `docs/beat-grid.md`. Both tracks have to be downloaded, gridded, steady and
/// close enough in tempo, which is most often not true, and then the pair
/// crossfades instead.
enum AutoDJPreference {
    static let key = "aoide.autoDJ"

    /// Whether Auto DJ is offered at all. Off since 2026-10-22: without stems,
    /// and on a library of vocal pop and rock, the transitions never sounded
    /// like a DJ — see docs/arrangement.md, "Shelved". Everything behind it is
    /// kept and tested; turning this back on brings the switch back on the
    /// player and in Settings, and every path that reads ``isOn`` with it.
    static let isAvailable = false

    /// Whether Auto DJ is in force. Always false while it is not offered,
    /// whatever an old install left in the setting.
    static var isOn: Bool { isAvailable && UserDefaults.standard.bool(forKey: key) }
}

/// How much of the library the server has measured.
///
/// Measurement is lazy: a track is decoded the first time something asks about
/// it, so a library nobody has played through sits at nothing measured. That is
/// correct, and it looks exactly like a fault — which is the whole reason this
/// is on a screen.
struct AnalysisCoverage: Decodable, Equatable, Sendable {
    var tracks: Int
    var soundBounds: Int
    var audioAnalysis: Int
    var beatGrids: Int
    /// Of the measured ones, how many actually have a grid. The gap is not a
    /// backlog: a spoken-word track decoded and found to have no beat is
    /// finished, and counting it as outstanding would mean never reaching the
    /// end.
    var gridded: Int
    /// Queued or decoding right now. Zero with work outstanding means nothing is
    /// asking, rather than something being stuck.
    var measuring: Int
    var sweepEnabled: Bool
    var summary: String
}

extension BeatGridSync {
    /// Asks the server how far it has got. Nil from a server too old to answer.
    func coverage() async -> AnalysisCoverage? {
        guard let client = AppSession.shared.client else { return nil }
        do {
            return try JSONDecoder().decode(AnalysisCoverage.self, from: try await client.analysisCoverage())
        } catch {
            return nil
        }
    }
}


/// What each track is made of, as the sidecar measured it. See `docs/arrangement.md`.
///
/// Fetched for the same tracks as the beat grid and for the same reason: only
/// a record this device holds can be mixed, and only a mix cares where the
/// drop is.
@MainActor
@Observable
final class ArrangementSync {
    static let shared = ArrangementSync()

    private(set) var byTrack: [String: Arrangement?] = [:]
    private var pendingUntil: [String: Date] = [:]
    private var absentUntil: Date?
    private var inFlight: Set<String> = []
    private let log = Logger(subsystem: "com.example.aoide", category: "arrangement")

    private struct Wire: Decodable {
        struct Section: Decodable {
            var startMs: Double
            var endMs: Double
            var kind: String
            var energy: Double
        }
        struct Span: Decodable {
            var startMs: Double
            var endMs: Double
        }
        struct Track: Decodable {
            var sections: [Section]
            var phraseBars: Int?
            var phraseAnchorMs: Double?
            /// Three states, and the decoder has to keep them apart: spans, an
            /// empty list, and absent — which is why this is decoded by hand.
            var vocals: [Span]?
            var vocalsWasNull: Bool

            enum CodingKeys: String, CodingKey { case sections, phraseBars, phraseAnchorMs, vocals }

            init(from decoder: any Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                sections = try c.decode([Section].self, forKey: .sections)
                phraseBars = try c.decodeIfPresent(Int.self, forKey: .phraseBars)
                phraseAnchorMs = try c.decodeIfPresent(Double.self, forKey: .phraseAnchorMs)
                vocals = try c.decodeIfPresent([Span].self, forKey: .vocals)
                vocalsWasNull = vocals == nil
            }
        }
        var arrangements: [String: Track?]
        var pending: [String]?
    }

    private init() {
        if let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode([String: Stored?].self, from: data) {
            byTrack = saved.mapValues { $0?.arrangement }
        }
    }

    func arrangement(for trackId: String) -> Arrangement? {
        (byTrack[trackId] ?? nil).flatMap { AutoDJPreference.isOn ? $0 : nil }
    }

    func prefetch(ids: [String]) {
        guard AutoDJPreference.isOn, let client = AppSession.shared.client else { return }
        if let absentUntil, absentUntil > Date() { return }
        let now = Date()
        let wanted = ids.filter { id in
            byTrack[id] == nil
                && !inFlight.contains(id)
                && (pendingUntil[id] ?? .distantPast) <= now
        }
        guard !wanted.isEmpty else { return }
        for chunk in stride(from: 0, to: wanted.count, by: 200) {
            let slice = Array(wanted[chunk..<min(chunk + 200, wanted.count)])
            inFlight.formUnion(slice)
            Task { await fetch(slice, client: client) }
        }
    }

    private func fetch(_ ids: [String], client: JellyfinClient) async {
        defer { inFlight.subtract(ids) }
        do {
            let data = try await client.arrangements(ids: ids)
            let wire = try JSONDecoder().decode(Wire.self, from: data)
            for (id, found) in wire.arrangements {
                byTrack[id] = found.map(Self.arrangement(from:))
            }
            let retryAt = Date().addingTimeInterval(120)
            for id in wire.pending ?? [] { pendingUntil[id] = retryAt }
            save()
        } catch {
            if JellyfinClient.isSidecarAbsent(error) {
                absentUntil = Date().addingTimeInterval(3_600)
                log.info("This server has no arrangements; mixes will not see the music")
            } else {
                log.warning("Couldn't fetch arrangements: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private static func arrangement(from wire: Wire.Track) -> Arrangement {
        Arrangement(
            sections: wire.sections.map {
                Arrangement.Section(
                    startMs: $0.startMs, endMs: $0.endMs,
                    kind: Arrangement.Kind(rawValue: $0.kind) ?? .unknown,
                    energy: $0.energy
                )
            },
            phraseBars: wire.phraseBars,
            phraseAnchorMs: wire.phraseAnchorMs,
            vocals: wire.vocalsWasNull ? nil : (wire.vocals ?? []).map { Arrangement.Span(startMs: $0.startMs, endMs: $0.endMs) }
        )
    }

    @ObservationIgnored private let url: URL = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("arrangements.json")
    }()

    private func save() {
        let stored = byTrack.mapValues { $0.map(Stored.init(arrangement:)) }
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private struct Stored: Codable {
        struct Section: Codable { var startMs: Double; var endMs: Double; var kind: String; var energy: Double }
        struct Span: Codable { var startMs: Double; var endMs: Double }
        var sections: [Section]
        var phraseBars: Int?
        var phraseAnchorMs: Double?
        /// Kept as a separate flag so "could not tell" survives a round trip
        /// through a file, where a missing key and a null look the same.
        var vocalsUnknown: Bool
        var vocals: [Span]

        init(arrangement: Arrangement) {
            sections = arrangement.sections.map { Section(startMs: $0.startMs, endMs: $0.endMs, kind: $0.kind.rawValue, energy: $0.energy) }
            phraseBars = arrangement.phraseBars
            phraseAnchorMs = arrangement.phraseAnchorMs
            vocalsUnknown = arrangement.vocals == nil
            vocals = (arrangement.vocals ?? []).map { Span(startMs: $0.startMs, endMs: $0.endMs) }
        }

        var arrangement: Arrangement {
            Arrangement(
                sections: sections.map { Arrangement.Section(startMs: $0.startMs, endMs: $0.endMs, kind: Arrangement.Kind(rawValue: $0.kind) ?? .unknown, energy: $0.energy) },
                phraseBars: phraseBars,
                phraseAnchorMs: phraseAnchorMs,
                vocals: vocalsUnknown ? nil : vocals.map { Arrangement.Span(startMs: $0.startMs, endMs: $0.endMs) }
            )
        }
    }
}
