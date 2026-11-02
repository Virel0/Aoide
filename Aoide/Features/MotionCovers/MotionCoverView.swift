import AVFoundation
import MeleteKit
import SwiftUI
import UIKit

/// An album's motion cover over its still cover: muted, looping, faded in once
/// it's ready. Nothing shows while it's off in Settings, with Reduce Motion or
/// Low Power Mode on, or when the album has none.
struct MotionCoverView: View {
    let albumId: String?
    var cornerRadius: CGFloat = 6

    @AppStorage(MotionCovers.enabledKey) private var isEnabled = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var file: URL?
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled

    var body: some View {
        // A clear base, not an empty group: `.task` never runs on a view with nothing in it.
        ZStack {
            Color.clear
            if let file, isEnabled, !reduceMotion, !lowPower {
                LoopingVideo(file: file)
                    .clipShape(.rect(cornerRadius: cornerRadius))
                    .transition(.opacity)
            }
        }
        .animation(.easeIn(duration: 0.4), value: file)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: albumId) {
            file = nil
            guard let albumId, isEnabled, let client = AppSession.shared.client else { return }
            file = await MotionCovers.shared.file(forAlbum: albumId, client: client)
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
            lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
    }
}

/// A muted video file played in a loop, filling its frame.
private struct LoopingVideo: UIViewRepresentable {
    let file: URL

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.play(file)
        return view
    }

    func updateUIView(_ view: PlayerView, context: Context) {
        view.play(file)
    }

    static func dismantleUIView(_ view: PlayerView, coordinator: ()) {
        view.stop()
    }

    final class PlayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        /// Always an `AVPlayerLayer`, by `layerClass`.
        private var playerLayer: AVPlayerLayer? { layer as? AVPlayerLayer }
        private var looper: AVPlayerLooper?
        private var playing: URL?

        func play(_ file: URL) {
            guard file != playing else { return }
            playing = file
            let player = AVQueuePlayer()
            // Muted and silent to the system: the music is the app's own engine,
            // and this must never take the audio session from it.
            player.isMuted = true
            player.audiovisualBackgroundPlaybackPolicy = .pauses
            player.preventsDisplaySleepDuringVideoPlayback = false
            looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: file))
            playerLayer?.videoGravity = .resizeAspectFill
            playerLayer?.player = player
            player.play()
        }

        func stop() {
            playerLayer?.player?.pause()
            playerLayer?.player = nil
            looper = nil
            playing = nil
        }
    }
}
