import PlaybackKit
import SwiftUI

/// Full-screen Now Playing: cover, scrubber, transport, and the queue.
struct NowPlayingView: View {
    @State private var engine = PlaybackEngine.shared
    @Environment(\.dismiss) private var dismiss

    /// While a drag is in progress the scrubber has to follow the finger, not the
    /// player — otherwise every time update yanks the thumb back.
    @State private var scrubPosition: Double?
    @State private var isShowingQueue = false
    @State private var sharePlay = SharePlayCoordinator.shared
    @State private var isShowingLyrics = false

    @Environment(LyricsStore.self) private var lyricsStore

    private var track: Track? { engine.currentTrack }

    var body: some View {
        VStack(spacing: 0) {
            grabber

            if let track {
                Spacer(minLength: 8)

                ArtworkView(url: track.artworkURL, cornerRadius: 10)
                    .padding(.horizontal, 32)
                    .shadow(color: .black.opacity(0.25), radius: 20, y: 10)
                    // The cover shrinks while paused, the way Apple Music does.
                    .scaleEffect(engine.state.isPlaying ? 1.0 : 0.86)
                    .animation(.spring(response: 0.4, dampingFraction: 0.75), value: engine.state.isPlaying)

                Spacer(minLength: 16)

                titleBlock(track)
                scrubber
                transportControls
                secondaryControls

                Spacer(minLength: 8)
            } else {
                Spacer()
                ContentUnavailableView("Nothing Playing", systemImage: "music.note")
                Spacer()
            }
        }
        .padding(.bottom, 16)
        .presentationDragIndicator(.hidden)
        .sheet(isPresented: $isShowingQueue) {
            QueueView()
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $isShowingLyrics) {
            // Same environment boundary as above — carried across explicitly.
            LyricsView()
                .environment(lyricsStore)
        }
        .task(id: track?.id) {
            // Loading here rather than on demand is what lets the lyrics button
            // know whether to appear at all.
            guard let id = track?.id else { return }
            await lyricsStore.load(trackId: id)
        }
    }

    private var grabber: some View {
        Capsule()
            .fill(.secondary.opacity(0.5))
            .frame(width: 36, height: 5)
            .padding(.top, 8)
            .padding(.bottom, 4)
    }

    private func titleBlock(_ track: Track) -> some View {
        VStack(spacing: 2) {
            Text(track.title)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
            Text(track.artist)
                .font(.title3)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 12)
    }

    // MARK: - Scrubber

    private var scrubber: some View {
        let total = engine.duration?.seconds ?? 0
        let current = scrubPosition ?? engine.elapsed.seconds

        return VStack(spacing: 2) {
            Slider(
                value: Binding(
                    get: { min(current, max(total, 0.01)) },
                    set: { scrubPosition = $0 }
                ),
                in: 0...max(total, 0.01),
                onEditingChanged: { editing in
                    // Commit only when the finger lifts. Seeking continuously during
                    // the drag would stutter a network stream badly.
                    if !editing, let position = scrubPosition {
                        engine.seek(to: .seconds(position))
                        scrubPosition = nil
                    }
                }
            )
            .disabled(total <= 0)
            // `scrubPosition` overrides the engine's position while it is set, so
            // anything that leaves it set strands the scrubber: it stops following
            // playback and keeps reporting the spot the finger left, even after the
            // song changes. SwiftUI does not guarantee the `false` edit callback —
            // a drag interrupted by the sheet, or by this Slider being rebuilt
            // mid-gesture, simply never delivers it. A new track is unambiguous
            // proof the drag is over, so clear it there rather than trusting the
            // callback to be the only way out.
            .onChange(of: engine.currentTrack?.id) { scrubPosition = nil }

            HStack {
                Text(Duration.seconds(current).clockDescription)
                Spacer()
                Text(total > 0 ? "-" + Duration.seconds(max(total - current, 0)).clockDescription : "--:--")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 32)
    }

    // MARK: - Controls

    private var transportControls: some View {
        HStack(spacing: 44) {
            Button { engine.previous() } label: {
                Image(systemName: "backward.fill")
            }
            Button { engine.togglePlayPause() } label: {
                Image(systemName: engine.state.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 44))
                    .frame(width: 60, height: 60)
            }
            Button { engine.next() } label: {
                Image(systemName: "forward.fill")
            }
        }
        .font(.system(size: 30))
        .foregroundStyle(.primary)
        .buttonStyle(.plain)
        .padding(.vertical, 20)
    }

    private var secondaryControls: some View {
        HStack {
            Button {
                engine.setShuffled(!engine.isShuffled)
            } label: {
                Image(systemName: "shuffle")
                    .foregroundStyle(engine.isShuffled ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            }

            Spacer()

            if let trackId = track?.id, lyricsStore.mayHaveLyrics(trackId) {
                Button {
                    isShowingLyrics = true
                } label: {
                    Image(systemName: "quote.bubble")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            // Sized explicitly: AVRoutePickerView is a UIKit view with its own
            // intrinsic size, and left alone it lays out taller than the SF Symbols
            // beside it and pushes the whole row off centre.
            RoutePickerButton()
                .frame(width: 28, height: 28)
                .accessibilityLabel("AirPlay")

            Spacer()

            if sharePlay.isEligible {
                Button {
                    Task { await sharePlay.start() }
                } label: {
                    Image(systemName: "shareplay")
                        .foregroundStyle(sharePlay.isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                }
                .accessibilityLabel(sharePlay.isActive ? "Listening together" : "Start SharePlay")

                Spacer()
            }

            Button {
                isShowingQueue = true
            } label: {
                Image(systemName: "list.bullet")
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                engine.repeatMode = engine.repeatMode.next
            } label: {
                Image(systemName: engine.repeatMode == .one ? "repeat.1" : "repeat")
                    .foregroundStyle(engine.repeatMode == .off ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
            }
        }
        .font(.title3)
        .buttonStyle(.plain)
        .padding(.horizontal, 40)
    }
}

/// Up Next, reorderable and swipe-to-delete.
struct QueueView: View {
    @State private var engine = PlaybackEngine.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let current = engine.queue.current {
                    Section("Now Playing") {
                        QueueRow(entry: current)
                    }
                }

                let upNext = engine.queue.upNext
                // Captured together, deliberately. A drag delivers offsets in the
                // index space of the rows SwiftUI last rendered, so `offset` has to
                // come from that same evaluation — reading `queue.position` inside
                // the drop closure reads it *live*, and a track boundary during the
                // drag would then reorder the wrong entry.
                let queueOffset = (engine.queue.position ?? 0) + 1
                if !upNext.isEmpty {
                    Section("Up Next") {
                        ForEach(upNext) { entry in
                            QueueRow(entry: entry)
                                .contentShape(.rect)
                                .onTapGesture { engine.jump(to: entry.id) }
                        }
                        .onDelete { offsets in
                            // `offsets` index into Up Next, but the engine works in
                            // whole-queue terms — map through the entry ids.
                            for index in offsets {
                                engine.remove(entryId: upNext[index].id)
                            }
                        }
                        .onMove { source, destination in
                            engine.move(
                                fromOffsets: IndexSet(source.map { $0 + queueOffset }),
                                toOffset: destination + queueOffset
                            )
                        }
                    }
                }
            }
            .navigationTitle("Queue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { EditButton() }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct QueueRow: View {
    let entry: QueueEntry

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(url: entry.track.artworkURL, cornerRadius: 4)
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.track.title).lineLimit(1)
                Text(entry.track.artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

extension RepeatMode {
    /// Cycles the way the button implies: off → all → one → off.
    var next: RepeatMode {
        switch self {
        case .off: .all
        case .all: .one
        case .one: .off
        }
    }
}
