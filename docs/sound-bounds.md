# Sound bounds: where each track's sound starts and stops

*Proposed 2026-09-04 from the client side. Built and shipped on iOS for downloaded
files; this asks the sidecar to provide the same for streamed tracks, so the
desktop (which never holds a file) and the phone (for anything not downloaded)
can trim the same silence.*

## Why

Gapless playback joins two files with no stall — measured on the phone: FLAC
stalls 67 ms at every boundary, Apple Lossless 0 ms — and still leaves silence
between songs when the *recordings* carry it: three seconds of nothing after the
last chord, two before the first note of the next. Trimming that needs to know,
per track, where the sound actually is. The phone measures its downloads itself.
Nothing else can measure what it does not hold; the server holds everything.

## The measurement (the phone's, exactly — both sides must agree)

Decode to PCM float. A sample is *sound* if any channel's absolute value exceeds
**0.00178** (−55 dBFS: under a fade's tail, above a vinyl rip's noise floor).

- `soundStart` = time of the first sound sample **minus 60 ms**, floored at 0.
- `soundEnd` = time of the last sound sample **plus 200 ms**, capped at the
  file's length.
- If `soundStart < 300 ms` **and** `length − soundEnd < 300 ms`, there is
  nothing worth trimming: report no bounds (the client plays the file whole).
- A file with no sound sample at all: no bounds.

Reference implementation: `Packages/PlaybackKit/Sources/PlaybackKit/SilenceBounds.swift`,
tests in `SilenceBoundsTests.swift` (a 2 s / 3 s / 2.5 s silence–tone–silence
file must yield start ≈ 1.94 s and end ≈ 5.2 s; a −40 dBFS quiet tail must be
kept; a 100 ms trim must be ignored). ffmpeg's `silencedetect` with
`noise=-55dB` gives the raw crossings; apply the margins and the 300 ms rule
on top.

## Endpoint

```
GET /aoide/sound-bounds?ids=<jellyfinId>,<jellyfinId>,…     (≤ 200 ids)
Authorization: MediaBrowser Token="…"                        (the user's, as everywhere)

200 {
  "bounds": {
    "<jellyfinId>": { "soundStartMs": 1940, "soundEndMs": 312200 },
    "<jellyfinId>": null            // measured: nothing to trim
  },
  "pending": ["<jellyfinId>"]       // not measured yet; ask again later
}
```

- Measured lazily: an id asked for and not yet measured is queued and returned
  in `pending`; the client plays it whole this time and asks again next time.
  A scheduled task may also sweep the library so most tracks are ready before
  anyone asks.
- Cache per item keyed with the file's modification time, so a replaced file is
  re-measured.
- Unknown ids: omitted from `bounds`, not an error.
- `POST /aoide/sound-bounds` with the same shape, from a client that has
  measured a file itself (the phone, for its downloads), so the server can
  serve it without decoding. Optional; the server may ignore it.

## What the clients do with it

Phone: a downloaded track uses its own measurement; a streamed track asks the
server, and `AVPlayerItem.forwardPlaybackEndTime` plus a queued seek do the
rest — the handover stays stall-free because the end point *is* the item's end.
Desktop: the same numbers go to MPV as per-file start/end, and to the web
player as a seek on start and an early advance.
