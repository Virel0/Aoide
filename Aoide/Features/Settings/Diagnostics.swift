import OSLog
import PlaybackKit
import SwiftUI
import UIKit

/// The app's own log, the last while of it, as a file to hand over.
///
/// Reading a phone's log otherwise needs a Mac, a cable and root — which is
/// no way to answer "what just happened?" from the sofa. The system keeps
/// every line the app has logged; this asks for the app's own, over the last
/// half hour, and puts a summary of the player's state on top: what was
/// playing, what was next, which switches were on, and where the decks
/// thought they were. Shared through the share sheet — AirDrop to a Mac,
/// Files, Messages — and nothing leaves the phone otherwise.
enum Diagnostics {
    static let window: TimeInterval = 30 * 60

    /// What the lyrics store holds for a track, in a word, set by the store.
    @MainActor static var lyricsState: ((String) -> String)?

    /// Writes the report and returns where it is.
    @MainActor
    static func write() throws -> URL {
        var report = header()
        report += "\n\n== Log, last \(Int(window / 60)) minutes ==\n"
        report += try recentLog()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Aoide diagnostics \(stamp()).txt")
        try report.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @MainActor
    private static func header() -> String {
        let engine = PlaybackEngine.shared
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        var lines: [String] = []
        lines.append("Aoide \(version) (\(build)) on iOS \(UIDevice.current.systemVersion), \(UIDevice.current.model)")
        lines.append("Written \(Date().formatted(.iso8601))")
        lines.append("")
        lines.append("Crossfade: \(engine.isCrossfading ? "on" : "off")  Auto DJ: \(engine.isAutoDJing ? "on" : "off")  Infinity: \(InfinityQueue.shared.isOn ? "on" : "off")")
        lines.append("State: \(engine.state)  mix: \(engine.mixState)")
        lines.append("Elapsed: \(engine.elapsed.seconds.formatted(.number.precision(.fractionLength(1))))s  duration: \(engine.duration.map { "\($0.seconds.formatted(.number.precision(.fractionLength(1))))s" } ?? "?")  exit: \(engine.exitAt.map { "\($0.seconds.formatted(.number.precision(.fractionLength(1))))s" } ?? "none")")
        if let track = engine.currentTrack {
            lines.append("Playing: \(track.title) — \(track.artist) [\(track.id)]")
            lines.append("  local: \(engine.localFileResolver?(track) != nil)  grid: \(engine.beatGridResolver?(track) != nil)  arrangement: \(engine.arrangementResolver?(track) != nil)  lyrics: \(lyricsState?(track.id) ?? "?")")
        }
        for (index, entry) in engine.queue.upNext.prefix(3).enumerated() {
            let track = entry.track
            lines.append("Next \(index + 1): \(track.title) — \(track.artist) [\(track.id)]")
            lines.append("  local: \(engine.localFileResolver?(track) != nil)  grid: \(engine.beatGridResolver?(track) != nil)  arrangement: \(engine.arrangementResolver?(track) != nil)  lyrics: \(lyricsState?(track.id) ?? "?")")
        }
        return lines.joined(separator: "\n")
    }

    private static func recentLog() throws -> String {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let since = store.position(date: Date().addingTimeInterval(-window))
        let predicate = NSPredicate(format: "subsystem == %@", AppIdentity.bundle)
        let entries = try store.getEntries(at: since, matching: predicate)
        let time = Date.FormatStyle(date: .omitted, time: .standard).secondFraction(.fractional(3))
        var out = ""
        for entry in entries {
            guard let log = entry as? OSLogEntryLog else { continue }
            out += "\(log.date.formatted(time)) [\(log.category)] \(level(log.level)) \(log.composedMessage)\n"
        }
        return out.isEmpty ? "(nothing logged in the window)\n" : out
    }

    private static func level(_ level: OSLogEntryLog.Level) -> String {
        switch level {
        case .error: "ERROR"
        case .fault: "FAULT"
        case .info: "info"
        case .debug: "debug"
        default: "note"
        }
    }

    private static func stamp() -> String {
        Date().formatted(Date.FormatStyle().year().month(.twoDigits).day(.twoDigits).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: ".")
    }
}

/// A button that writes the report and offers it to share.
struct ShareDiagnosticsButton: View {
    @State private var report: URL?
    @State private var problem: String?

    var body: some View {
        Group {
            if let report {
                ShareLink(item: report) {
                    Label("Share Diagnostics", systemImage: "square.and.arrow.up")
                }
            } else {
                Button("Share Diagnostics", systemImage: "doc.text.magnifyingglass") {
                    do {
                        report = try Diagnostics.write()
                    } catch {
                        problem = error.localizedDescription
                    }
                }
            }
            if let problem {
                Text("Couldn't write the report: \(problem)")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
    }
}
