# Activity tags

A listen can carry a note about what the listener was doing: **Gaming**, **Focus**,
**Chores**, **Commute**. Nothing detects it — you say so, or the listen is untagged.

## Why it is a closed set

Four words, spelled the same on both apps, chosen because they describe *why*
music is on rather than what it sounds like. Free text would be honest too, but
it splits: "gaming", "Gaming", "games" and "vidya" would be four buckets holding
one habit, and everything downstream reads these buckets.

A build that meets a word it does not know drops the tag rather than guessing.
That is what lets a newer app add a fifth activity without an older one
mis-filing its history.

## Why nothing guesses

Time of day, headphone route and motion all correlate with an activity, and none
of them are it. A wrong guess does not just show a wrong label for a moment — it
is written into the play history that mixes, smart playlists and Replay are built
out of, and there is no later moment at which it gets corrected. A tag somebody
set is worth more than four tags inferred.

## What syncs and what does not

| Thing | Scope |
| --- | --- |
| The tag on a play event | Syncs, like the event it belongs to |
| The activity currently selected | This device only |

The selection is about this device in this moment. A phone in a pocket adopting
the desktop's "Focus" because the desktop is at a desk would be nonsense, and the
same in reverse.

The server needs no change for either. Play events are opaque payloads to it, so
a new field inside one travels without the server knowing the field exists.

## When the tag is written

At the moment the listen **begins**. Setting Gaming halfway through a song does
not retag the song already playing; it tags the next one. This keeps the tag
answering one question — "what were you doing when you put this on?" — instead of
a blurred version of two.

## Reading it back

`finishCounts(byActivity:)` (iOS, `CurationKit`) and its desktop counterpart
split the same finish-rate counts the rest of the system uses, by tag, ignoring
untagged listens entirely. The minimum sample of three from
[finish rate](../Packages/CurationKit/Sources/CurationKit/FinishRate.swift)
applies per bucket: a habit needs to be a habit before it is worth reading.

## Storage

`playEvent.activity TEXT`, null when untagged (iOS migration `v9`). The selection
lives in `UserDefaults` under `aoide.currentActivity` on iOS.
