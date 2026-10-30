# Crossfade

One song faded into the next, on a toggle beside shuffle and repeat. Off by
default: a crossfade changes how every record on the device sounds, and a player
that starts doing it uninvited is a player that broke.

## What it is not

It is **not beat-matching**, and calling it that would be a lie you could hear.
That is why this is called Crossfade: it is a crossfade.

Matching beats needs to know where the beats *fall* — a downbeat and a grid, not
a count. What the library holds is one BPM figure per track, measured by the
server to about a beat per minute, whose own
[documentation](audio-analysis.md) says not to match on it. Two tracks locked to
the same tempo but a quarter-beat apart sound markedly worse than two tracks
that were never locked at all, so tempo here does exactly one job: deciding
whether a pair is worth a long blend or a short one.

A tempo also has to *describe* its track before anything can be matched to it.
The server reports `bpmStability` — the fraction of twenty-second windows that
agreed with the whole-track figure — and a track that ramps 105→145 reports a
confident 135 at a stability of 0.10. Below 0.5 the number is an average of a
track that was never at it, so the pair gets the short blend. A track from a
server too old to report stability is not penalised for it.

Tempi are compared as a ratio folded into a single octave, because 85 against
170 is one groove counted two ways — and half-or-double is the *expected* mistake
of the measurement, so treating those as unrelated would refuse precisely the
pairs that fit best.

## The rules

| Situation | Handover |
| --- | --- |
| Two consecutive tracks of one album, album lock on | Gapless — untouched |
| Crossfade off | A cut, exactly as before |
| Tempi agree (within 6%, any octave) and both hold steady | An 8-second blend |
| Anything else, including unmeasured tracks | A 4-second blend |
| Either track too short, or its length unknown | A cut |

No blend may swallow more than a quarter of the shorter of the two tracks, and
one that works out shorter than two seconds is a cut instead. A ninety-second
interlude does not lose a sixth of itself to the mixer.

**Album lock** is what makes crossfading safe to leave on: a record sequenced to run
continuously still does. It is on by default and is the mixer's off-switch,
never a second mixer — with Crossfade off, an unlocked album run is still a cut.

The rules live in `PlaybackKit/MixTransition.swift` and are unit-tested; nothing
about them needs a player to exercise.

## Two decks

One player cannot play two things at once, and a crossfade is two things at once.
So the engine holds two `AVQueuePlayer`s, like a DJ's decks. One of them is "the
player" at any moment and every path that is not about mixing goes through it and
cannot tell there is a second.

A blend is prepared twelve seconds ahead: the incoming track is put on the spare
deck, silent, and taken out of the playing deck's window so that deck runs *out*
of items and falls silent as its track ends. When it does, the decks swap — the
spare deck is now the player, and the track that was fading in is simply the
track that is playing.

Both decks are queue players, so an album run still hands over inside one deck
with `AVQueuePlayer`'s own seamless advance. The mixer is never allowed near a
record that segues.

## The two halves of the fade

They are performed differently, for a reason worth writing down.

The track coming **in** is faded by an `AVAudioMix` attached to its item before
it plays a note: sample-accurate, immune to a busy main thread, and unbothered by
the screen being off. AVFoundation only promises to honour a mix attached before
the item played.

The track going **out** has, by definition, already played. Its half is ridden
down on its deck's own fader, stepped twenty times a second from the deck's
media clock — a clock that only advances when audio does, so it cannot drift away
from the music. Each step is a fraction of a decibel from the last.

Both follow the same equal-power curve, because two unrelated recordings at half
volume are not as loud as one at full volume: a linear crossfade dips audibly in
the middle of every transition.

The levelling from [loudness normalisation](audio-analysis.md) sits underneath
both, so a blend fades between two tracks that were already at the same level
rather than undoing that work.

## When it gives up

A blend becomes a plain cut if the incoming track's fade cannot be built in time,
if that track fails to load, or if the queue moves under it — the decision is
re-taken twice a second, so it cannot go stale. A skip, a seek or a new "play
next" abandons whatever was prepared.

A cut is the player's ordinary behaviour, so falling back to one is never worse
than not having the feature. Two songs at full volume over each other would be.

## The three things this player can be

| | For | What it does |
| --- | --- | --- |
| **Crossfade** | Somebody listening to their music who does not want a gap | Every record, all of it, faded into the next |
| **Infinity + Crossfade** | Somebody who never wants it to end | The same, and the queue keeps going |
| **Auto DJ** | A room | Records mixed where they suit each other, played for their hook rather than to the fade-out, and the queue never runs out — Infinity is implied |

The third is the one that plays *less* of each record. A radio edit is rarely
used start to finish on a floor: the room hears the first hook, a second chorus
if it is landing, and moves on — forty to seventy per cent of a three-minute
record. Somebody who wants the whole song every time has the other two.

## Infinity

The other toggle: Crossfade decides *how* one song becomes the next, Infinity
decides that there **is** a next one.

When fewer than three songs are left in front of the listener, it asks Melete's
`/aoide/next` for twenty to follow whatever is playing. The server scores the
whole library: this listener's taste from what they finish, a shared genre with
the seed, closeness in tempo, key and energy, and penalties for what and who was
heard lately. It leaves out anything queued, recently played or marked Not
Interested. [infinity.md](infinity.md) is the rule, term by term.

It is arithmetic, not a recommender: every position it produces can be explained
in a sentence, and when it is wrong it is wrong somewhere you can point at.

**With Auto DJ on, Infinity is the set planner.** The request is made in `autodj`
mode: the same records are chosen, then put in the order they mix best, each
one the record that follows the last most smoothly.

Off by default: a queue that ends is not a fault, and a player that quietly plays
on for an hour after the album finished is one nobody asked for. It does nothing
while the queue is looping, since a loop never runs out, and it never starts
playback on its own — an empty queue that fills itself would be a player that
started playing while nobody was there.

What it adds is context, not a choice: the songs go behind everything, including
anything queued by hand, and they shuffle with the rest.

The desktop has had a version of this since Feishin, under the name Auto DJ.

**"Auto DJ" is being kept for something else**: transitions that are actually
mixed — beat-matched, on a grid, the thing anyone picturing a DJ is picturing.
That needs beat positions the tempo measurement does not yet give, so calling
either of these features a DJ would be borrowing a word we have not earned.
