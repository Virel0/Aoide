import CurationKit
import MeleteKit
import SwiftUI

/// Asking for what the library doesn't have, at the foot of Search's results: the
/// words looked up on MusicBrainz through Melete, in groups (songs, albums,
/// artists), each showing its best few with the rest a tap away. A row says what
/// it is and who by, and is marked in the library, wanted or asked for already,
/// else has Ask. A song not in the library can go in a playlist straight away,
/// waiting there until it arrives.
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
    /// Requests made here, by candidate, so adding one to a playlist after asking
    /// for it doesn't ask again.
    @State private var asked: [RequestCandidate: Int64] = [:]
    /// The song on its way into a playlist.
    @State private var adding: WaitingPick?
    @Environment(LocalPlaylistStore.self) private var playlists

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
        // Explicit: a sheet is an environment boundary.
        .sheet(item: $adding) { pick in
            AddToPlaylistSheet(title: pick.candidate.title) { store, list in
                await addWaiting(pick.candidate, to: list, in: store)
            }
            .environment(playlists)
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
            if Self.canWait(candidate) {
                Button("Add to Playlist…", systemImage: "text.badge.plus") {
                    adding = WaitingPick(candidate: candidate)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            if Self.canWait(candidate) {
                Button("Add to Playlist…", systemImage: "text.badge.plus") {
                    adding = WaitingPick(candidate: candidate)
                }
            }
        }
    }

    /// A song the library lacks that can be asked for, or has been.
    private static func canWait(_ candidate: RequestCandidate) -> Bool {
        candidate.kind == .song && !candidate.inLibrary
            && (candidate.mbRecordingId != nil || candidate.requested != nil)
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
            let request = try await client.askFor(candidate)
            asked[candidate] = request.id
            answers[candidate] = request.standing
        } catch MeleteError.http(status: 409, _, let detail) {
            answers[candidate] = detail ?? "Asked for already"
        } catch {
            answers[candidate] = (error as? MeleteError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Asks for the song unless it has been, then puts it in `list` waiting on that
    /// request. Says why in the store's message when it can't.
    private func addWaiting(_ candidate: RequestCandidate, to list: Playlist, in store: LocalPlaylistStore) async -> Bool {
        guard let requestId = await requestId(for: candidate, store: store) else { return false }
        let song = PendingSong(requestId: requestId, title: candidate.title, artist: candidate.artist)
        guard await store.addWaiting(song, to: list) else { return false }
        answers[candidate] = "Added to “\(list.name)”"
        return true
    }

    /// This user's request for the song: the open one the search found, one made
    /// here, or a new one.
    private func requestId(for candidate: RequestCandidate, store: LocalPlaylistStore) async -> Int64? {
        if let id = candidate.requested ?? asked[candidate] { return id }
        guard let client = AppSession.shared.client else { return nil }
        do {
            let request = try await client.askFor(candidate)
            asked[candidate] = request.id
            return request.id
        } catch MeleteError.http(status: 409, _, let detail) {
            // Asked for since the search: looking again finds the request.
            let again = try? await client.requestSearch(.song, words: term)
            if let id = again?.first(where: { $0.mbRecordingId == candidate.mbRecordingId })?.requested {
                asked[candidate] = id
                return id
            }
            store.lastErrorMessage = detail ?? "It couldn't be asked for."
        } catch {
            store.lastErrorMessage = (error as? MeleteError)?.errorDescription ?? error.localizedDescription
        }
        return nil
    }
}

/// A search result on its way into a playlist, for `.sheet(item:)`.
private struct WaitingPick: Identifiable {
    let id = UUID()
    let candidate: RequestCandidate
}
