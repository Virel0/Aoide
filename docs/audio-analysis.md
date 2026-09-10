# Audio analysis: loudness and tempo

*Proposed 2026-09-10 from the client side. Asks the sidecar for two numbers per
track that neither client can compute for a file it does not hold. Same shape as
`sound-bounds.md`, and deliberately so — it is the same decode.*

## Why

**Loudness.** A personal library is mastered across four decades, so playing a
2015 remaster after a 1978 pressing is a volume lottery. That is merely annoying
on headphones and genuinely bad while gaming, where the music sits under a game
whose own level is fixed. mpv and AVPlayer can both correct for it, given a
number. Files with ReplayGain tags already carry one; most do not.

**Tempo.** The only missing ingredient for anything beat-aware — ordering a mix
so it builds, or eventually transitions that are not just a crossfade. Neither
client can compute it for a streamed file, and computing it on a phone for a
library of thousands is not sensible.

Both come from decoding the file, which the sidecar **already does** for
`/aoide/sound-bounds`. One decode can produce all of it; doing them in the same
pass is the main reason to build this here rather than anywhere else.

## The measurements, pinned

Both clients must apply the same numbers, so the definitions are the contract.

**Loudness** — EBU R128 integrated loudness over the whole track, in LUFS, and
true peak in dBFS. `ffmpeg -i FILE -af loudnorm=print_format=json -f null -`
prints both as `input_i` and `input_tp`; that is the reference implementation.
A track too short or too quiet to measure reports `null`.

**Tempo** — beats per minute as a float, with a confidence between 0 and 1.
`aubio tempo` or Essentia's `RhythmExtractor2013` are both fine; the clients
only order by it, so approximate is acceptable and wrong is not. **Report `null`
below 0.5 confidence** rather than guessing: ambient, spoken word and rubato
classical have no meaningful single tempo, and a made-up 128 there is worse than
nothing.

## Endpoint

```
GET /aoide/audio-analysis?ids=<jellyfinId>,<jellyfinId>,…      (≤ 200 ids)
Authorization: MediaBrowser Token="…"                          (the user's, as everywhere)

200 {
  "analysis": {
    "<jellyfinId>": {
      "loudnessLufs": -9.7,
      "truePeakDbfs": -0.3,
      "bpm": 128.0,
      "bpmConfidence": 0.82
    },
    "<jellyfinId>": null          // measured; nothing worth reporting
  },
  "pending": ["<jellyfinId>"]     // not measured yet, ask again later
}
```

- Any field may be `null` independently: a track can have loudness and no usable
  tempo. `null` for the whole entry means measured and nothing to report.
- Lazily measured and queued exactly as sound bounds are, returned in `pending`
  meanwhile. The clients play the track unmodified and ask again next time.
- Cached per item against the file's modification time, so a replaced file is
  re-measured.
- Unknown ids are omitted rather than being an error.
- `POST /aoide/audio-analysis` with the same body shape, from a client that
  measured a file itself. Optional; the server may ignore it.

## What the clients do with it

**Loudness.** Normalise to **−18 LUFS**, the ReplayGain 2.0 reference, so both
apps land on the same level. Gain is `−18 − loudnessLufs` dB, applied by mpv on
the desktop and as a per-track volume factor on the phone, **attenuating only** —
a track quieter than the reference is left alone rather than amplified into its
own true peak. A file that already carries ReplayGain tags uses those; this is
for the ones that do not.

**Tempo.** Ordering, at first: a mix that rises rather than lurching. Nothing
transitions on a beat until the numbers have proved themselves in practice.

## What this does not need

No new sync entity, no op log, no export, no retention rules. These are facts
about a file rather than about a person, so they belong to the server that holds
the file and can be recomputed at any time. Nothing here is user data and none of
it should be synced.
