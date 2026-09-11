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

                PlayerArtwork(track: track, mixState: engine.mixState, outgoing: engine.outgoingTrack, cornerRadius: 10)
                    .padding(.horizontal, 32)
                    .shadow(color: .black.opacity(0.25), radius: 20, y: 10)
                    // The cover shrinks while paused, the way Apple Music does.
                    .scaleEffect(engine.state.isPlaying ? 1.0 : 0.86)
                    .animation(.spring(response: 0.4, dampingFraction: 0.75), value: engine.state.isPlaying)

                Spacer(minLength: 16)

                titleBlock(track)
                MixBadge(state: engine.mixState)
                scrubber
                transportControls
                secondaryControls
                PlayerModesRow()
                    .padding(.top, 12)

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
            ScrubBar(
                elapsed: engine.elapsed.seconds,
                duration: total,
                dragPosition: $scrubPosition
            ) { position in
                engine.seek(to: .seconds(position))
            }
            // Kept as a safety net even though ScrubBar now clears the drag itself:
            // a stranded position is invisible until someone notices the bar has
            // stopped following the music, and a new track is unambiguous proof the
            // drag is over.
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
        .padding(.horizontal, 28)
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

                // Two lanes, because they mean different things: what you chose
                // yourself plays before whatever was already running resumes.
                let lane = engine.queue.lane
                let rest = engine.queue.contextUpNext
                // Captured together, deliberately. A drag delivers offsets in the
                // index space of the rows SwiftUI last rendered, so the base has to
                // come from that same evaluation — reading `queue.position` inside
                // the drop closure reads it *live*, and a track boundary during the
                // drag would then reorder the wrong entry.
                let queueOffset = (engine.queue.position ?? 0) + 1

                if !lane.isEmpty {
                    Section("Next Up") {
                        ForEach(lane) { entry in
                            QueueRow(entry: entry)
                                .contentShape(.rect)
                                .onTapGesture { engine.jump(to: entry.id) }
                        }
                        .onDelete { offsets in
                            for index in offsets { engine.remove(entryId: lane[index].id) }
                        }
                        .onMove { source, destination in
                            engine.move(
                                fromOffsets: IndexSet(source.map { $0 + queueOffset }),
                                toOffset: destination + queueOffset
                            )
                        }
                    }
                }

                if !rest.isEmpty {
                    // The lane sits between the current track and this one, so a
                    // drag here is offset by both.
                    let restOffset = queueOffset + lane.count
                    Section(lane.isEmpty ? "Up Next" : "Then") {
                        ForEach(rest) { entry in
                            QueueRow(entry: entry)
                                .contentShape(.rect)
                                .onTapGesture { engine.jump(to: entry.id) }
                        }
                        .onDelete { offsets in
                            for index in offsets { engine.remove(entryId: rest[index].id) }
                        }
                        .onMove { source, destination in
                            engine.move(
                                fromOffsets: IndexSet(source.map { $0 + restOffset }),
                                toOffset: destination + restOffset
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
                // The same rules as the desktop's queue: reorder, remove, clear
                // what's next. Clearing leaves the playing track alone.
                if !engine.queue.upNext.isEmpty {
                    ToolbarItem(placement: .bottomBar) {
                        Button("Clear Up Next", systemImage: "xmark.circle", role: .destructive) {
                            engine.clearUpNext()
                        }
                    }
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
