import CarPlay
import PlaybackKit
import UIKit
import os

/// Owns the car's interface controller and the Now Playing screen.
///
/// CarPlay's Now Playing template is a system singleton — the car draws the
/// artwork, title, scrubber and transport itself from `MPNowPlayingInfoCenter` and
/// `MPRemoteCommandCenter`, both of which ``PlaybackEngine`` already feeds. All we
/// add are the buttons the system does not know about (shuffle and repeat) and the
/// Up Next list behind them.
@MainActor
final class CarPlayNowPlaying: NSObject {
    static let shared = CarPlayNowPlaying()

    private let log = Logger(subsystem: "com.example.jellymusic", category: "carplay")
    private weak var interfaceController: CPInterfaceController?

    /// Re-applied whenever playback state changes, because the button glyphs encode
    /// shuffle and repeat state and the car has no way to ask for them.
    private var stateObservation: Task<Void, Never>?

    private override init() { super.init() }

    func attach(_ controller: CPInterfaceController) {
        interfaceController = controller
        CPNowPlayingTemplate.shared.add(self)
        refreshButtons()
        observePlaybackState()
    }

    func detach() {
        stateObservation?.cancel()
        stateObservation = nil
        CPNowPlayingTemplate.shared.remove(self)
        interfaceController = nil
    }

    // MARK: - Navigation

    func push(_ template: CPTemplate) {
        guard let interfaceController else { return }
        interfaceController.pushTemplate(template, animated: true) { [weak self] ok, error in
            if let error {
                // Most often the five-level nesting limit. Worth knowing about
                // rather than looking like a dead tap.
                self?.log.error("CarPlay push failed: \(error.localizedDescription, privacy: .public)")
            }
            _ = ok
        }
    }

    /// Brings the Now Playing screen forward after the user starts something.
    func present() {
        guard let interfaceController else { return }
        guard interfaceController.topTemplate !== CPNowPlayingTemplate.shared else { return }
        interfaceController.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
    }

    // MARK: - Buttons

    /// Polls rather than observing: `PlaybackEngine` is `@Observable`, and the
    /// tracking closure would have to be re-registered after every read. At half a
    /// second this is imperceptible and costs nothing while the car is idle.
    private func observePlaybackState() {
        stateObservation?.cancel()
        stateObservation = Task { [weak self] in
            var lastSignature: String?
            while !Task.isCancelled {
                guard let self else { return }
                let engine = PlaybackEngine.shared
                let signature = "\(engine.isShuffled)-\(engine.repeatMode.rawValue)-\(engine.queue.upNext.count)"
                if signature != lastSignature {
                    lastSignature = signature
                    self.refreshButtons()
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func refreshButtons() {
        let engine = PlaybackEngine.shared
        let template = CPNowPlayingTemplate.shared

        let shuffle = CPNowPlayingShuffleButton { _ in
            MainActor.assumeIsolated {
                let engine = PlaybackEngine.shared
                engine.setShuffled(!engine.isShuffled)
            }
        }

        let repeatButton = CPNowPlayingRepeatButton { _ in
            MainActor.assumeIsolated {
                let engine = PlaybackEngine.shared
                engine.repeatMode = engine.repeatMode.next
            }
        }

        template.updateNowPlayingButtons([shuffle, repeatButton])

        // Only offer Up Next when there is something in it — an empty list behind a
        // button is worse than no button on a screen you glance at while driving.
        let upNext = engine.queue.upNext
        template.isUpNextButtonEnabled = !upNext.isEmpty
        template.upNextTitle = upNext.isEmpty ? "" : "Up Next"
        template.isAlbumArtistButtonEnabled = false
    }
}

// MARK: - Up Next

extension CarPlayNowPlaying: @preconcurrency CPNowPlayingTemplateObserver {
    // `CPNowPlayingTemplateObserver` carries no isolation, so the conformance has to
    // hop rather than assume. Asserting main-thread here would be the same mistake
    // that crashed playback once already.
    nonisolated func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        Task { @MainActor [weak self] in
            self?.showUpNext()
        }
    }

    @MainActor
    private func showUpNext() {
        let engine = PlaybackEngine.shared
        let entries = Array(engine.queue.upNext.prefix(CPListTemplate.maximumItemCount))

        let items = entries.map { entry -> CPListItem in
            let item = CPListItem(text: entry.track.title, detailText: entry.track.artist)
            if let url = entry.track.artworkURL {
                Task { [weak item] in
                    guard let image = await ArtworkCache.shared.image(for: url) else { return }
                    item?.setImage(image)
                }
            }
            item.handler = { _, completion in
                MainActor.assumeIsolated {
                    PlaybackEngine.shared.jump(to: entry.id)
                }
                completion()
            }
            return item
        }

        let template = CPListTemplate(title: "Up Next", sections: [CPListSection(items: items)])
        template.emptyViewSubtitleVariants = ["Nothing queued."]
        push(template)
    }
}
