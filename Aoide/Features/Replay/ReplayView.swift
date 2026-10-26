import CurationKit
import JellyfinKit
import SwiftUI

/// Your listening, as a story: this month, this year, or all of it.
///
/// Apple calls its version Replay and Spotify calls its Wrapped; the brief calls
/// them identity objects. Ours is nearly free, because the play history is already
/// on this device and already honest about skips — and it never leaves the phone
/// to be computed.
struct ReplayView: View {
    enum Period: String, CaseIterable, Identifiable {
        case month = "This Month"
        case year = "This Year"
        case all = "All Time"
        var id: Self { self }

        var from: Millis {
            let calendar = Calendar.current
            let now = Date()
            // The start of the current month or year; a calendar that can't say
            // falls back to now rather than crashing.
            switch self {
            case .month: return (calendar.dateInterval(of: .month, for: now)?.start ?? now).millis
            case .year: return (calendar.dateInterval(of: .year, for: now)?.start ?? now).millis
            case .all: return 0
            }
        }
    }

    @Environment(LibraryStore.self) private var store
    @State private var period: Period = .year
    @State private var recap: Recap?
    @State private var topTracks: [JellyfinItem] = []
    @State private var isLoading = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Design.Spacing.shelf) {
                Picker("Period", selection: $period) {
                    ForEach(Period.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .pageMargin()

                if let recap, recap.totalPlays > 0 {
                    totals(recap)
                    if !topTracks.isEmpty { tracks }
                    if !recap.topArtists.isEmpty { artists(recap) }
                    if !recap.topAlbums.isEmpty { albums(recap) }
                    if recap.unattributedPlays > 0 {
                        Text("\(recap.unattributedPlays) plays were of songs this device no longer knows, and count only in the totals.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .pageMargin()
                    }
                } else if isLoading {
                    LoadingRow().pageMargin()
                } else {
                    ContentUnavailableView {
                        Label("Nothing to Replay Yet", systemImage: "chart.bar")
                    } description: {
                        Text("Play some music and it'll add up here.")
                    }
                    .padding(.top, 40)
                }
            }
            .padding(.vertical, 12)
        }
        .miniPlayerInset()
        .appBackground()
        .navigationTitle("Replay")
        .task(id: period) { await load() }
    }

    // MARK: - Sections

    private func totals(_ recap: Recap) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                stat("Plays", recap.totalPlays.formatted())
                stat("Hours", (Double(recap.totalMsPlayed) / 3_600_000).formatted(.number.precision(.fractionLength(0...1))))
                stat("Songs", recap.distinctTracks.formatted())
                stat("Artists", recap.distinctArtists.formatted())
            }
            if let day = recap.busiestDay, let date = Self.dayFormatter.date(from: day.day) {
                Text("Busiest day: \(date.formatted(date: .abbreviated, time: .omitted)), \(day.playCount) plays.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .pageMargin()
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.title.weight(.semibold).monospacedDigit())
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .tracking(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: Design.Radius.thumbnail + 4, style: .continuous))
    }

    private var tracks: some View {
        VStack(alignment: .leading, spacing: 8) {
            PlainShelfHeader(title: "Top Songs").pageMargin()
            LazyVStack(spacing: 0) {
                ForEach(topTracks) { track in
                    SongRow(song: track)
                        .contentShape(.rect)
                        .onTapGesture {
                            guard let index = topTracks.firstIndex(of: track) else { return }
                            store.play(topTracks, startingAt: index)
                        }
                        .padding(.vertical, 4)
                }
            }
            .pageMargin()
        }
    }

    private func artists(_ recap: Recap) -> some View {
        ranked("Top Artists", recap.topArtists.map { ($0.artist, $0.playCount) })
    }

    private func albums(_ recap: Recap) -> some View {
        ranked("Top Albums", recap.topAlbums.map { ("\($0.album) · \($0.artist)", $0.playCount) })
    }

    private func ranked(_ title: String, _ rows: [(String, Int)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            PlainShelfHeader(title: title).pageMargin()
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    HStack(spacing: 12) {
                        Text("\(index + 1)")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 22, alignment: .trailing)
                        Text(row.0).lineLimit(1)
                        Spacer(minLength: 8)
                        Text("\(row.1) play\(row.1 == 1 ? "" : "s")")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 7)
                }
            }
            .pageMargin()
        }
    }

    // MARK: - Loading

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        guard let db = CurationDatabase.shared else { recap = nil; return }
        let from = period.from
        let computed = try? await Task.detached { try db.recap(from: from, to: Millis.max) }.value
        recap = computed
        guard let computed, !computed.topTracks.isEmpty else { topTracks = []; return }
        let ids = computed.topTracks.map(\.jellyfinId)
        let items = (try? await store.items(ids: ids)) ?? []
        let byId = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // In rank order, not the server's.
        topTracks = ids.compactMap { byId[$0] }
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
