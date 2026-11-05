import Foundation
import MeleteKit
import os

/// Albums' looping videos, read once from the server and kept in Caches for a
/// week. Only MP4 and QuickTime loops are kept: AVFoundation doesn't play WebM,
/// and the still cover stands in for those.
actor MotionCovers {
    static let shared = MotionCovers()

    private static let keepFor: TimeInterval = 7 * 24 * 60 * 60

    /// What each album was found to have: the path its album gave, or nil for
    /// none (or none this phone can play), so an album is asked about once a run.
    private var known: [String: String?] = [:]
    private var inFlight: [String: Task<URL?, Never>] = [:]
    private let log = Logger(subsystem: AppIdentity.bundle, category: "motion")

    private static var directory: URL {
        URL.cachesDirectory.appending(path: "MotionCovers", directoryHint: .isDirectory)
    }

    private static func file(for albumId: String) -> URL {
        directory.appending(path: "\(albumId).mp4")
    }

    /// The album's motion cover as a file to play, or nil when it has none.
    ///
    /// The server is asked once a run whether the album still has one, even
    /// with a copy kept here: a motion cover taken away (as Melete 0.5.0 did
    /// with the ones it made from still covers) stops playing at the next
    /// launch rather than a week later. A kept copy is played without a new
    /// download, and when the server can't be reached.
    func file(forAlbum albumId: String, client: MeleteClient) async -> URL? {
        let kept = Self.kept(albumId)
        switch known[albumId] {
        case .some(.none): return nil
        case .some(.some): if let kept { return kept }
        case .none: break
        }
        if let running = inFlight[albumId] { return await running.value }
        let task = Task { await fetch(albumId, client: client, kept: kept) }
        inFlight[albumId] = task
        let found = await task.value
        inFlight[albumId] = nil
        return found
    }

    /// The copy kept for the album, if it's under a week old.
    private static func kept(_ albumId: String) -> URL? {
        let file = file(for: albumId)
        guard let made = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
              Date().timeIntervalSince(made) < keepFor
        else { return nil }
        return file
    }

    private func fetch(_ albumId: String, client: MeleteClient, kept: URL?) async -> URL? {
        let path: String?
        do {
            if let known = known[albumId] {
                path = known
            } else {
                path = try await client.album(id: albumId).album.motionCover
            }
        } catch {
            // Not remembered: a failed read says nothing about the album. The
            // kept copy plays meanwhile, as it would offline.
            log.error("Motion cover for \(albumId, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return kept
        }
        guard let path else {
            known[albumId] = .some(nil)
            try? FileManager.default.removeItem(at: Self.file(for: albumId))
            return nil
        }
        if let kept {
            known[albumId] = path
            return kept
        }
        do {
            guard let data = try await client.motionCoverData(servedPath: path),
                  MeleteClient.isPlayableMotionCover(data)
            else {
                known[albumId] = .some(nil)
                return nil
            }
            known[albumId] = path
            try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            let file = Self.file(for: albumId)
            try data.write(to: file, options: .atomic)
            return file
        } catch {
            log.error("Motion cover for \(albumId, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
