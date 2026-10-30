# Audio analysis: loudness and tempo

> **Since 2026-10-30** Aoide runs on [Melete](https://github.com/Virel0/Melete),
> which serves the sidecar's `/aoide/*` routes at the same paths, signed in with
> Melete's tokens. Where this says Jellyfin ids, read Melete track ids. The
> brief is kept as written.

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

*As built:* it really is one decode — the filter graph splits, one branch
carrying raw PCM for the silence scan and the tempo envelope while the other
goes through `loudnorm` purely so it prints its numbers. Asking **either**
endpoint about a file fills both caches, so a client that has already fetched
sound bounds for a playlist gets loudness and tempo without the server decoding
anything again.

## The measurements, pinned

Both clients must apply the same numbers, so the definitions are the contract.

**Loudness** — EBU R128 integrated loudness over the whole track, in LUFS, and
true peak in dBFS. `ffmpeg -i FILE -af loudnorm=print_format=json -f null -`
prints both as `input_i` and `input_tp`; that is the reference implementation.
A track too short or too quiet to measure reports `null`.

**Tempo** — beats per minute as a float, with a confidence between 0 and 1.
The clients only order by it, so approximate is acceptable and wrong is not.
**Report `null` below 0.5 confidence** rather than guessing: ambient, spoken
word and rubato classical have no meaningful single tempo, and a made-up 128
there is worse than nothing.

*As built (sidecar 1.11.0.0):* envelope autocorrelation in C#, not `aubio` or
Essentia — Jellyfin ships ffmpeg and nothing else, and a plugin that is one
managed DLL should not need an admin to install a native library first for two
numbers used only for ordering. Verified within about a BPM at 90–170 on
synthesised beats, at any loudness; held tones, noise, silence and anything
under ten seconds report nothing.

*As built (sidecar 1.12.0.0):* the estimator became multi-band spectral flux with
interpolated correlation lags, and the accuracy went from about a beat per minute
to within 0.2 — 185 BPM used to come back as 92. A `bpmStability` field arrived
with it: the fraction of overlapping twenty-second windows whose own tempo agreed
with the whole-track answer, half and double counting as agreement. It is the
answer to a question confidence cannot answer — a track ramping 105→145 reports a
*confident* 135 and a stability of 0.10. `null` under about forty seconds.

The clients use stability for one thing: a track whose tempo does not hold is not
a track a long crossfade can be matched to, whatever its BPM says. See
[crossfade.md](crossfade.md). **1.0 does not mean "gridded"** — half a per cent is
what twenty seconds of audio can resolve, and half a per cent still drifts most of
a second across a three-minute track.

That release also dropped every server-measured row so the better estimator would
take them again, since a row is otherwise only re-measured when its file changes.
The clients cache those numbers too, so iOS names its cache file by generation and
deletes the previous one; anything else would have kept the old tempi for good.

**Half and double is the expected failure**, settled for the ordinary case by a
preference for tempi near 120, so a track reported at 85 that you would call 170
is the mistake to look for. **Do not beat-match on these numbers.** Ordering is
what they are for.

**If a client ever measures tempo itself, taper the analysis window.** A 220 Hz
drone came back as a confident 120 BPM on the sidecar's first live run and
passed its unit tests, which had used 440 Hz: reading energy off a rigid grid
makes a sustained note's level wobble in step with its own frequency against the
hop rate, and that wobble is as periodic as any drum machine. A Hann taper kills
it. Two implementations would hit this separately, so it is written here rather
than only in the server.

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
a track at or below the reference is left alone entirely, peak and all, because
the true-peak rule exists to stop the *client* pushing a signal over full scale
and a file it has decided not to touch is not its to limit. Among the tracks it
is turning down, one whose true peak would still land above 0 dBFS is turned
down further until it does not. Results are rounded to a hundredth of a decibel
on both sides, and the same nine inputs are pinned as a table in each app's
tests. A file that already carries ReplayGain tags uses those; this is for the
ones that do not.

**Tempo.** Ordering, at first: a mix that rises rather than lurching. Nothing
transitions on a beat until the numbers have proved themselves in practice.

## What this does not need

No new sync entity, no op log, no export, no retention rules. These are facts
about a file rather than about a person, so they belong to the server that holds
the file and can be recomputed at any time. Nothing here is user data and none of
it should be synced.
