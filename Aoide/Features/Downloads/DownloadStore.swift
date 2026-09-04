import Foundation
import JellyfinKit
import PlaybackKit
import os

/// Owns offline copies of tracks.
///
/// Uses a **background** `URLSession`, which is the part that matters: a foreground
/// download dies the moment the app is suspended, and downloading an album is
/// exactly the thing someone starts and then locks their phone. The system keeps
/// these running and relaunches the app to tell us they finished.
///
/// Files land in Application Support rather than Caches — the system may evict
/// Caches under disk pressure, and silently losing music someone downloaded for a
/// flight is worse than running out of space with a clear message.
@MainActor
@Observable
final class DownloadStore: NSObject {
    static let shared = DownloadStore()

    enum State: Equatable {
        case absent
        case waiting
        case downloading(fraction: Double)
        case downloaded
        case failed(String)

        var isPresent: Bool { self == .downloaded }
        var isBusy: Bool {
            switch self {
            case .waiting, .downloading: true
            default: false
            }
        }
    }

    /// Keyed by Jellyfin item id.
    private(set) var states: [String: State] = [:]

    /// Where each downloaded track actually lives, including its extension.
    /// Held in memory so resolving a local file is a dictionary lookup rather than
    /// a directory scan — the bridge asks once per track when building a queue.
    private(set) var files: [String: URL] = [:]

    private let log = Logger(subsystem: "com.example.aoide", category: "downloads")
    @ObservationIgnored private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: "com.example.aoide.downloads")
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    /// Maps a live task back to the track it is fetching.
    @ObservationIgnored private var trackForTask: [Int: String] = [:]

    /// FLAC files replaced by a converted copy but not yet deleted, because a queue
    /// still named them. See `retire(_:)`.
    @ObservationIgnored private var retiredFiles: Set<URL> = []

    private override init() {
        super.init()
        rebuildStateFromDisk()
        // Adopt anything the system was still running while we were terminated.
        Task { await adoptRunningTasks() }
    }

    // MARK: - Locations

    nonisolated private static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // Downloads are re-fetchable from the server, so they must not go into
        // iCloud backups — that would balloon a backup with replaceable data.
        var resource = URLResourceValues()
        resource.isExcludedFromBackup = true
        var mutable = base
        try? mutable.setResourceValues(resource)
        return base
    }()

    /// One file per track, **with the container's extension**.
    ///
    /// The extension is not cosmetic: AVFoundation works out how to decode a local
    /// file from it, and a file saved without one cannot be opened at all. Saving
    /// extensionless made every download silently unplayable.
    nonisolated static func fileURL(for trackId: String, extension ext: String) -> URL {
        directory.appendingPathComponent(trackId, isDirectory: false)
            .appendingPathExtension(ext)
    }

    /// The local copy, if there is one. Main-actor because it reads the in-memory
    /// index; the bridge that calls it is main-actor too.
    static func localURLIfPresent(for trackId: String) -> URL? {
        shared.files[trackId]
    }

    /// Works out the container from what the server actually sent.
    ///
    /// Guessing from the request would be wrong — `/Audio/{id}/universal` decides
    /// server-side whether to hand back the original file or a transcode.
    nonisolated static func fileExtension(for response: URLResponse?) -> String {
        if let suggested = response?.suggestedFilename {
            let ext = (suggested as NSString).pathExtension
            if !ext.isEmpty { return ext.lowercased() }
        }
        return switch response?.mimeType?.lowercased() {
        case "audio/flac", "audio/x-flac": "flac"
        case "audio/mpeg", "audio/mp3", "audio/x-mp3": "mp3"
        case "audio/mp4", "audio/m4a", "audio/x-m4a": "m4a"
        case "audio/aac", "audio/aacp", "audio/x-aac": "aac"
        case "audio/wav", "audio/x-wav", "audio/wave": "wav"
        case "audio/aiff", "audio/x-aiff": "aiff"
        case "audio/ogg", "audio/opus": "ogg"
        // m4a is the safest fallback: it is what the server transcodes to, and
        // AVFoundation opens it without complaint.
        default: "m4a"
        }
    }

    func state(for trackId: String) -> State {
        states[trackId] ?? .absent
    }

    // MARK: - Starting and stopping

    func download(_ items: [JellyfinItem], client: JellyfinClient) {
        for item in items where item.type == .audio {
            download(item, client: client)
        }
    }

    func download(_ item: JellyfinItem, client: JellyfinClient) {
        guard item.type == .audio else { return }
        guard state(for: item.id) == .absent || isFailed(item.id) else { return }

        // Always lossless for a download. A bitrate ceiling would make the server
        // transcode, so the file kept forever would be worse than the source — and
        // it would arrive with a gap between tracks that no later fix can remove.
        guard let url = try? client.streamURL(for: item.id, quality: .lossless) else {
            states[item.id] = .failed("Couldn't work out where to fetch this from.")
            return
        }

        let task = session.downloadTask(with: url)
        trackForTask[task.taskIdentifier] = item.id
        states[item.id] = .waiting
        task.resume()

        // Cover and lyrics ride along with the audio. They are fetched on a plain
        // session rather than the background one: both are small enough to finish
        // inside a foreground window, and a background transfer per cover would
        // queue behind the multi-megabyte audio it exists to decorate.
        Task { await OfflineAssets.shared.cache([item], client: client) }
    }

    func cancelDownload(_ trackId: String) {
        Task {
            let tasks = await session.allTasks
            for task in tasks where trackForTask[task.taskIdentifier] == trackId {
                task.cancel()
            }
            states[trackId] = .absent
        }
    }

    func remove(_ trackId: String) {
        if let url = files[trackId] { try? FileManager.default.removeItem(at: url) }
        files[trackId] = nil
        states[trackId] = .absent
        OfflineAssets.shared.remove(trackId: trackId)
    }

    func removeAll() {
        try? FileManager.default.removeItem(at: Self.directory)
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        files = [:]
        states = states.mapValues { _ in .absent }
        OfflineAssets.shared.removeAll()
    }

    // MARK: - Accounting

    var downloadedCount: Int {
        states.values.filter(\.isPresent).count
    }

    /// Bytes on disk, summed from the files themselves rather than tracked as we go
    /// — the two drift apart the moment anything is deleted outside the app.
    func diskUsage() -> Int64 {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: Self.directory,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        return contents.reduce(Int64(0)) { total, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return total + Int64(size)
        }
    }

    // MARK: - Recovery

    /// Disk is the source of truth on launch. An in-memory record would be a second
    /// truth that goes stale the moment a download finishes while we're terminated.
    private func rebuildStateFromDisk() {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: Self.directory,
            includingPropertiesForKeys: nil
        ) else { return }
        var recovered = 0
        var pendingFLAC: [(String, URL)] = []
        for url in contents {
            // A conversion the app was killed in the middle of. Its real file, if
            // any, is a sibling; this one is incomplete and wears the wrong name.
            if url.pathExtension == "converting" {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            let trackId = url.deletingPathExtension().lastPathComponent
            guard !url.pathExtension.isEmpty else {
                // Left by an earlier build that saved without an extension. Those
                // files cannot be opened by AVFoundation, so they are dead weight —
                // delete them rather than leave the track looking downloaded.
                try? FileManager.default.removeItem(at: url)
                log.notice("Removed an extensionless download that could never have played")
                continue
            }
            if url.pathExtension.lowercased() == "flac" {
                // A converted copy beside it wins; the FLAC is what it was made
                // from. Otherwise it is from before conversion existed, and gets
                // converted now — quietly, one at a time, while the app runs.
                let converted = Self.fileURL(for: trackId, extension: "m4a")
                if FileManager.default.fileExists(atPath: converted.path) {
                    try? FileManager.default.removeItem(at: url)
                    continue
                }
                pendingFLAC.append((trackId, url))
            }
            files[trackId] = url
            states[trackId] = .downloaded
            recovered += 1
        }
        log.info("Found \(recovered, privacy: .public) downloaded tracks on disk")
        if !pendingFLAC.isEmpty {
            log.info("Converting \(pendingFLAC.count, privacy: .public) FLAC downloads to Apple Lossless")
            for (trackId, url) in pendingFLAC { convertIfFLAC(trackId, at: url) }
        }
    }

    private func adoptRunningTasks() async {
        for task in await session.allTasks {
            guard let url = task.originalRequest?.url else { continue }
            // The track id is the path component before "/universal".
            let parts = url.pathComponents
            guard let index = parts.firstIndex(of: "Audio"), parts.count > index + 1 else { continue }
            let trackId = parts[index + 1]
            trackForTask[task.taskIdentifier] = trackId
            if states[trackId] != .downloaded { states[trackId] = .waiting }
        }
    }

    private func isFailed(_ trackId: String) -> Bool {
        if case .failed = state(for: trackId) { return true }
        return false
    }

    fileprivate func finish(taskId: Int, movedTo destination: URL?, error: (any Error)?) {
        guard let trackId = trackForTask.removeValue(forKey: taskId) else { return }
        if let error {
            let cancelled = (error as? URLError)?.code == .cancelled
            states[trackId] = cancelled ? .absent : .failed(error.localizedDescription)
            return
        }
        guard let destination else {
            states[trackId] = .failed("The download didn't complete.")
            return
        }
        files[trackId] = destination
        states[trackId] = .downloaded
        convertIfFLAC(trackId, at: destination)
    }

    // MARK: - Gapless

    /// FLAC downloads are rewritten as Apple Lossless once they land.
    ///
    /// Apple's FLAC decoder pads the last block of a file, which leaves a short
    /// silence between tracks mastered to run together; its ALAC decoder does not.
    /// The file is playable as FLAC from the moment it lands, so nothing waits on
    /// this — the row already says downloaded, and the next play uses whichever
    /// file is there. See ``LosslessConverter``.
    private func convertIfFLAC(_ trackId: String, at url: URL) {
        guard url.pathExtension.lowercased() == "flac" else { return }
        let target = Self.fileURL(for: trackId, extension: "m4a")
        Task(priority: .utility) {
            guard await LosslessConversionQueue.shared.convert(flac: url, to: target) else { return }
            // Removed while converting: the listener no longer wants either file.
            guard files[trackId] == url else {
                try? FileManager.default.removeItem(at: target)
                return
            }
            files[trackId] = target
            retire(url)
        }
    }

    /// Deletes a superseded file — unless something is still going to play it.
    ///
    /// A queue is built with each track's file URL baked in, and the player opens
    /// a queued file only when it gets near it. Deleting the FLAC the moment its
    /// ALAC copy landed pulled the floor out from under every queued track that
    /// named it: they failed one after another, which looked like the downloads
    /// had vanished. So a file still named by the queue waits, and is swept the
    /// next time a conversion finishes, a queue is loaded, or the app launches.
    private func retire(_ url: URL) {
        retiredFiles.insert(url)
        sweepRetired()
    }

    func sweepRetired() {
        guard !retiredFiles.isEmpty else { return }
        let inUse = Set(PlaybackEngine.shared.queue.entries.map(\.track.streamURL))
        for url in retiredFiles where !inUse.contains(url) {
            try? FileManager.default.removeItem(at: url)
            retiredFiles.remove(url)
        }
    }

    fileprivate func progress(taskId: Int, fraction: Double) {
        guard let trackId = trackForTask[taskId] else { return }
        states[trackId] = .downloading(fraction: fraction)
    }
}

// MARK: - URLSessionDownloadDelegate

extension DownloadStore: URLSessionDownloadDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // The temporary file is deleted the moment this method returns, so it has to
        // be moved here — synchronously, on this thread — rather than after a hop.
        let taskId = downloadTask.taskIdentifier
        var moved: URL?
        if let response = downloadTask.response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
           let trackId = downloadTask.originalRequest?.url?.trackIdFromStreamURL {
            let ext = DownloadStore.fileExtension(for: response)
            let destination = DownloadStore.fileURL(for: trackId, extension: ext)
            try? FileManager.default.removeItem(at: destination)
            do {
                try FileManager.default.moveItem(at: location, to: destination)
                moved = destination
            } catch {
                moved = nil
            }
        }
        let result = moved
        Task { @MainActor in
            DownloadStore.shared.finish(taskId: taskId, movedTo: result, error: nil)
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        guard let error else { return }   // success is handled above
        let taskId = task.taskIdentifier
        Task { @MainActor in
            DownloadStore.shared.finish(taskId: taskId, movedTo: nil, error: error)
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let taskId = downloadTask.taskIdentifier
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        Task { @MainActor in
            DownloadStore.shared.progress(taskId: taskId, fraction: fraction)
        }
    }
}

private extension URL {
    /// `/Audio/{itemId}/universal` — the id is the component after "Audio".
    var trackIdFromStreamURL: String? {
        let parts = pathComponents
        guard let index = parts.firstIndex(of: "Audio"), parts.count > index + 1 else { return nil }
        return parts[index + 1]
    }
}
