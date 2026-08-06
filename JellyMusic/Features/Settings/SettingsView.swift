import JellyfinKit
import PlaybackKit
import SwiftUI

struct SettingsView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(LyricsStore.self) private var lyricsStore
    @Environment(AppSession.self) private var session

    @State private var isConfirmingSignOut = false
    @AppStorage("jellymusic.appearance") private var appearance = AppearanceMode.dark

    var body: some View {
        List {
            Section("Account") {
                LabeledContent("Signed in as", value: store.accountSummary.username)
                LabeledContent("Server", value: store.accountSummary.server)
            }

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
                LyricsOffsetRow()
            } header: {
                Text("Lyrics")
            } footer: {
                Text("Bluetooth headphones play audio slightly after the app thinks they do. JellyMusic corrects for this automatically, but you can nudge it if the words still run ahead or behind.")
            }

            Section {
                Toggle("Gapless Playback", isOn: .constant(true))
                    .disabled(true)
            } footer: {
                Text("Tracks run straight into each other. Your library is FLAC, which Apple's decoder pads to a whole block — leaving about 57ms between tracks. Converting an album to ALAC removes it entirely.")
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
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Sign out of JellyMusic?",
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
