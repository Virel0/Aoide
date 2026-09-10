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

    /// Asks about tracks this device holds. Anything streamed is skipped, since
    /// a grid could not be used for it.
    func prefetch(ids: [String]) {
        guard AutoDJPreference.isOn, let client = AppSession.shared.client else { return }
        if let absentUntil, absentUntil > Date() { return }
        let now = Date()
        let wanted = ids.filter { id in
            DownloadStore.localURLIfPresent(for: id) != nil
                && byTrack[id] == nil
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

    @ObservationIgnored private let url: URL = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("beat-grids.json")
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
    static var isOn: Bool { UserDefaults.standard.bool(forKey: key) }
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
