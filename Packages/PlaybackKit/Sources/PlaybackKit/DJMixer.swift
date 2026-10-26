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
/// player → time-pitch → high-pass → delay ─┐
///                                          ├→ main mixer → output
/// player → time-pitch → high-pass → delay ─┘
///
/// The delay is silent except for an echo-out, when the record's last beat is
/// left ringing under the first bar of the next one.
/// ```
///
/// **Time-pitch rather than varispeed**, which reverses an earlier decision here
/// and is worth explaining. Varispeed resamples, so speed and pitch move together
/// — a turntable's pitch fader, and the authentic thing. But authenticity is not
/// the goal: bending 170 BPM down to 164 is 3.7%, which takes the incoming record
/// **62 cents flat**, most of a semitone. Against a record in another key that is
/// simply out of tune, and a mix of two records out of tune with each other is
/// the thing a listener calls bad without being able to name.
///
/// So the bend preserves pitch. Apple's own AutoMix time-stretches for the same
/// reason. The cost is a processing latency, which is measured rather than
/// assumed — see ``latency`` — and is identical on both decks, so it cancels
/// between them and only matters when handing a record over from the player.
///
/// Deliberately free of `AVAudioSession` and of anything iOS-only, so the whole
/// thing can be rendered offline on a Mac and measured. See `DJMixerTests`.
public final class DJMixer {
    public enum Side: CaseIterable, Sendable {
        case a, b
    }

    /// Where the high-pass sits when a record's low end is out: kick drums and
    /// bass lines live below this, the body of a vocal does not.
    public static let bassCutHz: Float = 220
    /// And where it sits when the record is untouched — below anything a
    /// speaker reproduces, so the filter is in the chain but not in the sound.
    public static let bassOpenHz: Float = 20
    /// Where the low-pass sits when it is out of the way.
    public static let topOpenHz: Float = 20_000

    private let engine = AVAudioEngine()

    private final class Deck {
        let player = AVAudioPlayerNode()
        let speed = AVAudioUnitTimePitch()
        let shelf = AVAudioUnitEQ(numberOfBands: 2)
        let echo = AVAudioUnitDelay()
        var file: AVAudioFile?
        /// Whether this deck is meant to be sounding, as distinct from whether it
        /// happens to be paused. A deck stopped at the end of a mix must not come
        /// back when somebody presses play.
        var isRunning = false

        init() {
            // Pitch held while the speed moves. `.varispeed` would be the other
            // choice and is the one this used to make.
            speed.pitch = 0
            // A high-pass rather than the shelf this used to be. A shelf turns
            // the low end *down*; a kick's harmonics and a bass line's upper
            // notes still come through it, and two of those under each other is
            // exactly the mud the swap exists to stop. A filter takes the low
            // end *out*, and sweeping its corner across the swap is how a DJ's
            // isolator actually behaves.
            let band = shelf.bands[0]
            band.filterType = .highPass
            band.frequency = DJMixer.bassOpenHz
            band.bandwidth = 0.7
            band.bypass = false
            // And a low-pass, open until a filtered cut closes it: the
            // outgoing record's top rolled off over its last two beats, then
            // stopped — the exit for a pair that cannot be mixed and has no
            // clean word to throw.
            let top = shelf.bands[1]
            top.filterType = .lowPass
            top.frequency = DJMixer.topOpenHz
            top.bandwidth = 0.7
            top.bypass = false
            // Dry until asked. Feedback and the darkening of each repeat are
            // what make it read as an echo rather than a stutter.
            echo.wetDryMix = 0
            // Each repeat 3.1 dB under the last: the third, where the next
            // record comes in, is six down, and the seventh — a bar and a
            // half into the new record — twenty. Fading under it, not gone
            // before it.
            echo.feedback = 70
            // The repeats recede rather than stack: nothing above 3 kHz, so
            // hats and air do not pile up, and the throw reads as a voice or
            // a hit rather than the whole mix. With the high-pass after it
            // at 200 Hz, the echo is mid-only — as near to a vocal stem as a
            // deck without stems can get.
            echo.lowPassCutoff = 3_000
            echo.delayTime = 0.5
        }
    }

    private let decks: [Side: Deck] = [.a: Deck(), .b: Deck()]

    public init() {
        for side in Side.allCases {
            guard let deck = decks[side] else { continue }
            engine.attach(deck.player)
            engine.attach(deck.speed)
            engine.attach(deck.shelf)
            engine.attach(deck.echo)
            // The delay sits *before* the filter, so the filter shapes the
            // echo's repeats as well as the record: an echo-out takes the low
            // end out of the tail so the next record's bass comes in clean.
            // The delay is dry unless an echo-out is running, and a dry delay
            // is a wire, so nothing else notices the order.
            engine.connect(deck.player, to: deck.speed, format: nil)
            engine.connect(deck.speed, to: deck.echo, format: nil)
            engine.connect(deck.echo, to: deck.shelf, format: nil)
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
        // Ask each node for buffers before anything needs them. A player node
        // that starts cold reads its first blocks on the render thread's
        // deadline, which is the one place work cannot be late.
        for deck in decks.values where deck.file != nil {
            deck.player.prepare(withFrameCount: 8_192)
        }
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

    /// Every setter here refuses to write a value the unit already has.
    ///
    /// The automation runs sixty times a second and mostly asks for what is
    /// already set — the rate in particular is constant for a whole mix. Writing
    /// an audio unit's parameter is not free and is not always a no-op, so the
    /// cheapest way to avoid whatever it costs is not to do it.
    /// What the units add between a scheduled start and a sound.
    ///
    /// Constant, identical on both decks, and therefore invisible inside a mix —
    /// but it is real, and handing a record over from the ordinary player has to
    /// account for it or the two are that far apart at the crossing.
    public var latency: Double {
        guard let deck = decks[.a] else { return 0 }
        return deck.speed.auAudioUnit.latency + deck.shelf.auAudioUnit.latency
    }

    public func setRate(_ rate: Double, on side: Side) {
        guard let deck = decks[side] else { return }
        let wanted = Float(max(0.25, min(4, rate)))
        guard abs(deck.speed.rate - wanted) > 0.0001 else { return }
        deck.speed.rate = wanted
    }

    public func setVolume(_ volume: Double, on side: Side) {
        guard let deck = decks[side] else { return }
        let wanted = Float(max(0, min(1, volume)))
        guard abs(deck.player.volume - wanted) > 0.0005 else { return }
        deck.player.volume = wanted
    }

    /// Where the high-pass corner sits, in hertz. 20 is the record untouched;
    /// 220 is its bass out; 1,500 is rhythm and air.
    public func setHighPass(hz: Double, on side: Side) {
        guard let deck = decks[side], hz.isFinite else { return }
        let wanted = Float(max(Double(Self.bassOpenHz), min(4_000, hz)))
        guard abs(deck.shelf.bands[0].frequency - wanted) > 0.5 else { return }
        deck.shelf.bands[0].frequency = wanted
    }

    /// How much of the low end is out: 0 leaves the record alone, 1 takes the
    /// bass out entirely. In between, the filter's corner moves across the
    /// octaves between the two on a log scale, because that is how frequency
    /// is heard — halfway is a corner at about 66 Hz, not at 120.
    public func setBassCut(_ amount: Double, on side: Side) {
        let fraction = max(0, min(1, amount.isFinite ? amount : 0))
        setHighPass(hz: Double(Self.bassOpenHz) * pow(Double(Self.bassCutHz / Self.bassOpenHz), fraction), on: side)
    }

    /// The older shape of the same control, in decibels of a shelf that no
    /// longer exists. Kept because the automation still speaks in it; mapped
    /// onto the filter by how far down the cut the number sits.
    public func setBassDb(_ db: Double, on side: Side) {
        setBassCut(db / DJAutomation.bassCutDb, on: side)
    }

    /// Brings the echo in under a record that is still playing: the delay is
    /// set to one beat and the mix moved from dry towards wet, so the repeats
    /// build as the record itself goes. `wet` is 0…100.
    public func armEcho(_ side: Side, beatSeconds: Double, wet: Double) {
        guard let deck = decks[side] else { return }
        deck.echo.delayTime = max(0.05, min(2, beatSeconds))
        let wanted = Float(max(0, min(100, wet)))
        guard abs(deck.echo.wetDryMix - wanted) > 0.01 else { return }
        deck.echo.wetDryMix = wanted
    }

    /// Leaves a deck's last beat ringing: the dry signal is cut and the delay,
    /// set to one beat, repeats what it holds with feedback until it fades. The
    /// player is stopped at the same instant, so what rings is exactly what was
    /// playing when the cut fell — nothing after it.
    public func echoOut(_ side: Side, beatSeconds: Double) {
        guard let deck = decks[side] else { return }
        deck.echo.delayTime = max(0.05, min(2, beatSeconds))
        deck.echo.wetDryMix = 100
        deck.isRunning = false
        deck.player.stop()
    }

    /// How far into the echo a deck is, 0…100.
    public func echoWet(on side: Side) -> Double { Double(decks[side]?.echo.wetDryMix ?? 0) }

    /// Back to dry, for the next record on this deck.
    public func clearEcho(_ side: Side) {
        decks[side]?.echo.wetDryMix = 0
    }

    /// Whether a deck is meant to be sounding. The end of a mix has to leave the
    /// record that faded out actually stopped, not merely turned down: a deck at
    /// volume zero is still decoding, and still there to be resumed by the next
    /// thing that presses play.
    public func isRunning(_ side: Side) -> Bool { decks[side]?.isRunning ?? false }

    public func rate(on side: Side) -> Double { Double(decks[side]?.speed.rate ?? 1) }
    public func volume(on side: Side) -> Double { Double(decks[side]?.player.volume ?? 0) }
    /// Where the high-pass corner is, in hertz.
    public func bassCornerHz(on side: Side) -> Double { Double(decks[side]?.shelf.bands[0].frequency ?? 0) }

    /// Moves the low-pass corner. Every setter here refuses a value the unit
    /// already has, as the high-pass does.
    public func setLowPass(hz: Double, on side: Side) {
        guard let deck = decks[side], hz.isFinite else { return }
        let wanted = Float(max(100, min(Double(Self.topOpenHz), hz)))
        guard abs(deck.shelf.bands[1].frequency - wanted) > 0.5 else { return }
        deck.shelf.bands[1].frequency = wanted
    }

    /// Where the low-pass corner is, in hertz.
    public func topCornerHz(on side: Side) -> Double { Double(decks[side]?.shelf.bands[1].frequency ?? 0) }

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

    /// Why an offline render could not be set up.
    public enum RenderingFailure: Error, Equatable {
        /// No standard float format exists for this sample rate and channel count.
        case unsupportedFormat(sampleRate: Double, channels: AVAudioChannelCount)
        /// A buffer of the rendering format could not be made.
        case bufferUnavailable
    }

    /// Puts the engine into offline rendering, so a mix can be produced faster
    /// than real time and measured.
    ///
    /// The point of the whole file being platform-free: what a listener would
    /// hear is a buffer this returns, and a buffer can be asserted on.
    public func beginOfflineRendering(sampleRate: Double = 44_100, channels: AVAudioChannelCount = 2) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels) else {
            throw RenderingFailure.unsupportedFormat(sampleRate: sampleRate, channels: channels)
        }
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4_096)
    }

    /// Renders `seconds` of audio, calling `automate` with the elapsed time
    /// before each block so a mix can move while it is being rendered.
    public func renderOffline(seconds: Double, automate: (Double) -> Void = { _ in }) throws -> AVAudioPCMBuffer {
        let format = engine.manualRenderingFormat
        let total = AVAudioFrameCount(seconds * format.sampleRate)
        // A format that is not float has no float channel data; that fails here
        // too, rather than as a crash halfway through the copy.
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: total),
              let block = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: engine.manualRenderingMaximumFrameCount),
              let outputChannels = output.floatChannelData,
              let blockChannels = block.floatChannelData
        else { throw RenderingFailure.bufferUnavailable }

        while output.frameLength < total {
            automate(Double(output.frameLength) / format.sampleRate)
            let wanted = min(engine.manualRenderingMaximumFrameCount, total - output.frameLength)
            let status = try engine.renderOffline(wanted, to: block)
            guard status == .success, block.frameLength > 0 else { break }
            for channel in 0..<Int(format.channelCount) {
                let destination = outputChannels[channel] + Int(output.frameLength)
                destination.update(from: blockChannels[channel], count: Int(block.frameLength))
            }
            output.frameLength += block.frameLength
        }
        return output
    }
}
