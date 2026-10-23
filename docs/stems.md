# Stems: the voice apart from the band

*Asked of the sidecar on 2026-10-23 from the client side. Auto DJ was shelved
on 2026-10-22 (see [arrangement.md](arrangement.md), "Shelved") because the
decks can only move a whole mix. This is what would bring it back, and what
would give the apps a karaoke mode on the way.*

## Why

A song file is every instrument added into one waveform. Everything a DJ
does that sounds good is done to the parts separately: the outgoing singer's
last word echoed on its own, the new record's drums under the old record's
voice, two vocals never overlapping. The decks can turn a whole record up or
down and filter it, and nothing else. Every rule in arrangement.md made one
mechanism measurably right; none of them got past that ceiling.

Source separation is a solved problem with open, local tools. The sidecar
already decodes every track to measure it, and the server has a GPU.

## What is wanted

### 1. One stem per track: the vocal

Per track, the **vocal stem**, and only that.

The rest of the record is not stored. The clients play the original file and
the vocal stem together, sample-aligned on one clock, and get any vocal level
they want by adding the stem at a gain:

```
heard = original + (g − 1) · vocals      g = 1 normal, 0 no voice, 0.3 Sing
```

and an echo of the voice alone by sending only the vocal stem into the delay.
That halves the storage and the download of a two-stem scheme, and it only
works if the stem is exact against the original, which sets the format:

- **Lossless.** FLAC. A lossy vocal stem subtracted from the original leaves
  its codec noise in the "instrumental". Vocal stems are mostly silence and
  compress well.
- **The same samples as the source.** Separated from the *decoded original*,
  at its own sample rate and channel count, with no resampling, no trim and
  no added padding: sample *n* of the stem is sample *n* of the file. The
  clients play downloads that were converted FLAC → ALAC, which is lossless,
  so the samples are the same.
- **The same length**, to the sample.

Drums and bass stems would make a better bass swap and are worth having
later. Not in this round: the vocal is what every failure in arrangement.md
came down to.

### 2. The model

**Demucs, `htdemucs`**, Meta's hybrid transformer model. The code is
MIT-licensed; please confirm the licence of the released weights before
shipping them. It outputs four stems; keep `vocals`. It is normally run from
Python. How the sidecar runs it is the sidecar's call: an ONNX export through
ONNX Runtime with the CUDA execution provider keeps it inside .NET, and a
separate local process is the other option. Two constraints either way:

- **Nothing leaves the server.** No hosted separation API.
- **No PHP**, and nothing pulled in that drags in a web runtime.

On a GPU this should be seconds per track; without one, minutes. The sidecar
should still work without a GPU, slowly, and say so (§4).

### 3. When it runs

Lazily, like every other measurement, with two additions:

- **A track a client asks about is put at the front.** The clients will ask
  for the queue ahead of playback, as they do for grids.
- **The background sweep covers stems too**, when it is enabled, so a
  library is separated over time without anyone playing it.

A track that cannot be separated (too short, spoken word, a decode failure)
is finished with no stem, not retried forever, as with grids.

### 4. Endpoints

```
GET /aoide/stems?ids=<jellyfinId>,…      (≤ 200)
```

```json
{
  "stems": {
    "3b1c…": { "vocals": { "bytes": 6123456, "sampleRate": 44100, "channels": 2, "frames": 9437184, "sha256": "…" } },
    "9f2a…": null
  },
  "pending": ["77e0…"]
}
```

- A track in `stems` with an object has a stem ready. `null` means
  "measured, no stem worth having". `pending` means queued or running, and
  asking put it at the front.
- `frames` lets a client check, before playing, that the stem is the same
  length as its file. A mismatch is a bug, and the client will refuse the
  stem rather than play it misaligned.
- 404 from the endpoint itself is an older sidecar. Clients fall back to
  playing without stems.

```
GET /aoide/stems/<jellyfinId>/vocals     → audio/flac
```

Range requests, please: the phone will download a stem the way it downloads
the track.

And in `/aoide/analysis/coverage`, `stems` (decoded) and `separated` (with a
stem), the same pattern as `beatGrids` / `gridded`, plus
`"separationDevice": "cuda" | "cpu"` so a slow library can be explained.

### 5. Storage

Under the plugin's data folder, one file per track, named by Jellyfin id.
Deleted when the track leaves the library. A size cap in the plugin
settings, and the coverage endpoint reports the bytes used. A vocal FLAC is
roughly a third to a half of the original's size.

## What the clients will do with it

- **Sing** (karaoke): the vocal turned down to about 30%, with the synced
  lyrics on screen. The first use, and the test of alignment: a stem a few
  samples out of line makes the voice sound phased, not quieter.
- **Auto DJ, back**: a throw that echoes the voice only; a blend that brings
  the new record's band in under the old voice and swaps the voices on the
  phrase line, never both at once. The decks gain a second player per deck,
  on the same timeline as the first.
- Tests as before: rendered and measured. Stem plus original at g = 0 must
  cancel a known vocal to below −40 dB on a test file.

## What the clients will do if it never arrives

What they do now: Auto DJ stays hidden, and Sing is not offered.
