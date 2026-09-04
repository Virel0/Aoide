import JellyfinKit
import PlaybackKit
import SwiftUI

struct SettingsView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(LyricsStore.self) private var lyricsStore
    @Environment(AppSession.self) private var session

    @State private var isConfirmingSignOut = false
    @AppStorage("aoide.appearance") private var appearance = AppearanceMode.dark
    @AppStorage(PlaylistSurface.key) private var playlistSurface = PlaylistSurface.both
    @AppStorage(TrimSilencePreference.key) private var trimSilence = true
    @State private var silence = SilenceIndex.shared
    @State private var siri = SiriAuthorization.shared
    @State private var downloads = DownloadStore.shared

    var body: some View {
        List {
            Section("Account") {
                LabeledContent("Signed in as", value: store.accountSummary.username)
                LabeledContent("Server", value: store.accountSummary.server)
            }

            SyncSection()

            Section {
                Picker("Appearance", selection: $appearance) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Appearance")
            } footer: {
                Text("Dark by default — album artwork carries the page better against a dark ground.")
            }

            Section {
                Picker("Playlists", selection: $playlistSurface) {
                    ForEach(PlaylistSurface.allCases) { surface in
                        Text(surface.displayName).tag(surface)
                    }
                }
                .pickerStyle(.segmented)
                NavigationLink("Hidden from Mixes") { TasteFlagsView() }
            } header: {
                Text("Playlists")
            } footer: {
                Text("Which playlists the Playlists screen shows: the ones kept on your devices, the ones on your Jellyfin server, or both. Whatever's hidden is still there, under the screen's menu.")
            }

            Section {
                LabeledContent("Siri", value: siri.summary)
                if siri.status == .denied {
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                }
            } header: {
                Text("Voice")
            } footer: {
                Text("With Siri on, you can ask for music without touching your phone — \u{201C}play Boreas\u{201D}, \u{201C}shuffle my library\u{201D}.")
            }

            Section {
                LyricsOffsetRow()
            } header: {
                Text("Lyrics")
            } footer: {
                Text("Bluetooth headphones play audio slightly after the app thinks they do. Aoide corrects for this automatically, but you can nudge it if the words still run ahead or behind.")
            }

            Section {
                LabeledContent("Downloaded", value: "\(downloads.downloadedCount) tracks")
                // Covers and lyrics are stored alongside the audio, so they count
                // towards what removing everything gives back.
                LabeledContent("Storage used", value: ByteCountFormatter.string(
                    fromByteCount: downloads.diskUsage() + OfflineAssets.shared.diskUsage(),
                    countStyle: .file
                ))
                if let report = downloads.lastCheck {
                    LabeledContent("Last check", value: "\(report.checked) checked, \(report.damaged) damaged")
                }
                // Says what the files actually are. "Gapless" is only true of the
                // Apple Lossless ones, and this is how to tell whether the conversion
                // ever happened.
                LabeledContent("Formats", value: downloads.formatSummary.isEmpty ? "none" : downloads.formatSummary)
                if downloads.conversionsPending > 0 {
                    LabeledContent("Converting", value: "\(downloads.conversionsPending) waiting")
                }
                if let problem = downloads.conversionProblem {
                    Text("Conversion stopped: \(problem)")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                ForEach(downloads.conversionFailures, id: \.self) { failure in
                    Text("Couldn't convert \(failure)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Button("Check Downloads", systemImage: "stethoscope") {
                    Task { await downloads.checkFiles() }
                }
                if downloads.downloadedCount > 0 {
                    Button("Remove All Downloads", role: .destructive) {
                        downloads.removeAll()
                        DownloadIndex.shared.removeAll()
                    }
                }
            } header: {
                Text("Downloads")
            } footer: {
                Text("Downloads are always lossless, whatever the streaming quality — a file you keep shouldn't be worse than the source. They're excluded from iCloud backups, since your server already has them.")
            }

            Section {
                Toggle("Trim Silence", isOn: $trimSilence)
                LabeledContent("Measured", value: "\(silence.measuredCount) of \(downloads.downloadedCount) downloads, \(silence.serverCount) from the server")
            } header: {
                Text("Gapless")
            } footer: {
                Text("Downloads are converted to Apple Lossless so tracks run straight into each other with no stall; measured, FLAC pauses 67ms at every boundary and Apple Lossless none. Trim Silence goes further: each downloaded file is measured once for where its sound starts and stops, and only that span plays — so the seconds of nothing some recordings carry at either end are skipped. Streamed tracks are trimmed with measurements from your server, which this phone also sends its own to.")
            }

            Section {
                Button("Sign Out", role: .destructive) {
                    isConfirmingSignOut = true
                }
            }

            Section {
                LabeledContent("Version", value: Bundle.main.appVersion)
            }
        }
        .navigationTitle("Settings")
        .task { siri.refresh() }
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Sign out of Aoide?",
            isPresented: $isConfirmingSignOut,
            titleVisibility: .visible
        ) {
            Button("Sign Out", role: .destructive) {
                Task { await session.signOut() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You'll need your server address and password to sign back in.")
        }
    }
}

/// The lyric timing nudge, inline rather than buried behind another sheet — it's
/// the one setting here anyone is likely to touch twice.
private struct LyricsOffsetRow: View {
    @Environment(LyricsStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Timing")
                Spacer()
                Text(label(for: store.offset))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: Binding(
                    get: { store.offset.seconds },
                    set: { store.offset = .seconds($0) }
                ),
                in: -1.5...1.5,
                step: 0.05
            ) {
                Text("Lyrics timing")
            } minimumValueLabel: {
                Image(systemName: "backward.fill").font(.caption2)
            } maximumValueLabel: {
                Image(systemName: "forward.fill").font(.caption2)
            }
        }
        .padding(.vertical, 2)
    }

    private func label(for offset: Duration) -> String {
        let ms = Int((offset.seconds * 1000).rounded())
        if ms == 0 { return "In sync" }
        return ms > 0 ? "\(ms) ms later" : "\(-ms) ms earlier"
    }
}

extension Bundle {
    var appVersion: String {
        let short = infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }
}
