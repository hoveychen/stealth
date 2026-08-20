# Batch 17, P5 (ImageDecoder / ImageTrack / ImageTrackList) — ground truth

Measured on Chrome 150, macOS, on an https page. Raw data: `win47-chrome.json`.
Probe: `probe-win47.js` — it builds its own 4x2 PNG off a canvas and a
hand-assembled 2-frame animated GIF, so it needs no network, and it wraps every
promise in a 1.5s race so a never-settling one reports `PENDING(...)` instead of
hanging the whole evaluate (which is what happened on the first attempt).

**This closes the gap probe-win43.js left**: that probe read `decoder.tracks`
before `tracks.ready` settled and so recorded an empty track list, leaving every
`ImageTrack` getter unmeasured.

## Prototypes

```
ImageTrack       get frameCount[ec-],get animated[ec-],get repetitionCount[ec-],accessor selected[ec-],@@toStringTag=ImageTrack
ImageTrackList   get length[ec-],get selectedIndex[ec-],get selectedTrack[ec-],get ready[ec-],@@toStringTag=ImageTrackList,@@iterator=fn:values
ImageDecoder     get type[ec-],get complete[ec-],get completed[ec-],get tracks[ec-],close/0[ecw],decode/0[ecw],reset/0[ecw],@@toStringTag=ImageDecoder
```

Note `decode/0` — arity **zero**, not one. `ImageTrackList`'s only own symbols
are `@@toStringTag` and `@@iterator`, and the iterator *is* the `values`
function, so it needs `bridge.iterator(..., .{ .js_name = "values" })` or it will
show up as an anonymous function the way the WebGPU setlikes first did.

`ImageTrack` and `ImageTrackList` are both `Illegal constructor`
(`Failed to construct 'ImageTrack': Illegal constructor`, and calling without
`new` is the bare `Illegal constructor`).

## ImageDecoder.isTypeSupported

Resolves a boolean, and it never throws — `isTypeSupported()` with no argument
returns a Promise.

True: `image/png`, `image/jpeg`, `image/gif`, `image/webp`, `image/avif`,
`image/bmp`, and **`IMAGE/PNG`** (the type is matched case-insensitively).
False: `image/x-icon`, `image/svg+xml`, `image/tiff`, `nope`, `''`.

## The track list is empty until `ready` settles

Straight after `new ImageDecoder({data, type})`:

- `type` echoes the string, `complete` is **true**, `completed` is a Promise,
  `tracks` is an ImageTrackList.
- `tracks.length` is 0, `tracks.selectedIndex` is **-1**, `tracks.selectedTrack`
  is **null**.

After `await tracks.ready` (which resolves undefined for a good image):

- `tracks.length` 1, `tracks.selectedIndex` 0.
- `tracks[0]` is an own property (`Object.getOwnPropertyNames(tracks)` is
  `["0"]`), it is `=== tracks.selectedTrack`, and the same object comes back on
  every read. An out-of-range index is `undefined`.
- Iteration works: `for...of`, `Array.from` and spread all give the one track.

For the still PNG the track reads `{animated: false, frameCount: 1,
repetitionCount: 0, selected: true}` and has no own properties.

For the 2-frame animated GIF: `length` 1, `selectedIndex` 0, and the track reads
`{animated: true, frameCount: 2, repetitionCount: null, selected: true}` — note
`repetitionCount` is **null** for an infinitely-looping GIF and **0** for a still
image.

`track.selected = false` deselects it: the track reads back false, and the list
then reports `selectedIndex` **-1** and `selectedTrack` **null**. Setting it back
to true restores index 0.

## decode()

Resolves a plain `{complete, image}` object — keys in that order, prototype
`Object.prototype` — whose `image` is a **VideoFrame**. For the 4x2 PNG:
`{format: 'BGRA', codedWidth: 4, codedHeight: 2, timestamp: 0, duration: null}`.

For the animated GIF the two frames come back as
`complete=true, timestamp=0, duration=100000` and
`complete=true, timestamp=100000, duration=100000` (microseconds, so a 0.1s
frame delay), both 1x1.

Refusals:

- `decode({frameIndex: 99})` rejects `RangeError: The frame index provided (99)
  is outside the range [0, 1).` — the upper bound is the frame count, so the GIF
  says `[0, 2)`.
- `decode('x')` rejects `TypeError: Failed to execute 'decode' on
  'ImageDecoder': The provided value is not of type 'ImageDecodeOptions'.`
- `decode({frameIndex: 0, completeFramesOnly: true})` is fine.

## reset() and close()

`reset()` returns undefined and, on a decoder whose metadata is already in,
changes nothing observable: `complete` stays true and the track list keeps its
one track.

`close()` returns undefined and **is idempotent** (a second one does not throw —
unlike the four codec classes, where a second `close()` is an InvalidStateError).
After it:

- `complete` stays **true**, but `type` becomes the **empty string**.
- `tracks.length` 0, `tracks.selectedIndex` -1.
- `decode()` rejects `InvalidStateError: The decoder has been closed.` — note
  there is no "Failed to execute" prefix on this one.
- `reset()` still returns undefined.
- Both `completed` and `tracks.ready` are already resolved and stay resolved.

## The two failure paths

**A type nothing supports** (`{data: png, type: 'nope'}`): the constructor
*accepts* it and `type` echoes `'nope'`. Then `tracks.ready` rejects
`NotSupportedError: The provided image type (nope) is not supported` — no
trailing period — and `decode()` rejects with the same error. `completed` never
settles at all (it reported `PENDING` after 1.5s). `tracks` stays `0/-1`.

**Junk bytes with a good type** (`{data: [1,2,3,4], type: 'image/png'}`):
`tracks.ready` rejects `InvalidStateError: Failed to retrieve track metadata.`,
`completed` **resolves**, and `decode()` rejects `InvalidStateError: The decoder
has been closed.`

## Constructor

`ImageDecoderInit` requires `data` and `type`, read in that order (`{}` complains
about data; `{data}` about type). `null`, `undefined` and a number are all
`The provided value is not of type 'ImageDecoderInit'.`, and no argument at all
is `1 argument required, but only 0 present.`

`data` is a three-arm union and Chrome names all of it:
`The provided value is not of type '(ReadableStream or [AllowShared] ArrayBuffer
or [AllowShared] ArrayBufferView)'.`

The optional members (`premultiplyAlpha`, `colorSpaceConversion`,
`desiredWidth`, `desiredHeight`, `preferAnimation`) are all accepted, and
**a bogus enum value is not rejected at construction**:
`{premultiplyAlpha: 'nope'}` builds an ImageDecoder rather than throwing. Do not
add the usual enum refusal here.
