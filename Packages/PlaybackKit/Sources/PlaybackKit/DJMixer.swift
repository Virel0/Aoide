import AVFoundation
import Foundation

/// Two decks on one clock.
///
/// `AVQueuePlayer` cannot do this and no arrangement of it can: it decodes one
/// item at a time, its clock belongs to the item rather than to the hardware,
/// and starting it is accurate to tens of milliseconds. A beat at 128 BPM is
/// 469 ms, so a 20 ms error is a tenth of a beat — audible as a flam, and there
/// is nothing afterwards to stop the two drifting apart.
///
/// `AVAudioEngine` is the answer, and it is Apple's: every node in one engine is
/// driven by one render clock, `AVAudioTime` addresses that clock by sample, and
/// two player nodes scheduled against it start exactly where they were told to.
/// Each deck runs through a varispeed unit for the tempo bend and a low shelf for
/// the bass swap:
///
/// ```
/// player → varispeed → low shelf ─┐
///                                 ├→ main mixer → output
/// player → varispeed → low shelf ─┘
/// ```
///
/// **Varispeed rather than time-pitch, deliberately.** `AVAudioUnitTimePitch`
/// holds the pitch while changing the speed and is audibly artefacted above 1.0.
/// Varispeed simply resamples, so speed and pitch move together — which is what a
/// turntable's pitch fader does, and at the ±6% a mix ever asks for it is how
/// records have been mixed since 1975.
///
/// Deliberately free of `AVAudioSession` and of anything iOS-only, so the whole
/// thing can be rendered offline on a Mac and measured. See `DJMixerTests`.
public final class DJMixer {
    public enum Side: CaseIterable, Sendable {
        case a, b
    }

    /// Where the low shelf sits. Kick drums and bass lines live below this; the
    /// body of a vocal does not.
    public static let bassShelfHz: Float = 220

    private let engine = AVAudioEngine()

    private final class Deck {
        let player = AVAudioPlayerNode()
        let speed = AVAudioUnitVarispeed()
        let shelf = AVAudioUnitEQ(numberOfBands: 1)
        var file: AVAudioFile?
        /// Whether this deck is meant to be sounding, as distinct from whether it
        /// happens to be paused. A deck stopped at the end of a mix must not come
        /// back when somebody presses play.
        var isRunning = false

        init() {
            let band = shelf.bands[0]
            band.filterType = .lowShelf
            band.frequency = DJMixer.bassShelfHz
            band.gain = 0
            band.bypass = false
        }
    }

    private let decks: [Side: Deck] = [.a: Deck(), .b: Deck()]

    public init() {
        for side in Side.allCases {
            guard let deck = decks[side] else { continue }
            engine.attach(deck.player)
            engine.attach(deck.speed)
            engine.attach(deck.shelf)
            engine.connect(deck.player, to: deck.speed, format: nil)
            engine.connect(deck.speed, to: deck.shelf, format: nil)
            engine.connect(deck.shelf, to: engine.mainMixerNode, format: nil)
        }
    }

    // MARK: - Loading

    /// Opens a file on a deck and queues it from `seconds`.
    ///
    /// Local files only, and that is the shape of the feature rather than a gap
    /// waiting to be filled: `AVAudioFile` reads from disk, the phone already
    /// converts every download to Apple Lossless, and a mix of two tracks that
    /// might stall halfway is not a mix.
    public func load(_ url: URL, on side: Side, from seconds: Double = 0) throws {
        guard let deck = decks[side] else { return }
        let file = try AVAudioFile(forReading: url)
        deck.file = file
        deck.player.stop()
        scheduleRest(of: deck, from: seconds)
    }

    private func scheduleRest(of deck: Deck, from seconds: Double) {
        guard let file = deck.file else { return }
        let rate = file.processingFormat.sampleRate
        let start = AVAudioFramePosition(max(0, seconds) * rate)
        let remaining = AVAudioFrameCount(max(0, file.length - start))
        guard remaining > 0 else { return }
        deck.player.scheduleSegment(file, startingFrame: start, frameCount: remaining, at: nil)
    }

    // MARK: - Running

    public func start() throws {
        try engine.start()
    }

    public func stop() {
        for deck in decks.values {
            deck.isRunning = false
            deck.player.stop()
        }
        engine.stop()
    }

    /// Starts a deck as soon as the engine can.
    public func play(_ side: Side) {
        decks[side]?.isRunning = true
        decks[side]?.player.play()
    }

    /// Stops one deck and leaves the other running — the end of a mix, where the
    /// record that faded out is done and the one that came in is not.
    public func stopDeck(_ side: Side) {
        decks[side]?.isRunning = false
        decks[side]?.player.stop()
    }

    /// Both decks together, so a pause in the middle of a mix does not leave
    /// half of one audible.
    public func pauseAll() {
        for deck in decks.values { deck.player.pause() }
    }

    public func resumeAll() {
        for deck in decks.values where deck.isRunning { deck.player.play() }
    }

    /// The engine's clock, as a sample position. Nil before it has rendered
    /// anything, which is the one moment nothing can be scheduled against it.
    public var renderTime: AVAudioTime? {
        decks[.a]?.player.lastRenderTime ?? engine.outputNode.lastRenderTime
    }

    /// Starts a deck exactly `seconds` from now, on the engine's own clock.
    ///
    /// This is the whole reason for the engine: "exactly" here means to the
    /// sample, not to whenever the main thread next gets a turn.
    @discardableResult
    public func play(_ side: Side, inSeconds seconds: Double) -> AVAudioTime? {
        guard let deck = decks[side], let now = renderTime else { return nil }
        deck.isRunning = true
        let rate = now.sampleRate > 0 ? now.sampleRate : engine.outputNode.outputFormat(forBus: 0).sampleRate
        let when = AVAudioTime(sampleTime: now.sampleTime + AVAudioFramePosition(seconds * rate), atRate: rate)
        deck.player.play(at: when)
        return when
    }

    // MARK: - The controls a mix moves

    public func setRate(_ rate: Double, on side: Side) {
        decks[side]?.speed.rate = Float(max(0.25, min(4, rate)))
    }

    public func setVolume(_ volume: Double, on side: Side) {
        decks[side]?.player.volume = Float(max(0, min(1, volume)))
    }

    /// Decibels on the low shelf: 0 leaves the bass alone, negative takes it out.
    public func setBassDb(_ db: Double, on side: Side) {
        decks[side]?.shelf.bands[0].gain = Float(max(-96, min(24, db)))
    }

    /// Whether a deck is meant to be sounding. The end of a mix has to leave the
    /// record that faded out actually stopped, not merely turned down: a deck at
    /// volume zero is still decoding, and still there to be resumed by the next
    /// thing that presses play.
    public func isRunning(_ side: Side) -> Bool { decks[side]?.isRunning ?? false }

    public func rate(on side: Side) -> Double { Double(decks[side]?.speed.rate ?? 1) }
    public func volume(on side: Side) -> Double { Double(decks[side]?.player.volume ?? 0) }
    public func bassDb(on side: Side) -> Double { Double(decks[side]?.shelf.bands[0].gain ?? 0) }

    /// Applies everything a transition says about one instant of itself.
    ///
    /// Called from whatever is driving the mix — a render callback, a timer, a
    /// test — so the automation lives in one place and the driver only has to
    /// know how far through it is.
    public func apply(progress: Double, outgoing: Side, incoming: Side, transition: DJTransition) {
        setVolume(DJAutomation.outgoingGain(progress: progress), on: outgoing)
        setVolume(DJAutomation.incomingGain(progress: progress), on: incoming)
        setBassDb(DJAutomation.outgoingBassDb(progress: progress), on: outgoing)
        setBassDb(DJAutomation.incomingBassDb(progress: progress), on: incoming)
        setRate(transition.outgoingRate, on: outgoing)
        setRate(transition.incomingRate, on: incoming)
    }

    // MARK: - Rendering without a speaker

    /// Puts the engine into offline rendering, so a mix can be produced faster
    /// than real time and measured.
    ///
    /// The point of the whole file being platform-free: what a listener would
    /// hear is a buffer this returns, and a buffer can be asserted on.
    public func beginOfflineRendering(sampleRate: Double = 44_100, channels: AVAudioChannelCount = 2) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4_096)
    }

    /// Renders `seconds` of audio, calling `automate` with the elapsed time
    /// before each block so a mix can move while it is being rendered.
    public func renderOffline(seconds: Double, automate: (Double) -> Void = { _ in }) throws -> AVAudioPCMBuffer {
        let format = engine.manualRenderingFormat
        let total = AVAudioFrameCount(seconds * format.sampleRate)
        let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: total)!
        let block = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: engine.manualRenderingMaximumFrameCount)!

        while output.frameLength < total {
            automate(Double(output.frameLength) / format.sampleRate)
            let wanted = min(engine.manualRenderingMaximumFrameCount, total - output.frameLength)
            let status = try engine.renderOffline(wanted, to: block)
            guard status == .success, block.frameLength > 0 else { break }
            for channel in 0..<Int(format.channelCount) {
                let destination = output.floatChannelData![channel] + Int(output.frameLength)
                destination.update(from: block.floatChannelData![channel], count: Int(block.frameLength))
            }
            output.frameLength += block.frameLength
        }
        return output
    }
}
