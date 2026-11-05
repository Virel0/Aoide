import Foundation
import MeleteKit
import os

/// Albums' looping videos, read once from the server and kept in Caches for a
/// week. Only MP4 and QuickTime loops are kept: AVFoundation doesn't play WebM,
/// and the still cover stands in for those.
actor MotionCovers {
    static let shared = MotionCovers()

    /// The switch in Settings; on until turned off.
    static let enabledKey = "aoide.motionCovers"
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
    func file(forAlbum albumId: String, client: MeleteClient) async -> URL? {
        let file = Self.file(for: albumId)
        if let made = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
           Date().timeIntervalSince(made) < Self.keepFor {
            return file
        }
        if let known = known[albumId], known == nil { return nil }
        if let running = inFlight[albumId] { return await running.value }
        let task = Task { await fetch(albumId, client: client) }
        inFlight[albumId] = task
        let found = await task.value
        inFlight[albumId] = nil
        return found
    }

    private func fetch(_ albumId: String, client: MeleteClient) async -> URL? {
        do {
            let path: String?
            if let known = known[albumId] {
                path = known
            } else {
                path = try await client.album(id: albumId).album.motionCover
            }
            guard let path,
                  let data = try await client.motionCoverData(servedPath: path),
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
            // Not remembered: a failed read says nothing about the album.
            log.error("Motion cover for \(albumId, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
