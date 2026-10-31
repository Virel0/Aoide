# Changelog

Notable changes to Aoide for iPhone. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

The app isn't on the App Store; it is built from source with Xcode (or
installed through TestFlight). Versions are the app's own: 1.0 (2) is version
1.0, build 2.

## [Unreleased]

Aoide now plays from [Melete](https://github.com/Virel0/Melete), the server
that replaces Jellyfin and keeps Aoide's sync itself. Sign in again after
updating; the local store belongs to the old server and is cleared at sign-in,
and playlists, likes and history come back from Melete.

### Added
- Quick Connect: sign in by approving a code in Melete's web UI.
- Two-factor sign-in: an account with it on in Melete 0.2.0 is asked for the
  code from its authenticator app after the password.
- Albums can be liked again, with the heart on the album's page, and Library
  has Liked Albums. Album likes are their own sync record (`album_likes`),
  shared with Melete and Aoide for Linux; liking an album likes none of its
  songs.
- Listen Together, from Now Playing: start a session with your queue, or join
  one by its code, and every device in it plays in step, each streaming for
  itself. Unlike SharePlay it needs no FaceTime call, and works with Aoide for
  Linux too. Infinity holds back while in a session.

### Changed
- Searching for songs matches a song's own title and artist, so an album's
  name no longer lists every track on it (Melete 0.2.0).
- Everything the app asked of Jellyfin it asks of Melete: the library, search,
  streams, downloads, lyrics and likes. The `JellyfinKit` package is now
  `MeleteKit`.
- A stream's link is asked for when the player starts the track, so a long
  queue starts at once.
- Favourites are your liked songs.
- Covers are fetched with your sign-in.
- In Lossless, a file Apple's players can't open (Ogg, WavPack, Monkey's Audio)
  is streamed and downloaded as FLAC instead, so it plays.
- Stations and Infinity start from what `/aoide/next` picks after the seed
  song, in place of Jellyfin's Instant Mix.

### Removed
- Jellyfin playlists, importing them, and the playlist-surface setting:
  Melete's playlists are Aoide's own.
- The Rediscover shelf on Home and library scopes, which needed Jellyfin's play
  counts and libraries.
- The playback reports Jellyfin needed.

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
