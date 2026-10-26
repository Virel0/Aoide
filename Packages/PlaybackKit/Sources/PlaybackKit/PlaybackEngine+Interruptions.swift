#if os(iOS)

import AVFoundation
import Foundation

// MARK: - Interruptions and route changes

extension PlaybackEngine {
    func observeAudioSessionEvents() {
        let center = NotificationCenter.default

        // `Notification` isn't `Sendable`, so the raw values are pulled out here —
        // in the observer, which the `.main` queue already runs on the main thread —
        // and only plain integers cross into the actor-isolated handler.

        // Phone calls, Siri, alarms.
        center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let typeRaw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let optionsRaw = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            MainActor.assumeIsolated {
                self?.handleInterruption(typeRaw: typeRaw, optionsRaw: optionsRaw)
            }
        }

        // An AVAudioEngine stops itself when the hardware underneath it changes —
        // a different output, a different sample rate — and does not start again
        // on its own. Nothing else in the engine needs to know, because nothing
        // else is an `AVAudioEngine`; without it, plugging in headphones mid-mix
        // is silence until the next track.
        center.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.restartDecksAfterConfigurationChange()
            }
        }

        // Headphones unplugged, Bluetooth disconnected, leaving the car.
        center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let reasonRaw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            MainActor.assumeIsolated {
                self?.handleRouteChange(reasonRaw: reasonRaw)
            }
        }
    }

    private func handleInterruption(typeRaw: UInt?, optionsRaw: UInt) {
        guard let typeRaw, let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }

        switch type {
        case .began:
            // Read before pausing, which clears it.
            wasPlayingWhenInterrupted = state.isPlaying || intendsToPlay
            pause()
            // The system tears the engine down under an interruption, so what is
            // resumed later has to be a *started* engine. Stopping it here makes
            // that explicit rather than leaving a graph that looks alive.
            if isUsingDecks { djMixer?.stop() }
        case .ended:
            // The session is ours again only once we say so; `resume()` does it
            // too, but the flag may say not to resume and the next deliberate tap
            // should still find a live session.
            activateSession()
            let systemSaysResume = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
                .contains(.shouldResume)
            let resuming = InterruptionPolicy.shouldResume(
                systemSaysResume: systemSaysResume,
                wasPlayingWhenInterrupted: wasPlayingWhenInterrupted
            )
            log.info("Interruption ended: system says resume=\(systemSaysResume, privacy: .public), was playing=\(self.wasPlayingWhenInterrupted, privacy: .public), resuming=\(resuming, privacy: .public)")
            wasPlayingWhenInterrupted = false
            guard restartDecksAfterInterruption(resuming: resuming) else { return }
            if resuming { resume() }
        @unknown default:
            break
        }
    }

    /// Starts the decks' engine again, if they have the record. Returns false
    /// when it would not start and the record was handed back to the player.
    private func restartDecksAfterInterruption(resuming: Bool) -> Bool {
        guard isUsingDecks else { return true }
        do {
            try djMixer?.start()
            return true
        } catch {
            // Silence is the one outcome worth avoiding: hand the record
            // back to the player, which knows how to complain.
            log.error("Couldn't restart the decks after an interruption: \(error.localizedDescription, privacy: .public)")
            stopDecks()
            if let track = queue.currentTrack { beginOnPlayer(track, autoplay: resuming) }
            return false
        }
    }

    /// Puts the decks back together after the hardware changed underneath them.
    ///
    /// A record cannot be resumed exactly where it was through a restart, so it
    /// is restarted from where the session says it had reached — which is the
    /// same thing the listener would expect from a device they just plugged in.
    private func restartDecksAfterConfigurationChange() {
        guard isUsingDecks, let session = djSession, let mixer = djMixer else { return }
        let position = session.position(at: djClock())
        let wasPlaying = state.isPlaying
        log.info("The output changed under the decks; restarting at \(position, privacy: .public)s")
        do {
            mixer.stop()
            try mixer.start()
            try session.seek(to: position, at: djClock())
            if !wasPlaying { session.pause(at: djClock()) }
        } catch {
            log.error("Couldn't restart the decks: \(error.localizedDescription, privacy: .public)")
            stopDecks()
            if let track = queue.currentTrack { beginOnPlayer(track, autoplay: wasPlaying) }
        }
    }

    /// Claims the audio session back.
    ///
    /// The category and mode are set once at launch and survive; this only says
    /// "this app wants the output again", which is the half a phone call takes
    /// away. A failure is logged rather than thrown: another app holding an
    /// exclusive session is a reason to stay quiet, not to crash a music player.
    func activateSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            log.error("Could not reclaim the audio session: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func handleRouteChange(reasonRaw: UInt?) {
        // Latency is a property of the route, so it has to be re-read on every
        // change — plugging in AirPods moves it by a couple of hundred milliseconds.
        refreshOutputLatency()

        guard let reasonRaw, let reason = AVAudioSession.RouteChangeReason(rawValue: reasonRaw) else { return }

        // The old device went away — pulled headphones, left Bluetooth range.
        // Not pausing here is how you end up blasting music from the phone speaker.
        if reason == .oldDeviceUnavailable {
            pause()
        }
    }

    func refreshOutputLatency() {
        let session = AVAudioSession.sharedInstance()
        outputLatency = session.outputLatency + session.ioBufferDuration
    }
}

#endif
