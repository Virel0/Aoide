import MeleteKit
import SwiftUI

/// Asking for what the library doesn't have, at the foot of Search's results: the
/// words looked up on MusicBrainz through Melete, in groups (songs, albums,
/// artists), each showing its best few with the rest a tap away. A row says what
/// it is and who by, and is marked in the library, wanted or asked for already,
/// else has Ask.
///
/// Looked up only when asked: MusicBrainz is slow and the server paces it, and a
/// lookup at every pause in typing would be both. Give it `.id(term)` so a new
/// term starts afresh.
struct AskForItSection: View {
    let term: String

    @State private var found: [RequestKind: [RequestCandidate]]?
    @State private var isLooking = false
    @State private var problem: String?
    /// The groups showing all their rows.
    @State private var expanded: Set<RequestKind> = []
    /// What asking said, by candidate: where it stands now, or why not.
    @State private var answers: [RequestCandidate: String] = [:]
    @State private var asking: RequestCandidate?

    /// Rows a group shows before "Show More".
    private static let shown = 3
    private static let order: [RequestKind] = [.song, .album, .artist]

    var body: some View {
        Section {
            if let found {
                if found.values.allSatisfy(\.isEmpty) {
                    Text("MusicBrainz has nothing by that name.")
                        .foregroundStyle(.secondary)
                }
            } else if isLooking {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Looking it up on MusicBrainz…").foregroundStyle(.secondary)
                }
            } else {
                Button("Not in your library? Look it up to ask for it", systemImage: "plus.magnifyingglass") {
                    Task { await lookUp() }
                }
            }
            if let problem {
                Text(problem).font(.footnote).foregroundStyle(.red)
            }
        } header: {
            Text("Ask for It")
        }
        if let found {
            ForEach(Self.order, id: \.self) { kind in
                if let candidates = found[kind], !candidates.isEmpty {
                    group(kind, candidates)
                }
            }
        }
    }

    private func group(_ kind: RequestKind, _ candidates: [RequestCandidate]) -> some View {
        let isExpanded = expanded.contains(kind)
        let rows = isExpanded ? candidates : Array(candidates.prefix(Self.shown))
        return Section {
            ForEach(rows, id: \.self) { row($0) }
            if candidates.count > Self.shown {
                Button(isExpanded ? "Show Fewer" : "Show \(candidates.count - Self.shown) More") {
                    withAnimation {
                        if isExpanded { expanded.remove(kind) } else { expanded.insert(kind) }
                    }
                }
                .font(.subheadline)
            }
        } header: {
            Text(Self.heading(kind))
        }
    }

    private func row(_ candidate: RequestCandidate) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.title)
                    .fontWeight(.medium)
                    .lineLimit(1)
                if let byline = Self.byline(candidate) {
                    Text(byline)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let detail = Self.detail(candidate) {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            trailing(candidate)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func trailing(_ candidate: RequestCandidate) -> some View {
        if let answer = answers[candidate] {
            Text(answer)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 120, alignment: .trailing)
        } else if candidate.inLibrary {
            badge("In Library", systemImage: "checkmark.circle.fill")
        } else if candidate.wanted {
            badge("Wanted", systemImage: "clock")
        } else if candidate.requested != nil {
            badge("Asked For", systemImage: "paperplane")
        } else {
            Button(asking == candidate ? "Asking…" : "Ask") {
                Task { await ask(candidate) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(asking != nil)
        }
    }

    private func badge(_ words: String, systemImage: String) -> some View {
        Label(words, systemImage: systemImage)
            .labelStyle(.titleAndIcon)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private static func heading(_ kind: RequestKind) -> String {
        switch kind {
        case .song: "Songs on MusicBrainz"
        case .album: "Albums on MusicBrainz"
        case .artist, .other: "Artists on MusicBrainz"
        }
    }

    /// Who it's by, and when: "Radiohead · 1997". An artist's kind and country.
    private static func byline(_ candidate: RequestCandidate) -> String? {
        let parts: [String?] = candidate.kind == .artist
            ? [candidate.detail]
            : [candidate.artist, candidate.year.map(String.init)]
        let line = parts.compactMap { $0 }.joined(separator: " · ")
        return line.isEmpty ? nil : line
    }

    /// What tells it apart: the album a song is on, an album's type when it isn't
    /// just "Album".
    private static func detail(_ candidate: RequestCandidate) -> String? {
        guard candidate.kind != .artist, let detail = candidate.detail,
              detail.caseInsensitiveCompare(candidate.kind.word) != .orderedSame
        else { return nil }
        return detail
    }

    private func lookUp() async {
        guard let client = AppSession.shared.client else { return }
        isLooking = true
        problem = nil
        defer { isLooking = false }
        do {
            async let songs = client.requestSearch(.song, words: term)
            async let albums = client.requestSearch(.album, words: term)
            async let artists = client.requestSearch(.artist, words: term)
            found = try await [.song: songs, .album: albums, .artist: artists]
        } catch MeleteError.http(status: 409, _, _) {
            problem = "Your server can't look music up: MusicBrainz is off in its settings."
        } catch {
            problem = (error as? MeleteError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func ask(_ candidate: RequestCandidate) async {
        guard let client = AppSession.shared.client else { return }
        asking = candidate
        defer { asking = nil }
        do {
            answers[candidate] = try await client.askFor(candidate).standing
        } catch MeleteError.http(status: 409, _, let detail) {
            answers[candidate] = detail ?? "Asked for already"
        } catch {
            answers[candidate] = (error as? MeleteError)?.errorDescription ?? error.localizedDescription
        }
    }
}
