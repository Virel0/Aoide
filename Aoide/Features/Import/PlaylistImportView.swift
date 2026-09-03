import JellyfinKit
import SwiftUI
import UniformTypeIdentifiers

/// Paste a Spotify playlist link, see what your server has and what it doesn't.
///
/// Shown as a sheet from the Playlists screen. The result is two lists rather than
/// a playlist: what matched can be saved as a local playlist in one tap, and what
/// didn't is the shopping list — copied out as text, since acquiring music is not
/// this app's business.
struct PlaylistImportView: View {
    @Environment(AppSession.self) private var session
    @Environment(LocalPlaylistStore.self) private var playlists
    @Environment(\.dismiss) private var dismiss

    @State private var importer: PlaylistImporter?
    @State private var link = ""
    @State private var isChoosingFile = false
    @State private var saved: String?
    @FocusState private var isTyping: Bool

    var body: some View {
        NavigationStack {
            List {
                inputSection
                if let importer {
                    switch importer.phase {
                    case .idle:
                        EmptyView()
                    case .reading:
                        LoadingRow()
                    case .matching(let done, let total):
                        Section {
                            ProgressView(value: Double(done), total: Double(max(total, 1))) {
                                Text("Checking your server… \(done) of \(total)")
                            }
                        }
                    case .failed(let message):
                        Section {
                            Label(message, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.secondary)
                        }
                    case .finished:
                        results(importer)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .appBackground()
            .navigationTitle("Import a Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                if let importer, importer.phase == .finished, !importer.found.isEmpty {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save \(importer.found.count)") { save(importer) }
                    }
                }
            }
            .task {
                guard importer == nil, let client = session.client else { return }
                importer = PlaylistImporter(client: client)
            }
            .fileImporter(
                isPresented: $isChoosingFile,
                allowedContentTypes: [.commaSeparatedText, .plainText, .text]
            ) { result in
                guard let importer, case .success(let url) = result else { return }
                let name = url.deletingPathExtension().lastPathComponent
                Task { await importer.importCSV(at: url, name: name) }
            }
            .alert(
                "Saved",
                isPresented: Binding(get: { saved != nil }, set: { if !$0 { saved = nil } })
            ) {
                Button("OK") { saved = nil }
            } message: {
                Text(saved ?? "")
            }
        }
    }

    private var inputSection: some View {
        Section {
            HStack {
                TextField("Spotify playlist link", text: $link)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .focused($isTyping)
                    .submitLabel(.go)
                    .onSubmit(lookUp)
                if !link.isEmpty {
                    Button("Look Up", action: lookUp)
                        .buttonStyle(.borderedProminent)
                        .disabled(importer == nil || isBusy)
                }
            }
            Button("Choose a CSV Export…", systemImage: "doc") { isChoosingFile = true }
                .disabled(importer == nil || isBusy)
        } footer: {
            Text("A link reads the playlist's first 100 tracks straight from Spotify — no account needed. For a longer playlist, export it to CSV with a tool like Exportify and choose the file.")
        }
    }

    @ViewBuilder
    private func results(_ importer: PlaylistImporter) -> some View {
        let found = importer.found
        let missing = importer.missing
        Section {
            LabeledContent("Found on your server", value: "\(found.count) of \(importer.matches.count)")
            if importer.playlist?.isTruncated == true {
                Label("Spotify only shares the first 100 tracks through a link. Export the playlist to CSV for all of it.", systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        if !missing.isEmpty {
            Section {
                ForEach(missing) { track in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title)
                        Text(track.artists.joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Button("Copy Missing as Text", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = missing
                        .map { "\($0.title) — \($0.artists.joined(separator: ", "))" }
                        .joined(separator: "\n")
                }
            } header: {
                Text("Missing (\(missing.count))")
            }
        }
        if !found.isEmpty {
            Section("Found (\(found.count))") {
                ForEach(found) { song in
                    SongRow(song: song)
                }
            }
        }
    }

    private var isBusy: Bool {
        switch importer?.phase {
        case .reading, .matching: true
        default: false
        }
    }

    private func lookUp() {
        guard let importer else { return }
        isTyping = false
        Task { await importer.importSpotify(link: link) }
    }

    private func save(_ importer: PlaylistImporter) {
        let name = importer.playlist?.name ?? "Imported playlist"
        let songs = importer.found
        Task {
            guard let created = await playlists.createPlaylist(name: name) else {
                saved = "Couldn't create the playlist."
                return
            }
            let added = await playlists.add(songs, to: created)
            saved = "“\(name)” now holds \(added) song\(added == 1 ? "" : "s")."
        }
    }
}
