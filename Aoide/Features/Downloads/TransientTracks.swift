import Foundation
import PlaybackKit
import os

/// Records fetched to disk for the decks, and forgotten afterwards.
///
/// The decks read files, not streams: `AVAudioFile` opens what is on disk, and
/// a mix booked to the sample cannot stall halfway waiting for a network. That
/// used to mean Auto DJ could only follow the downloads, which made a lie of
/// Infinity choosing the record that best follows the one playing — the best
/// record is rarely the one that happens to be on the phone.
///
/// So with Auto DJ on, the next record or two in the queue are fetched here, to
/// a cache the system may reclaim, well before they are needed: a four-minute
/// lossless file over a home network arrives in seconds, and the set gives it
/// most of a track. Nothing here is a download in the listener's sense — it is
/// not listed, not kept, and gone once the queue has moved past it.
@MainActor
@Observable
final class TransientTracks {
    static let shared = TransientTracks()

    /// How many records are held at once: the one playing, the next, and the
    /// one after it. More would be a download feature by another name.
    static let capacity = 3

    private var files: [String: URL] = [:]
    private var inFlight: Set<String> = []
    private let log = Logger(subsystem: "com.example.aoide", category: "transient")

    private static let directory: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let directory = caches.appendingPathComponent("aoide-transient", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()

    private init() {
        // Anything left from a previous run belongs to a queue that no longer
        // exists.
        try? FileManager.default.removeItem(at: Self.directory)
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
    }

    /// The file for a record fetched here, if it has arrived.
    func url(for trackId: String) -> URL? {
        guard let url = files[trackId], FileManager.default.fileExists(atPath: url.path) else {
            files[trackId] = nil
            return nil
        }
        return url
    }

    /// Fetches what is coming, and lets go of what has gone.
    ///
    /// `tracks` is the queue from the current record forward. Records this
    /// device already holds as downloads are left alone; the rest, up to the
    /// capacity, are fetched if they are not here already.
    func prepare(_ tracks: [Track]) {
        guard AutoDJPreference.isOn else {
            forgetAll()
            return
        }
        let wanted = Array(tracks.prefix(Self.capacity))
        let wantedIds = Set(wanted.map(\.id))

        for (id, url) in files where !wantedIds.contains(id) {
            try? FileManager.default.removeItem(at: url)
            files[id] = nil
        }

        for track in wanted where DownloadStore.localURLIfPresent(for: track.id) == nil {
            guard files[track.id] == nil, !inFlight.contains(track.id), !track.streamURL.isFileURL else { continue }
            inFlight.insert(track.id)
            Task { await fetch(track) }
        }
    }

    private func fetch(_ track: Track) async {
        defer { inFlight.remove(track.id) }
        do {
            let (temporary, response) = try await URLSession.shared.download(from: track.streamURL)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                try? FileManager.default.removeItem(at: temporary)
                return
            }
            // The extension matters to the reader: it is how the container is
            // recognised. The server names the file it sends.
            let ext = (response.suggestedFilename as NSString?)?.pathExtension.lowercased() ?? ""
            let destination = Self.directory.appendingPathComponent("\(track.id).\(ext.isEmpty ? "flac" : ext)")
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporary, to: destination)
            files[track.id] = destination
            log.info("Fetched \(track.title, privacy: .public) for the decks")
        } catch {
            log.warning("Couldn't fetch \(track.title, privacy: .public) for the decks: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func forgetAll() {
        for url in files.values { try? FileManager.default.removeItem(at: url) }
        files = [:]
    }
}
