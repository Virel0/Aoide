#if os(iOS)

import Foundation
import MediaPlayer
import UIKit

// MARK: - Now Playing

extension PlaybackEngine {
    /// Feeds the lock screen, the Control Center widget, and the CarPlay
    /// now-playing screen. All three read this one dictionary.
    func updateNowPlayingInfo() {
        guard let track = queue.currentTrack else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            lastArtworkTrackId = nil
            return
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyAlbumTitle: track.album,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed.seconds,
            // From the player, not our derived state. The car draws its play/pause
            // glyph from this, and anything computed from intent can disagree with
            // whether audio is actually moving — which showed as a play triangle
            // over a running track.
            MPNowPlayingInfoPropertyPlaybackRate: isUsingDecks
                ? (state.isPlaying ? 1 : 0)
                : Double(player.rate),
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyIsLiveStream: false,
        ]
        if let duration {
            info[MPMediaItemPropertyPlaybackDuration] = duration.seconds
        }
        if let trackNumber = track.trackNumber {
            info[MPMediaItemPropertyAlbumTrackNumber] = trackNumber
        }

        // Keep the artwork already on screen if it belongs to this track, so a
        // simple pause doesn't blank the cover while the image reloads.
        if let existing = MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork],
           lastArtworkTrackId == track.id {
            info[MPMediaItemPropertyArtwork] = existing
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        loadArtworkIfNeeded(for: track)
    }

    private func loadArtworkIfNeeded(for track: Track) {
        guard lastArtworkTrackId != track.id else { return }
        guard let url = track.artworkURL, let artworkLoader else {
            log.notice("No now-playing artwork: url=\(track.artworkURL != nil, privacy: .public) loader=\(self.artworkLoader != nil, privacy: .public)")
            lastArtworkTrackId = track.id
            return
        }
        lastArtworkTrackId = track.id

        Task { [weak self] in
            guard let data = await artworkLoader(url) else { return }
            guard let artwork = makeArtwork(from: data) else { return }
            await MainActor.run {
                guard let self, self.queue.currentTrack?.id == track.id else { return }
                MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork] = artwork
            }
        }
    }
}

/// Builds the artwork **outside** any actor, deliberately.
///
/// `MPMediaItemArtwork` stores its request handler and calls it later, on
/// MediaPlayer's own private queue, every time it needs the image at a new size.
/// A closure formed inside a `@MainActor` context carries that isolation with it,
/// so Swift 6's executor check trips the instant MediaPlayer invokes it — an
/// `EXC_BREAKPOINT` crash the moment a track with cover art starts playing.
/// Declaring this at file scope keeps the closure non-isolated.
private func makeArtwork(from data: Data) -> MPMediaItemArtwork? {
    guard let image = UIImage(data: data) else { return nil }
    return MPMediaItemArtwork(boundsSize: image.size) { _ in image }
}

#endif
