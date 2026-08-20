# Batch 17, P4 (the four codec classes) — ground truth

Measured on Chrome 150, macOS, on an https page (the four codec classes are
`[SecureContext]`, so `about:blank` does not expose them — that is why
`run-probe.mjs` takes a url). Raw data: `win46-chrome.json`,
`win46b-chrome.json`, `win46c-chrome.json`. Probes: `probe-win46.js`,
`probe-win46b.js`, `probe-win46c.js`.

Shapes and the EventTarget chain are in `win43-chrome.json` / `win43-findings.md`
and are already exact there. This file is only about behaviour.

## The state machine

`state` is `'unconfigured' | 'configured' | 'closed'`. All four behave
identically here.

| call | unconfigured | configured | closed |
|---|---|---|---|
| `configure(c)` | → `configured` | → `configured` (no error) | **InvalidStateError**, see the role quirk below |
| `decode`/`encode` | InvalidStateError `Cannot call 'decode' on an unconfigured codec.` | see below | InvalidStateError `Cannot call 'decode' on a closed codec.` |
| `flush()` | **rejects** InvalidStateError `Cannot call 'flush' on an unconfigured codec.` | resolves undefined, queue → 0, state unchanged | rejects `Cannot call 'flush' on a closed codec.` |
| `reset()` | undefined | undefined, → `unconfigured`, queue 0 | **throws** InvalidStateError `Cannot call 'reset' on a closed codec.` |
| `close()` | undefined | undefined | **throws** InvalidStateError `Cannot call 'close' on a closed codec.` |

So `close()` is *not* idempotent, unlike VideoFrame's and AudioData's — a second
one throws. Worth knowing because it is the opposite of the two containers.

**The role quirk.** `configure()` after `close()` names a different verb
depending on which side of the family it is on. Both *decoders* say
`Cannot call 'decode' on a closed codec.` while both *encoders* say
`Cannot call 'configure' on a closed codec.` That is a Blink slip; transcribe it.

Arity and conversion refusals, all four:

- `configure()` → TypeError `1 argument required, but only 0 present.`
- `configure('x')` → TypeError `The provided value is not of type 'VideoDecoderConfig'.`
- `decode()` → TypeError `1 argument required, but only 0 present.`
- `decode({})` → TypeError `parameter 1 is not of type 'EncodedVideoChunk'.`
  (`VideoFrame` / `AudioData` / `EncodedAudioChunk` for the others)
- `new VideoDecoder('x')` and `new VideoDecoder(null)` → TypeError
  `The provided value is not of type 'VideoDecoderInit'.`
- `ondequeue = 7` reads back **null** (a non-callable clears the slot).

## configure() with an unsupported codec is asynchronous

`configure({codec: 'nope', …})` returns undefined and leaves `state` at
`'configured'`. On a later task the `error` callback fires with a **DOMException**
(`e instanceof DOMException` is true) and `state` becomes `'closed'`. Calling
`configure` twice with the same bad codec still produces exactly **one** error.

The message differs per class:

| class | error |
|---|---|
| `VideoDecoder` | `NotSupportedError: Unknown or ambiguous codec name.` |
| `AudioDecoder` | `NotSupportedError: Unknown or ambiguous codec name.` |
| `VideoEncoder` | `NotSupportedError: Unsupported codec type.` |
| `AudioEncoder` | `NotSupportedError: Unsupported channel count; expected range from 1 to 32, received 0.` |

The AudioEncoder one is Chrome reporting a channel count it never parsed; it
says "received 0" even when the config passed `numberOfChannels: 2` (measured
twice). Transcribe it as-is.

A *supported* codec leaves `state` at `'configured'` and fires nothing.

## decode() / encode() on a configured codec

- **VideoEncoder / AudioEncoder / AudioDecoder** with a `key` input: returns
  undefined, the queue size goes to 1, then a `dequeue` **Event** (`bubbles`,
  `cancelable`, `composed` all false, `target` the codec) dispatches on a later
  task and the queue returns to 0.
- **VideoDecoder** never accepts a synthesised chunk. A `key` chunk gives
  `DataError: Failed to execute 'decode' on 'VideoDecoder': An EncodedVideoChunk
  was marked as type \`key\` but wasn't a key frame. A key frame is required
  after configure() or flush().` A `delta` chunk gives the shorter
  `DataError: … A key frame is required after configure() or flush().`
- **AudioDecoder** with a `delta` chunk gives `DataError: Failed to execute
  'decode' on 'AudioDecoder'` — with **no message text at all** after the
  prefix.
- An encoder handed a closed input: `TypeError: Failed to execute 'encode' on
  'VideoEncoder': Cannot encode closed input.` AudioDecoder handed a closed
  chunk does not care (a chunk has no close()).

## isConfigSupported

Never throws synchronously: every failure — the argument count, a non-object, a
missing member, a validation refusal — comes back as a **rejection**. It resolves
a plain object with keys `config` then `supported`, and `config` is the input
echoed back with every default filled in, **alphabetically**.

Echoes, minimal input:

| class | echo |
|---|---|
| `VideoDecoder` `{codec:'vp8'}` | `{codec, flip:false, hardwareAcceleration:'no-preference', rotation:0}` |
| `VideoEncoder` `{codec:'vp8',width:320,height:240}` | `{alpha:'discard', bitrateMode:'variable', codec, contentHint:'', hardwareAcceleration:'no-preference', height, latencyMode:'quality', width}` |
| `AudioDecoder` `{codec:'opus',sampleRate:48000,numberOfChannels:2}` | `{codec, numberOfChannels, sampleRate}` |
| `AudioEncoder` `{codec:'opus',sampleRate:48000,numberOfChannels:2}` | `{bitrateMode:'variable', codec, numberOfChannels, sampleRate}` |

Members that were provided are echoed too, still alphabetically — a
VideoDecoderConfig with `codedWidth`, `codedHeight`, `description` and
`optimizeForLatency` reads back
`{codec, codedHeight, codedWidth, description, flip, hardwareAcceleration, optimizeForLatency, rotation}`.
An unrecognised member (`nope: 1`) is **not** echoed. `description` is echoed as
the buffer object itself (`{}` through JSON.stringify).

Required members, alphabetical read order:

- `VideoDecoderConfig`: `codec` only. `codedWidth`/`codedHeight` are optional
  **but come as a pair**: one without the other rejects
  `Invalid config, codedWidth specified without codedHeight.` (note the comma
  after "config"), and a zero in either is `Invalid coded size (0, 240).`
- `VideoEncoderConfig`: `codec`, `height`, `width`. A zero in either size
  rejects `Invalid size; height and width must be greater than zero.`
- `AudioDecoderConfig`: `codec`, `numberOfChannels`, `sampleRate`. Zero rate is
  `Invalid sample rate; sample rate must be non-zero, received 0.`
- `AudioEncoderConfig`: `codec`, `numberOfChannels`, `sampleRate`.

`hardwareAcceleration`'s enum is named **`HardwarePreference`**, not
HardwareAcceleration: `{hardwareAcceleration:'nope'}` rejects
`Failed to read the 'hardwareAcceleration' property from 'VideoDecoderConfig':
The provided value 'nope' is not a valid enum value of type HardwarePreference.`

`vorbis` and `flac` on AudioDecoder reject `Invalid config; description is
required.` (semicolon this time) rather than answering supported:false.

## The supported-codec matrix

This is machine-specific — it is what a Chrome 150 on this macOS box reports,
and it is the interesting part for a detector, which can enumerate it.

**Video, identical for VideoDecoder and VideoEncoder.** True for exactly `vp8`
and anything starting `vp09.`, `avc1.`, `av01.`, `hev1.`, `hvc1.`. False for
`vp9`, `h264`, `theora`, `mp4v.20.8`. Matching is **case-sensitive**: `VP8`,
`Vp8`, `AVC1.42E01E` and `VP09.00.10.08` are all false.

**AudioDecoder.** True: `opus`, `mp3`, `mp4a.40.2`, `mp4a.40.5`, `alaw`, `ulaw`,
`pcm-u8`, `pcm-s16`, `pcm-s24`, `pcm-s32`, `pcm-f32`. False: `aac`. Rejects
(description required): `vorbis`, `flac`.

**AudioEncoder.** True: `opus`, `mp4a.40.2`, `mp4a.40.5`. False: everything else
tested, including `mp3`, `vorbis`, `flac`, the pcm family and `alaw`/`ulaw`.

**Audio case sensitivity is mixed**, which is worth reproducing literally:
`Opus`, `PCM-S16` and `ALAW` are all **true**, while `MP3` and `Mp4a.40.2` are
**false**. So the opus / alaw / ulaw / pcm-\* names compare case-insensitively
and the mp3 / mp4a.40.\* ones do not.
