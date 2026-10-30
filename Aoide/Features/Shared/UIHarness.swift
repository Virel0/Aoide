#if DEBUG
import MeleteKit
import SwiftUI

/// A scratch screen for looking at layout without a server.
///
/// Reached with the launch argument `-AoideUIHarness`. Debug-only: it exists so
/// components can be checked against real pixels rather than reasoned about, which
/// is the only way to catch things like a control that is a few points off centre.
struct UIHarness: View {
    @State private var favorite = false
    @State private var scrubElapsed: Double = 30
    @State private var scrubDrag: Double?
    @State private var isShowingScrubSheet = false

    var body: some View {
        ScrollView {
            VStack(spacing: 34) {
                sample("Album — not favourited") {
                    DetailActionRow(isFavorite: false, onLeading: {}, onPlay: {}, onTrailing: {})
                }
                sample("Album — favourited") {
                    DetailActionRow(isFavorite: true, onLeading: {}, onPlay: {}, onTrailing: {})
                }
                sample("Artist — station instead of shuffle") {
                    DetailActionRow(
                        leadingIcon: "dot.radiowaves.left.and.right",
                        leadingLabel: "Start Station",
                        trailingIcon: "shuffle",
                        trailingLabel: "Shuffle",
                        trailingFills: false,
                        onLeading: {}, onPlay: {}, onTrailing: {}
                    )
                }
                sample("Track rows — the per-song download control") {
                    VStack(spacing: 0) {
                        ForEach(UIHarness.sampleTracks) { track in
                            TrackRow(track: track, position: track.trackNumber, showsArtist: true)
                            Divider()
                        }
                    }
                }
                sample("Player secondary row — AirPlay beside SF Symbols") {
                    HStack {
                        Image(systemName: "shuffle")
                        Spacer()
                        RoutePickerButton().frame(width: 28, height: 28)
                        Spacer()
                        Image(systemName: "list.bullet")
                        Spacer()
                        Image(systemName: "repeat")
                    }
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 40)
                }
                sample("Scrub bar — in a sheet, where the old one broke") {
                    Button("Open scrub sheet") { isShowingScrubSheet = true }
                        .buttonStyle(.borderedProminent)
                }
                sample("Disabled — empty playlist") {
                    DetailActionRow(isEnabled: false, onLeading: {}, onPlay: {}, onTrailing: {})
                }
            }
            .padding(.vertical, 28)
        }
        .appBackground()
        // Presented as a sheet on purpose. The stock Slider only failed here: the
        // sheet's drag-to-dismiss recogniser cancelled its gesture, so the "editing
        // ended" callback never arrived and the bar stayed where the finger left it.
        // Testing outside a sheet would have passed against the broken version.
        .sheet(isPresented: $isShowingScrubSheet) {
            VStack(spacing: 20) {
                Text("Drag the bar, then lift").font(.headline)
                ScrubBar(elapsed: scrubElapsed, duration: 200, dragPosition: $scrubDrag) {
                    scrubElapsed = $0
                }
                .padding(.horizontal, 32)
                // The readout is the assertion: after a drag, committed must have
                // moved and dragging must read nil. A stuck drag shows up here.
                Text("committed \(Int(scrubElapsed))s · dragging \(scrubDrag.map { String(Int($0)) } ?? "nil")")
                    .font(.callout.monospaced())
                    .foregroundStyle(.tint)
            }
            .presentationDetents([.medium])
        }
    }

    static let sampleTracks: [MusicItem] = [
        MusicItem(
            id: "h1", name: "A Song With Quite a Long Title", type: .audio,
            artists: ["Someone"], trackNumber: 1, duration: .seconds(201)
        ),
        MusicItem(
            id: "h2", name: "Short One", type: .audio,
            artists: ["Someone Else"], trackNumber: 2, duration: .seconds(135)
        ),
    ]

    /// A centre line is drawn behind each row: if the capsule is off centre by even
    /// a couple of points, it shows against this immediately.
    private func sample<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tint)
                .tracking(0.6)
            content()
                .overlay(alignment: .center) {
                    Rectangle().fill(.red.opacity(0.6)).frame(width: 1)
                }
        }
        .pageMargin()
    }
}
#endif
