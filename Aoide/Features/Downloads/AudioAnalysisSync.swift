import Foundation
import MeleteKit
import PlaybackKit
import os

/// How loud each track is, as measured by the server.
///
/// The phone cannot measure a file it is streaming, and measuring a whole
/// library on a phone is not sensible even for the files it holds — so this asks
/// the sidecar, which decodes each file once and remembers. See
/// `docs/audio-analysis.md`; the arithmetic that turns a measurement into a
/// volume lives in ``LoudnessNormalisation`` and is shared with the desktop.
///
/// A server without the endpoint is not an error. Nothing is levelled, and it is
/// asked again in a while.
@MainActor
@Observable
final class AudioAnalysisSync {
    static let shared = AudioAnalysisSync()

    struct Analysis: Codable, Hashable, Sendable {
        var loudnessLufs: Double?
        var truePeakDbfs: Double?
        var bpm: Double?
        var bpmConfidence: Double?
        /// How much that one tempo describes the whole track — the fraction of
        /// twenty-second windows that agreed with it. A track that ramps from 105
        /// to 145 still reports a confident 135, and this is the number that says
        /// so. Absent from servers before 1.12.0.0.
        var bpmStability: Double?
    }

    /// Measured tracks. A `nil` inside means the server looked and had nothing
    /// to report, which is different from not having asked.
    private(set) var byTrack: [String: Analysis?] = [:]

    private var pendingUntil: [String: Date] = [:]
    private var absentUntil: Date?
    private var inFlight: Set<String> = []
    private let log = Logger(subsystem: AppIdentity.bundle, category: "loudness")

    private struct Wire: Decodable {
        var analysis: [String: Analysis?]
        var pending: [String]?
    }

    /// The cache file's generation, in its name.
    ///
    /// Sidecar 1.12.0.0 threw away every tempo it had measured itself, because
    /// the estimator that produced them was worse: it read 185 BPM as 92, and
    /// nothing would ever have re-measured those rows because a row is only
    /// re-measured when its file changes. Everything cached here came from that
    /// estimator, so it goes the same way — kept, and the numbers would be wrong
    /// for as long as the file existed.
    ///
    /// Bump this whenever a server-side measurement changes meaning. It costs one
    /// lazy re-fetch and nothing else.
    @ObservationIgnored private let url: URL = {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        // The generation before this one, from the estimator whose tempi were out
        // by an octave often enough to matter.
        for previous in ["audio-analysis.json", "audio-analysis-2.json"] {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(previous))
        }
        // Generation three: 1.15.0.0 levelled the onset signal before
        // correlating, after a loud sung passage was found deciding whole
        // tracks' tempi, and dropped its own rows so they would be taken again.
        return directory.appendingPathComponent("audio-analysis-3.json")
    }()

    private init() {
        if let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode([String: Analysis?].self, from: data) {
            byTrack = saved
        }
    }

    func analysis(for trackId: String) -> Analysis? {
        byTrack[trackId] ?? nil
    }

    /// Decibels to apply to this track, or nil to leave it alone.
    func gainDb(for trackId: String) -> Double? {
        guard LoudnessPreference.isOn, let found = analysis(for: trackId) else { return nil }
        return LoudnessNormalisation.gainDb(
            loudnessLufs: found.loudnessLufs,
            truePeakDbfs: found.truePeakDbfs
        )
    }

    /// The measured tempo, when there is one. The server reports nothing below
    /// its own confidence threshold, so an answer here is one worth having —
    /// though only for ordering and for how long to blend, never for matching
    /// beats. See `MixPlanner`.
    func tempo(for trackId: String) -> Tempo? {
        guard let bpm = analysis(for: trackId)?.bpm else { return nil }
        return Tempo(bpm: bpm, stability: analysis(for: trackId)?.bpmStability)
    }

    /// Makes sure the server has been asked about these tracks.
    func prefetch(ids: [String]) {
        guard let client = AppSession.shared.client, LoudnessPreference.isOn else { return }
        if let absentUntil, absentUntil > Date() { return }
        let now = Date()
        let wanted = ids.filter { id in
            byTrack[id] == nil && !inFlight.contains(id) && (pendingUntil[id] ?? .distantPast) <= now
        }
        guard !wanted.isEmpty else { return }
        for chunk in stride(from: 0, to: wanted.count, by: 200) {
            let slice = Array(wanted[chunk..<min(chunk + 200, wanted.count)])
            inFlight.formUnion(slice)
            Task { await fetch(slice, client: client) }
        }
    }

    private func fetch(_ ids: [String], client: MeleteClient) async {
        defer { inFlight.subtract(ids) }
        do {
            let data = try await client.audioAnalysis(ids: ids)
            let wire = try JSONDecoder().decode(Wire.self, from: data)
            for (id, found) in wire.analysis { byTrack[id] = .some(found) }
            let retry = Date().addingTimeInterval(60)
            for id in wire.pending ?? [] { pendingUntil[id] = retry }
            save()
        } catch {
            if MeleteClient.isSidecarAbsent(error) {
                // Not built yet, or an older sidecar. Asked again in ten minutes.
                absentUntil = Date().addingTimeInterval(600)
            } else {
                log.warning("Audio analysis unavailable: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    var measuredCount: Int { byTrack.count }

    private func save() {
        guard let data = try? JSONEncoder().encode(byTrack) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// Whether every record should play at the same level. On by default: a library
/// mastered across decades is otherwise a volume lottery.
enum LoudnessPreference {
    static let key = "aoide.loudnessNormalisation"
    static var isOn: Bool {
        UserDefaults.standard.object(forKey: key) == nil ? true : UserDefaults.standard.bool(forKey: key)
    }
}
