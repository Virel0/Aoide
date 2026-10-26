# Changelog

Notable changes to Aoide for iPhone. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

The app isn't on the App Store; it is built from source with Xcode (or
installed through TestFlight). Versions are the app's own: 1.0 (2) is version
1.0, build 2.

## [Unreleased]

## [1.0 (2)] - 2026-10-26

The first tagged release.

### Added
- Discover on Home: the sidecar's 30 songs of the week, with Play and Shuffle.
- Lyrics translated on the phone with Apple's Translation framework, offered
  when they aren't in the listener's language.
- Changes stay queued while the server is down and go out when it is back.
- Taste flags are erased with the account they belong to.
- README, security policy, contributing guide, issue and pull request
  templates.

### Changed
- The bundle identifier is set only in `Config/Local.xcconfig`; a clean
  checkout builds as `com.example.aoide`.
- The playback engine is split into one file per part (transport, the
  render window, crossfade, observation, interruptions, Now Playing, remote
  commands, Auto DJ), with no function over 50 lines; three other long
  functions are shortened.
- SwiftLint checks every change in CI against the project's size limits.

### Fixed
- Building an Auto DJ render buffer that the system can't create throws an
  error instead of crashing, and the last force-unwraps and `try!` outside
  tests are gone.

### Removed
- Auto DJ and the stems brief are shelved: switched off and hidden, with the
  code and tests kept. [docs/arrangement.md](docs/arrangement.md) says why and
  what would bring them back.

### In the app so far
Home, the library, playlists with folders and smart playlists, mixes and
sentence search with Apple Intelligence, downloads with FLAC converted to Apple
Lossless, Trim Silence, Crossfade, Infinity, Replay, taste flags, activity
tags, Spotify playlist import, sync with the Aoide sidecar, queue handoff,
synced lyrics, CarPlay, Siri, SharePlay and AirPlay. The README lists them in
full.
