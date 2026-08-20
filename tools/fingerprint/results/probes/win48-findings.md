# Batch 17, P4 addendum — what win46 left open

Three more Chrome 150 / macOS runs on an https page, closing the gaps the
handoff flagged and a few the implementation turned up. Probes
`probe-win48.js`, `probe-win49.js`, `probe-win50.js`; raw data
`win48-chrome.json`, `win49-chrome.json`, `win50-chrome.json`. Read
[win46-findings.md](win46-findings.md) first — this only adds to it.

## configure() refuses a malformed config *synchronously*

win46 established that an unsupported codec is an asynchronous error. It is
not the whole story: every other refusal is a plain synchronous TypeError, and
the codec stays exactly where it was (`state` is still `'unconfigured'`
afterwards, and no error callback ever fires). So there are two distinct
paths — validation, which throws now, and support, which errors later.

| config | `configure()` throws |
|---|---|
| `{codec:'vp8', codedWidth:0, codedHeight:240}` | `Invalid coded size (0, 240).` |
| `{codec:'vp8', codedWidth:320, codedHeight:0}` | `Invalid coded size (320, 0).` |
| `{codec:'vp8', codedWidth:0, codedHeight:0}` | `Invalid coded size (0, 0).` |
| `{codec:'vp8', codedWidth:320}` | `Invalid config, codedWidth specified without codedHeight.` |
| `{codec:'vp8', codedHeight:240}` | `Invalid config, codedHeight specified without codedWidth.` |
| `{codec:''}` | `Invalid codec; codec is required.` |
| `{codec:'vp8', width:0, height:240}` (encoder) | `Invalid size; height and width must be greater than zero.` |
| `{codec:'opus', sampleRate:0, numberOfChannels:2}` | `Invalid sample rate; sample rate must be non-zero, received 0.` |
| `{codec:'opus', sampleRate:48000, numberOfChannels:0}` | `Invalid channel count; channel count must be non-zero, received 0.` |
| `{codec:'vorbis', …}` (AudioDecoder, no description) | `Invalid config; description is required.` |

All of them read identically through `isConfigSupported`, only with that
method's prefix and as a rejection rather than a throw. `(320, 0)` closes the
first gap the handoff named.

## Validation order

Two orders, and they are not the same on video and audio.

- **Video** checks the codec first: `{codec:'', codedWidth:0, codedHeight:240}`
  reports the codec, not the size.
- **Audio** checks the numbers first, and the channel count before the rate:
  `{codec:'', sampleRate:0, numberOfChannels:2}` reports the *rate*, and
  `{codec:'opus', sampleRate:0, numberOfChannels:0}` reports the *channels*.
  Only a config whose numbers are both fine gets as far as the codec.

## The constructor reads `error` before `output`

Alphabetical, so `{}` and `{output: f}` both complain about `error`, and
`{error: f}` about `output`. A non-callable is
`Failed to read the 'output' property from 'VideoDecoderInit': The given value
is not a function.` An unrecognised member is ignored.

`ondequeue = 7` reads back **null** — a non-callable clears the slot rather
than throwing.

## The isConfigSupported echo, member by member

Every optional member is echoed when provided, alphabetically, and an
unrecognised one is dropped. Defaults that are *always* filled in:

- `VideoDecoderConfig`: `flip:false`, `hardwareAcceleration:'no-preference'`,
  `rotation:0`. `codedWidth`/`codedHeight`/`description`/`optimizeForLatency`
  only when given.
- `VideoEncoderConfig`: `alpha:'discard'`, `bitrateMode:'variable'`,
  `contentHint:''`, `hardwareAcceleration:'no-preference'`,
  `latencyMode:'quality'`. `avc`/`bitrate`/`displayWidth`/`displayHeight`/
  `framerate`/`scalabilityMode` only when given.
- `AudioDecoderConfig`: nothing beyond the three required members.
  `hardwareAcceleration` is **not** a member — it is accepted and dropped.
- `AudioEncoderConfig`: `bitrateMode:'variable'`. `bitrate`/`opus` when given.

`rotation` is echoed raw, not rounded: `{rotation: 45}` reads back 45.

`avc` is echoed exactly as it came in (`{format:'annexb'}` → `{format:'annexb'}`).
`opus` is **not** — it comes back filled out:
`{application:'audio', complexity:5, format:'opus', frameDuration:20000,
packetlossperc:0, signal:'auto', usedtx:false, useinbandfec:false}` for an
input of `{complexity: 5}`. The default for `complexity` alone was not
measured, so reproduce it by echoing `complexity` only when the page provides
one.

## `description` is copied into a fresh ArrayBuffer

Not handed back: a 3-byte `Uint8Array` view over an 8-byte buffer echoes an
**ArrayBuffer of byteLength 3** holding exactly those three bytes. It is never
the input's own `.buffer`, and two calls with the same input give two
different objects. That is why a stringified probe shows `"description":{}` —
`JSON.stringify` of an ArrayBuffer is `{}`, of a Uint8Array is `{"0":…}`.

A `description` that is not a BufferSource is
`Failed to read the 'description' property from 'VideoDecoderConfig': The
provided value is not of type '([AllowShared] ArrayBuffer or [AllowShared]
ArrayBufferView)'.`

## `prefer-hardware` finds nothing on this box

`{codec:'vp8', hardwareAcceleration:'prefer-hardware'}` answers
`supported: false` on both video classes, where `prefer-software` and
`no-preference` answer true. Worth reproducing: it is a second axis a detector
can enumerate on top of the codec list.

## vorbis and flac

They answer `supported: true` once a `description` is present — the refusal in
win46 was only about its absence. Both are **case-sensitive**: `Vorbis`,
`VORBIS`, `Flac` and `FLAC` are all `supported: false`, and without a
description a capitalised one is plainly false rather than refused. So the
description requirement is keyed to the exact lowercase names.

## The dequeue event

`bubbles`, `cancelable` and `composed` all false, `isTrusted` true, `target`
the codec, and `eventPhase` **2** (AT_TARGET) inside the handler. The
`ondequeue` attribute and an `addEventListener('dequeue')` both fire, the
attribute first.
