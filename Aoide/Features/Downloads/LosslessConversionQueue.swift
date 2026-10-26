import Foundation
import PlaybackKit
import os

/// Converts downloaded FLAC files to Apple Lossless, one at a time.
///
/// One at a time on purpose. A download finishing is one file, but a launch that
/// finds a hundred FLAC files from before conversion existed is a hundred, and a
/// hundred encoders at once would make the phone hot for nothing — they compete
/// for the same cores and finish no sooner in total. An actor doing synchronous
/// work is the simplest serial queue there is.
actor LosslessConversionQueue {
    static let shared = LosslessConversionQueue()

    private let log = Logger(subsystem: AppIdentity.bundle, category: "downloads")

    /// Where the sound is in a file, or nil when there is nothing to trim or the
    /// file could not be read. Serial with the conversions, for the same reason.
    func measureSilence(in url: URL) -> SilenceBounds? {
        do {
            return try SilenceBounds.analyze(url)
        } catch {
            log.error("Couldn't measure \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Writes `flac` as Apple Lossless at `target`. The converter handles its own
    /// scratch file — see `LosslessConverter.scratchURL`, and why the name matters.
    /// Returns false when the conversion did not happen.
    func convert(flac: URL, to target: URL) -> String? {
        do {
            try LosslessConverter.convertFLAC(at: flac, to: target)
            return nil
        } catch {
            let reason = "\((error as NSError).localizedDescription) [\((error as NSError).domain) \((error as NSError).code)]"
            log.error("Couldn't convert \(flac.lastPathComponent, privacy: .public) to Apple Lossless: \(reason, privacy: .public)")
            return reason
        }
    }
}
