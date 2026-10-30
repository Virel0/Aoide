import CurationKit
import Foundation
import MeleteKit
import PlaybackKit
import os

/// What the server knows about where each track's sound is, and what this phone
/// tells it.
///
/// The phone measures its downloads itself; for everything it streams it asks
/// the sidecar, which measured the file once and remembers. Measurements made
/// here are sent up so the server never decodes a file this phone already has.
/// A server without the endpoint is not an error: nothing is trimmed, and it is
/// asked again in a while.
@MainActor
@Observable
final class SoundBoundsSync {
    static let shared = SoundBoundsSync()

    /// Ids the server said it has not measured yet, and when to ask again.
    private var pendingUntil: [String: Date] = [:]
    /// Ids asked for and never answered (older sidecar): asked again after this.
    private var absentUntil: Date?
    private var inFlight: Set<String> = []
    private var toUpload: [String: SilenceBounds?] = [:]
    private var uploadTask: Task<Void, Never>?
    private let log = Logger(subsystem: AppIdentity.bundle, category: "silence")

    private struct Wire: Codable {
        struct Bounds: Codable { var soundStartMs: Int64; var soundEndMs: Int64 }
        var bounds: [String: Bounds?]
        var pending: [String]?
    }

    private init() {}

    /// Makes sure the server has been asked about these tracks. Answers land in
    /// `SilenceIndex`, where the engine reads them as items are made.
    func prefetch(ids: [String]) {
        guard let client = AppSession.shared.client, TrimSilencePreference.isOn else { return }
        if let absentUntil, absentUntil > Date() { return }
        let now = Date()
        let wanted = ids.filter { id in
            !SilenceIndex.shared.isMeasured(id) && !SilenceIndex.shared.isKnownFromServer(id)
                && !inFlight.contains(id) && (pendingUntil[id] ?? .distantPast) <= now
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
            let data = try await client.soundBounds(ids: ids)
            let wire = try JSONDecoder().decode(Wire.self, from: data)
            for (id, found) in wire.bounds {
                let bounds = found.map { SilenceBounds(soundStart: .milliseconds($0.soundStartMs), soundEnd: .milliseconds($0.soundEndMs)) }
                SilenceIndex.shared.recordFromServer(bounds, for: id)
            }
            let retry = Date().addingTimeInterval(60)
            for id in wire.pending ?? [] { pendingUntil[id] = retry }
        } catch {
            if MeleteClient.isSidecarAbsent(error) {
                // Not built yet, or not this version. Asked again in ten minutes.
                absentUntil = Date().addingTimeInterval(600)
            } else {
                log.warning("Sound bounds unavailable: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Queues this phone's own measurement for the server. Sent in batches, a
    /// few seconds after the last one arrives.
    func upload(_ bounds: SilenceBounds?, for trackId: String) {
        toUpload[trackId] = bounds
        uploadTask?.cancel()
        uploadTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            await flushUploads()
        }
    }

    private func flushUploads() async {
        guard let client = AppSession.shared.client, !toUpload.isEmpty else { return }
        if let absentUntil, absentUntil > Date() { return }
        let batch = Array(toUpload.prefix(200))
        for (id, _) in batch { toUpload[id] = nil }
        let wire = Wire(
            bounds: Dictionary(uniqueKeysWithValues: batch.map { id, bounds in
                (id, bounds.map { Wire.Bounds(soundStartMs: Int64($0.soundStart.seconds * 1000), soundEndMs: Int64($0.soundEnd.seconds * 1000)) })
            }),
            pending: nil
        )
        do {
            _ = try await client.postSoundBounds(body: try JSONEncoder().encode(wire))
            log.info("Sent \(batch.count, privacy: .public) sound measurements to the server")
        } catch {
            // Best effort; the server can always measure for itself.
            if MeleteClient.isSidecarAbsent(error) { absentUntil = Date().addingTimeInterval(600) }
        }
        if !toUpload.isEmpty { await flushUploads() }
    }
}
