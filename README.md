# Aoide

A native iOS music player for your own Jellyfin server, built to look and feel
like Apple Music: big artwork, an artwork-tinted Now Playing screen, synced
lyrics, CarPlay, Siri, and a library that behaves like a library.

It plays what is on your server and keeps what is yours on the phone: playlists,
smart playlists, likes, taste flags and an honest play history, all synced
between devices through the [Aoide sidecar](https://github.com/Virel0/aoide-sidecar),
a small Jellyfin plugin. The [desktop app](https://github.com/Virel0/aoide-linux)
reads and writes the same data, so a playlist made on the phone is on the desk
and a play at the desk counts on the phone.

## What it does

- **Home** opens on the last things you were in, each one tap from playing, and a
  "pick up" tile when another device was playing more recently.
- **Library**: artists, albums, songs, genres, playlists, mixes, Replay.
- **Playlists** kept on the device and synced, with folders, drag-to-reorder that
  survives two devices reordering at once, chosen covers, and **smart playlists**
  whose rules re-run every time they are opened. Two are built in: *Rediscover
  Mix* and *Heavy Rotation*.
- **Mixes**: describe a mood, get a queue, built on-device with Apple
  Intelligence. The model writes rules; the rules pick the songs.
- **Search** that understands a sentence, on-device.
- **Downloads** shown as what you downloaded: playlists, albums, then songs. FLAC
  downloads are converted to Apple Lossless on the phone, which plays gapless
  where FLAC does not (measured: 67 ms of stall per boundary against none).
- **Trim Silence**: each file is measured once for where its sound actually
  starts and stops, and only that span plays.
- **Replay**: this month, this year or all time, from the play history.
- **Taste flags**: *Not Interested* keeps a track out of mixes, stations, shuffle
  and every smart playlist; *Don't Count Plays* keeps it out of the history.
- **Import a Spotify playlist** and see what your server has and what it lacks.
- CarPlay, Siri, SharePlay, AirPlay, synced lyrics corrected for Bluetooth
  latency, and a queue you can hand to another device.

## Requirements

- iPhone on iOS 26 or later. Mixes and sentence search need Apple Intelligence.
- A Jellyfin server. Developed against 10.11; older 10.x releases may work but are untested.
- The Aoide sidecar plugin on that server, for sync, taste flags, Spotify-import
  matching and silence measurement. Without it the app still plays music and
  keeps playlists locally.

## Building

Open `Aoide.xcodeproj` in Xcode 26 and run. Two things are yours to supply,
neither is committed:

```
cp Config/Local.example.xcconfig Config/Local.xcconfig
```

Then fill in `DEVELOPMENT_TEAM` (your Apple Team ID) and, optionally,
`AOIDE_DEFAULT_SERVER`, the address the sign-in screen offers on a fresh install.
The bundle identifier is `AOIDE_BUNDLE_ID` in the same file; use your own.
CarPlay is a per-app entitlement granted by Apple on request, so a build under
another identifier plays music but does not appear in the car until Apple says so.

The logic lives in three local Swift packages so it can be tested without a
simulator:

```
cd Packages/CurationKit && swift test    # store, op log, sync, smart playlists
cd Packages/JellyfinKit && swift test    # API client, import matching
cd Packages/PlaybackKit && swift test    # queue, conversion, silence bounds
```

`docs/sync-design.md` is the contract the app and the sidecar both implement.
`docs/taste-flags.md` and `docs/sound-bounds.md` are the two later additions.

## License

GPL-3.0-or-later. See `LICENSE`. Aoide is one of the three original Muses; the
name means "song".
