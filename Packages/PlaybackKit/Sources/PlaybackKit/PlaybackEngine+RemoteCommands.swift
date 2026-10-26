#if os(iOS)

import MediaPlayer

// MARK: - Remote commands

extension PlaybackEngine {
    /// Wires the lock screen, headphone buttons, steering-wheel controls, and the
    /// CarPlay transport bar. All of them arrive through this one command centre.
    func configureRemoteCommands() {
        let commands = MPRemoteCommandCenter.shared()

        // These arrive from outside the app — the lock screen, a steering wheel, a
        // headphone button — and the calling thread isn't guaranteed to be main.
        // Hop to the main actor rather than asserting we're already on it.
        commands.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.resume() }
            return .success
        }
        commands.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        commands.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayPause() }
            return .success
        }
        commands.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.next() }
            return .success
        }
        commands.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previous() }
            return .success
        }
        commands.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = event.positionTime
            Task { @MainActor in self?.seek(to: .seconds(position)) }
            return .success
        }

        // Explicitly disabled: these are for podcasts and audiobooks, and leaving
        // them on puts skip-15s buttons on the CarPlay screen instead of next/prev.
        commands.skipForwardCommand.isEnabled = false
        commands.skipBackwardCommand.isEnabled = false
        commands.seekForwardCommand.isEnabled = false
        commands.seekBackwardCommand.isEnabled = false
    }
}

#endif
