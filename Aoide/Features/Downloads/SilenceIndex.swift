import Foundation
import PlaybackKit

/// Where the sound is in each downloaded file, measured once and kept.
///
/// Keyed by track rather than by file: a FLAC and the Apple Lossless copy made
/// from it hold the same samples, so one measurement serves both.
@MainActor
@Observable
final class SilenceIndex {
    static let shared = SilenceIndex()

    private(set) var bounds: [String: SilenceBounds] = [:]
    /// Tracks measured and found to need no trimming, so they are not measured again.
    private(set) var untrimmed: Set<String> = []
    /// What the server has measured, for tracks this phone streams. `nil` inside
    /// means the server looked and found nothing to trim.
    private(set) var fromServer: [String: SilenceBounds?] = [:]

    @ObservationIgnored private let url: URL = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("silence-bounds.json")
    }()

    private struct Saved: Codable {
        var bounds: [String: SilenceBounds]
        var untrimmed: [String]
        var fromServer: [String: SilenceBounds?]? = nil
    }

    private init() {
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            bounds = saved.bounds
            untrimmed = Set(saved.untrimmed)
            fromServer = saved.fromServer ?? [:]
        }
    }

    func isMeasured(_ trackId: String) -> Bool {
        bounds[trackId] != nil || untrimmed.contains(trackId)
    }

    /// This phone's own measurement first, then the server's.
    func bounds(for trackId: String) -> SilenceBounds? {
        if let own = bounds[trackId] { return own }
        if untrimmed.contains(trackId) { return nil }
        return fromServer[trackId] ?? nil
    }

    func isKnownFromServer(_ trackId: String) -> Bool { fromServer[trackId] != nil }

    func record(_ found: SilenceBounds?, for trackId: String) {
        if let found { bounds[trackId] = found; untrimmed.remove(trackId) } else { bounds[trackId] = nil; untrimmed.insert(trackId) }
        save()
        // The server can serve this without decoding the file itself.
        SoundBoundsSync.shared.upload(found, for: trackId)
    }

    func recordFromServer(_ found: SilenceBounds?, for trackId: String) {
        fromServer[trackId] = .some(found)
        save()
    }

    func remove(_ trackId: String) {
        bounds[trackId] = nil
        untrimmed.remove(trackId)
        save()
    }

    func removeAll() {
        bounds = [:]
        untrimmed = []
        try? FileManager.default.removeItem(at: url)
    }

    var measuredCount: Int { bounds.count + untrimmed.count }
    var serverCount: Int { fromServer.count }

    private func save() {
        guard let data = try? JSONEncoder().encode(Saved(bounds: bounds, untrimmed: Array(untrimmed), fromServer: fromServer)) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// The user's choice, read wherever a track is built. On by default: the
/// alternative is seconds of nothing between songs that the files happen to carry.
enum TrimSilencePreference {
    static let key = "aoide.trimSilence"
    static var isOn: Bool {
        UserDefaults.standard.object(forKey: key) == nil ? true : UserDefaults.standard.bool(forKey: key)
    }
}
