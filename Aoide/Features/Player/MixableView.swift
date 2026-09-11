import PlaybackKit
import SwiftUI

/// Which of your downloads can actually be mixed, and why the rest cannot.
///
/// Auto DJ refuses far more often than it fires, which is the design — but a
/// feature that silently does nothing is indistinguishable from one that is
/// broken. This is the screen that tells the difference, out of this library
/// rather than out of a description.
struct MixableView: View {
    @State private var grids = BeatGridSync.shared
    @State private var coverage: AnalysisCoverage?
    private let downloads = DownloadIndex.shared

    /// A downloaded track and what the server had to say about its beats.
    private struct Row: Identifiable {
        let id: String
        let title: String
        let artist: String
        let grid: BeatGrid?
        /// Nil grid *and* never answered for: the server has not measured it yet.
        let isPending: Bool

        var bpm: Double? { grid?.segments.first?.bpm }
        var isSteady: Bool {
            guard let grid, let segment = grid.segments.first else { return false }
            return grid.beatsPerBar != nil
                && segment.residualMs <= BeatGrid.maximumResidualMs(forBlendSeconds: 30)
                && grid.mixOutMs != nil
        }
    }

    private var rows: [Row] {
        downloads.tracks.map { item in
            let answer = grids.byTrack[item.id]
            return Row(
                id: item.id,
                title: item.name,
                artist: item.subtitle,
                grid: answer ?? nil,
                isPending: answer == nil
            )
        }
    }

    var body: some View {
        let rows = rows
        let mixable = rows.filter(\.isSteady)
        let refused = rows.filter { !$0.isSteady && !$0.isPending }
        let pending = rows.filter(\.isPending)

        List {
            if let coverage {
                Section {
                    LabeledContent("Measured", value: "\(coverage.beatGrids) of \(coverage.tracks)")
                    LabeledContent("With a beat", value: "\(coverage.gridded)")
                    if coverage.measuring > 0 {
                        LabeledContent("Measuring now", value: "\(coverage.measuring)")
                    }
                } header: {
                    Text("Your Server")
                } footer: {
                    Text(coverage.sweepEnabled
                        ? "Your server measures the whole library on a schedule, so coverage climbs on its own."
                        : "Your server measures a track the first time something asks about it, so this climbs as you listen. To do the whole library at once, turn on \"Analyse the whole library nightly\" in Jellyfin's Aoide Sidecar plugin settings — the first run takes hours on a large library, which is why it is off by default.")
                }
            }

            Section {
                LabeledContent("Downloaded", value: "\(rows.count)")
                LabeledContent("Can be mixed", value: "\(mixable.count)")
                if !pending.isEmpty {
                    LabeledContent("Not measured yet", value: "\(pending.count)")
                }
            } header: {
                Text("On This Phone")
            } footer: {
                Text("Two tracks mix only if both are here, their tempi are within six per cent of each other — counting half and double as a match — and there is room in each for sixteen bars. Everything else crossfades. Your server measures a track's beats the first time anything asks about it, so a fresh download takes a moment to appear.")
            }

            if !mixable.isEmpty {
                Section("Ready to Mix") {
                    ForEach(mixable.sorted { ($0.bpm ?? 0) < ($1.bpm ?? 0) }) { row in
                        MixableRow(title: row.title, artist: row.artist, detail: detail(for: row))
                    }
                }
            }

            if !refused.isEmpty {
                Section {
                    ForEach(refused) { row in
                        MixableRow(title: row.title, artist: row.artist, detail: reason(for: row))
                    }
                } header: {
                    Text("Not Mixable")
                } footer: {
                    Text("A track needs a steady tempo and a clear four to the bar. Live recordings, anything that speeds up or slows down, and music without a beat to find are all normal answers here — they crossfade instead.")
                }
            }
        }
        .navigationTitle("What Can Be Mixed")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            BeatGridSync.shared.prefetch(ids: downloads.tracks.map(\.id))
            ArrangementSync.shared.prefetch(ids: downloads.tracks.map(\.id))
            coverage = await BeatGridSync.shared.coverage()
        }
        .refreshable {
            coverage = await BeatGridSync.shared.coverage()
        }
    }

    private func detail(for row: Row) -> String {
        var parts: [String] = []
        if let bpm = row.bpm { parts.append("\(Int(bpm.rounded())) BPM") }
        if let key = row.grid?.key { parts.append(key) }
        return parts.joined(separator: " · ")
    }

    private func reason(for row: Row) -> String {
        guard let grid = row.grid else { return "No beat found" }
        if grid.beatsPerBar == nil { return "No steady bar" }
        if grid.segments.count > 1 { return "Tempo changes" }
        if let segment = grid.segments.first,
           segment.residualMs > BeatGrid.maximumResidualMs(forBlendSeconds: 30) {
            return "Loose timing · \(Int(segment.residualMs.rounded()))ms off its own grid"
        }
        return "No mix points"
    }
}

private struct MixableRow: View {
    let title: String
    let artist: String
    let detail: String

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1)
                Text(artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}
