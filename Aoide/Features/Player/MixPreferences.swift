import Foundation
import PlaybackKit

/// AutoMix: whether one song is faded into the next.
///
/// Off by default. A crossfade is a change to how every record on the device
/// sounds, and a player that starts doing it uninvited is a player that broke.
enum AutoMixPreference {
    static let key = "aoide.autoMix"
    static var isOn: Bool { UserDefaults.standard.bool(forKey: key) }
}

/// Album lock: never mix across two consecutive tracks of one album.
///
/// On by default, and it is what makes AutoMix safe to leave on — a record that
/// was sequenced to run continuously still does.
enum AlbumLockPreference {
    static let key = "aoide.albumLock"
    static var isOn: Bool {
        UserDefaults.standard.object(forKey: key) == nil ? true : UserDefaults.standard.bool(forKey: key)
    }
}
