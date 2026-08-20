# Batch 17, P5 addendum — and one correction to win47

Chrome 150 / macOS, https page. Probe `probe-win51.js`, raw data
`win51-chrome.json`. Read [win47-findings.md](win47-findings.md) first.

## Correction: `repetitionCount` is Infinity, not null

win47 recorded `repetitionCount: null` for the looping GIF. That was
`JSON.stringify` flattening **Infinity** to null — the value read directly is
`Infinity`. A still PNG's 0 is a real 0.

And `animated` follows the *format*, not the frame count: a **one-frame** GIF
still reports `animated: true`, `frameCount: 1`, `repetitionCount: Infinity`.
So the three-way split is

| image | animated | frameCount | repetitionCount |
|---|---|---|---|
| PNG still | false | 1 | 0 |
| GIF, 1 frame, no NETSCAPE block | true | 1 | Infinity |
| GIF, 2 frames, NETSCAPE loop 0 | true | 2 | Infinity |

## decode()

- `decode('x')` **returns a Promise and rejects** — it is not a synchronous
  throw. (win47 captured it through `Promise.resolve().then(...)`, which could
  not tell the two apart.)
- `decode({frameIndex: -1})` rejects
  `TypeError: Failed to execute 'decode' on 'ImageDecoder': Failed to read the
  'frameIndex' property from 'ImageDecodeOptions': Value is outside the
  'unsigned long' value range.` — an `[EnforceRange]` refusal, not the
  RangeError an out-of-range-but-positive index gets.
- Two `decode()` calls give two **different** VideoFrame objects.
- `decode()` called **before** `tracks.ready` settles works: it waits, resolves
  `{complete: true, image}`, and the track list reads 1 / 0 afterwards.
- `desiredWidth` / `desiredHeight` are accepted and resize nothing: a 4x2 image
  asked for 8x4 still decodes 4x2 coded and 4x2 display.

## The decoded frame carries real pixels

`decode()` then `frame.copyTo()` on a 4x2 PNG whose left half was filled black
returns 32 bytes:

```
00 00 00 FF  00 00 00 FF  00 00 00 00  00 00 00 00
00 00 00 FF  00 00 00 FF  00 00 00 00  00 00 00 00
```

BGRA, opaque black where the fill was and transparent elsewhere. So the samples
are readable from a page and an implementation that answers geometry only is
distinguishable.
