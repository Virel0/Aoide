# Changelog

Notable changes to Aoide for iPhone. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

The app isn't on the App Store; it is built from source with Xcode (or
installed through TestFlight). Versions are the app's own: 1.0 (2) is version
1.0, build 2.

## [Unreleased]

### Changed
- Repeat after Play or Shuffle on an album, playlist, mix or artist loops all
  of it, songs you queued with Play Next or Play Last included. Before, a
  queued song made repeat loop only the first song and that one, and the rest
  of the album never came round. Tapping a song and then queuing others still
  repeats just those.

### Fixed
- Rediscover Mix and Heavy Rotation sync for every user on a server, not only
  the first to sync them. They were made under the same id for everyone, and
  Melete gives each playlist id one owner, so every other user's were refused
  (Melete#324). Each user's are now their own. On the first sync after the
  update, the old ones are moved over, keeping a name or rules you changed,
  and one you deleted stays deleted.
- The Play button on album, playlist and artist pages is centred again, with
  its play icon. In those pages' lists the icon took the button's own colour,
  so it vanished but kept its space and pushed "Play" to the right.

## [1.7 (9)] - 2026-11-06

### Added
- Your Melete account in Settings: tap "Signed in as". Choose a profile
  picture from your photos (cropped square and made small on the phone) or
  from your server's gallery, or remove it; Settings shows the new one at
  once. Change your password, which signs out your other devices and API
  keys. Turn two-factor sign-in on with an authenticator app (a link that
  hands the secret to Passwords, a QR code drawn on the phone, or the secret
  to type), turn it off, or reset it for a new device, and see its recent
  changes, with a warning when wrong codes were typed at sign-in. An admin
  can give another user a new password, shown once to pass on.

### Fixed
- A song from a YouTube playlist export that your library has under another
  artist is found instead of reported missing. When a video's title doesn't
  name its artist, the channel stands in for it, and a channel is often a
  label's ("Ubisoft Music"). Such a song is now looked up in the library by
  its title alone, and taken when every song there with exactly that title is
  by one artist; your server then puts your copy in the playlist instead of
  asking for it again.
- Heavy Rotation and Rediscover Mix fill themselves again. Aoide for Linux
  made them anew on 2 November, as two writes at one instant, and on the
  other devices the rules lost the tie: they became plain, empty playlists.
  The app now puts their rules back. It also makes the built-ins only after
  it has synced, so a new device doesn't replace the ones you have, and makes
  a smart playlist in one write with its rules.

### Changed
- Heavy Rotation and Rediscover Mix aren't listed, in Playlists or CarPlay,
  until their rules match a song.

## [1.6 (8)] - 2026-11-06

### Added
- Importing a YouTube playlist from a CSV export. A file with the video's
  title and channel, and no artist column, is read video by video: the artist
  from "Artist - Song" titles or a YouTube Music "Artist - Topic" channel, else
  the channel less "VEVO"; "(Official Video)", "Lyric Video", "M/V" and what
  follows a " | " are taken off the title, and a music video's length is
  left out, since it runs over the song's. So Melete asks MusicBrainz for the
  song by its own name and artist, not a video's title alone, which matched
  a different song of that name. Lengths in seconds and `h:mm:ss` are read
  too.

## [1.5 (7)] - 2026-11-05

### Changed
- The full-screen player no longer crops the album cover to the screen. The
  cover, or its motion cover, shows square and whole across the top, over a
  soft gradient of the cover's main colours (its palette, from Melete 0.5.0).
  With an older Melete, or until the palette comes, the ground is the cover
  blurred.
- Covers are downloaded at the size they're shown (160, 400, 600 or 800 pixels
  wide), not whole, so a song row no longer fetches a large folder image. The
  full-screen player still shows the whole cover, and a downloaded song keeps
  the whole cover for every size. Needs Melete 0.5.0; an older Melete sends the
  whole cover as before.
- Home's Added Recently banner shows the album's cover whole in its middle,
  over the cover's own colours, instead of cropping the top and bottom off a
  square cover to fill the banner.

### Removed
- Settings → Motion Covers, with its "Ones Your Server Made": Melete 0.5.0
  stopped making motion covers from still covers. An album's own motion
  cover, from its folder, always plays, except with Reduce Motion or Low
  Power Mode on.

### Fixed
- A motion cover kept on the phone stops playing once the server no longer
  has it, at the next launch. Before, a kept copy played for up to a week,
  so motion covers Melete made from still covers went on showing after
  Melete 0.5.0 removed them.

## [1.4 (6)] - 2026-11-03

### Added
- Playlists hold songs your library doesn't have yet. They show in place,
  greyed, with where their request stands, or "Not found" and why when nothing
  could be asked for. They can't be played: Play, Shuffle and CarPlay skip
  them. Once a song arrives, Melete puts the real track in its place and it
  plays like any other. Swipe to remove one as usual. Needs Melete 0.4.0.
- Ask for It: a song not in your library has Add to Playlist…, which asks for
  it if it hasn't been and puts it in the playlist you pick, waiting.

### Changed
- Importing a playlist saves all of it: your server makes the playlist with
  every song, the ones it has and the rest waiting, and asks for the missing
  ones itself. The playlist appears as it fills, with a link to open it. On a
  Melete before 0.4.0, saving keeps the songs found and the missing ones can
  still be asked for, as before.
- Waiting songs a build before this one set aside as unreadable are put back
  in their playlists on the next sync.

## [1.3 (5)] - 2026-11-02

### Added
- Profile pictures from Melete: yours in Settings beside Signed in as, and each
  person's in Listen Together once the server sends them. Without a picture, or
  on a Melete without profile pictures, the first letter of the name shows in a
  round tile.
- Motion covers: an album with a looping video plays it, muted, over its cover
  on the album's page and in the player. Settings → Motion Covers turns them
  off, and chooses whether to see the ones your server made from still covers.
  Off with Reduce Motion or Low Power Mode. WebM loops show the still cover.
- Lyrics can show each line's pronunciation in Latin letters (Japanese,
  Korean, Cyrillic), from Melete while the server has it on: the Pronunciation
  button over the lyrics. Downloaded songs keep it for offline listening.
- Requests keeps itself up to date while it's open, from Melete's request
  feed: no need to pull to refresh to see a download move along.
- Each request says more: where a download comes from (torrent or Soulseek),
  how the copy to the server is going (size, speed and time left), Melete's
  latest word on it, who approved or declined it and when, and when it last
  changed.
- Importing a playlist can ask your server for the songs your library doesn't
  have. They go to Melete, which matches each on MusicBrainz and asks for it.
- Requests lists those playlists with how many songs were asked for, asked
  already or not found. Open one to see what became of each song, or to
  remove it, which takes back the songs still waiting for approval.

### Changed
- Search by description and Mixes use your Melete server's AI instead of Apple
  Intelligence, so they work on any iPhone. Your server sends the words you
  type, with your library's genre names, to OpenRouter; they no longer stay on
  the phone. With the server's AI features off, or on a Melete without music
  AI yet, search is the plain search and Mixes says so; both turn on once the
  server has them. A sentence search waits a second after you stop typing, since
  each one counts against the server's hourly limit.
- Ask for It groups what MusicBrainz finds into songs, albums and artists, the
  best three of each with Show More for the rest, and each row says who it's by
  and when, with Ask or where it stands (In Library, Wanted, Asked For).
- Smart and automatic playlists (Heavy Rotation, Rediscover Mix, mixes and
  your own smart playlists) show a cover made from what they hold: the covers
  of their first four albums in a grid, or the first album's cover when there
  are fewer, updated as their songs change. In the Playlists list, at the top
  of the playlist, on Home and in CarPlay. A picture chosen for a playlist
  still wins, and a playlist's own header now shows it too.
- The player shows the cover, still or moving, over the whole screen behind
  its controls, the way Apple Music shows animated covers, with a dark shade
  under the controls so they read over any cover.

### Fixed
- Repeat now repeats the queue you made. Once you've added songs with Play
  Next or Play Last, repeat loops the song you started from and the songs you
  added, instead of going back through the rest of the album; that stays in Up
  Next for when repeat is off. An album with nothing added still repeats whole.
- Searching for a song that isn't in the library no longer lists unrelated
  songs. Search by description now keeps only what the words say: a genre you
  named, years when you gave a number or a decade, liked songs when you said
  so; a song or band name is no longer turned into a whole genre.

## [1.2 (4)] - 2026-10-31

### Added
- Asking for music the library doesn't have: at the foot of Search, look the
  words up on MusicBrainz through Melete and ask for an album, an artist or a
  song. Library → Requests lists what you've asked for and how each is
  getting on; swipe one still waiting to withdraw it.

## [1.1 (3)] - 2026-10-31

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

### Fixed
- Downloads from before Melete show and play again. The list that names them
  was written in Jellyfin's format, which the Melete build couldn't read, so
  the Downloads screen was empty while the files were still on the phone. At
  sign-in each one is matched to Melete's song and renamed; any Melete
  doesn't have are listed, with Remove Them.

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
