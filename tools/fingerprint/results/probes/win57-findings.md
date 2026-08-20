# Batch 19 / P1 — EME + Media Source + media-capture family, measured

Probe: `probe-win57.js`. Chrome 150 headed at `http://localhost:8731/` (secure
context, `isSecureContext` true). lightpanda via `run-page-probe.mjs` off the
batch-19 worktree build. Raw: `win57-chrome.json` / `win57-lp.json`.

## Scope: the CreepJS table is the floor, and here it is also the ceiling

The CreepJS missing-key list is built against Chrome 115, so every batch has to
re-measure before trusting it. This time it came out exact: all 16 names it
lists still exist on Chrome 150, and the three plausible neighbours I probed for
are **not** on this build — `ManagedMediaSource`, `ManagedSourceBuffer`,
`PhotoCapabilities`, `MediaKeysPolicy` are all `ABSENT` in Chrome too. So the
batch is exactly the 16, no more.

Present in lightpanda already: `MediaSource`, `MediaSession`, `MediaStream`,
`MediaStreamTrack`, `MediaRecorder`. Everything else in the family is a
`ReferenceError`.

## Chrome shapes (prototype own-property order is the JsApi declaration order)

| interface | arity | proto chain | prototype own props (in order) |
|---|---|---|---|
| `MediaKeys` | 0 | Object.prototype | `createSession setServerCertificate constructor getStatusForPolicy` |
| `MediaKeySession` | 0 | EventTarget | `sessionId expiration closed keyStatuses onkeystatuseschange onmessage close generateRequest load remove update constructor` |
| `MediaKeyStatusMap` | 0 | Object.prototype | `size get has entries forEach keys values constructor` + `@@iterator` |
| `MediaKeySystemAccess` | 0 | Object.prototype | `keySystem createMediaKeys getConfiguration constructor` |
| `MediaKeyMessageEvent` | 2 | Event | `messageType message constructor` |
| `MediaEncryptedEvent` | 1 | Event | `initDataType initData constructor` |
| `SourceBuffer` | 0 | EventTarget | `mode updating buffered timestampOffset appendWindowStart appendWindowEnd onupdatestart onupdate onupdateend onerror onabort abort appendBuffer changeType remove constructor` |
| `SourceBufferList` | 0 | EventTarget | `length onaddsourcebuffer onremovesourcebuffer constructor` + `@@iterator` |
| `MediaSourceHandle` | 0 | Object.prototype | `constructor` (empty interface) |
| `MediaMetadata` | 0 | Object.prototype | `title artist album artwork chapterInfo constructor` |
| `MediaStreamTrackGenerator` | 1 | **MediaStreamTrack** | `writable constructor` |
| `MediaStreamTrackProcessor` | 1 | Object.prototype | `readable totalFrames discardedFrames constructor` |
| `ImageCapture` | 1 | Object.prototype | `track getPhotoCapabilities getPhotoSettings grabFrame takePhoto constructor` |
| `CanvasCaptureMediaStreamTrack` | 0 | **MediaStreamTrack** | `canvas requestFrame constructor` |
| `VideoPlaybackQuality` | 0 | Object.prototype | `creationTime totalVideoFrames droppedVideoFrames corruptedVideoFrames constructor` |
| `RemotePlayback` | 0 | EventTarget | `state onconnecting onconnect ondisconnect cancelWatchAvailability prompt watchAvailability constructor` |

Constructible from script: only `MediaMetadata` (arity 0),
`MediaKeyMessageEvent` (2), `MediaEncryptedEvent` (1),
`MediaStreamTrackGenerator` (1), `MediaStreamTrackProcessor` (1),
`ImageCapture` (1). The other ten are illegal constructors.

`MediaSource` also needs shape work: Chrome's order is `sourceBuffers
activeSourceBuffers duration onsourceopen onsourceended onsourceclose
readyState addSourceBuffer clearLiveSeekableRange endOfStream
removeSourceBuffer setLiveSeekableRange constructor`.

## Behaviour worth copying

**EME.** `requestMediaKeySystemAccess` resolves for both `org.w3.clearkey` and
`com.widevine.alpha` on a plain headed Chrome; an unknown key system gives
`NotSupportedError: Unsupported keySystem or supportedConfigurations.`, and an
empty `supportedConfigurations` array gives a **TypeError** (`The
supportedConfigurations parameter is empty.`), not a DOMException. Our engine
currently has the method with the right arity but it rejects `NotSupportedError`
unconditionally (`Navigator.zig:526`).

`getConfiguration()` echoes back a normalised dictionary, not the input:

```json
{"audioCapabilities":[],"distinctiveIdentifier":"not-allowed","initDataTypes":["cenc"],
 "label":"","persistentState":"not-allowed","sessionTypes":["temporary"],
 "videoCapabilities":[{"contentType":"video/mp4; codecs=\"avc1.42E01E\"",
                       "encryptionScheme":null,"robustness":""}]}
```

A fresh session: `sessionId` is `""`, `expiration` is `NaN`, `keyStatuses.size`
is 0, `closed` is a Promise. `setServerCertificate` resolves **false**.
`createSession('nope')` is a TypeError naming `MediaKeySessionType`.
`generateRequest()` with no args is "2 arguments required".  `load('')` is
"The sessionId parameter is empty."  `update`/`remove` before a request:
`InvalidStateError: ... The session is not callable.`  `video.setMediaKeys(keys)`
resolves and `video.mediaKeys === keys` afterwards.

**MSE.** A detached MediaSource is `closed`, `sourceBuffers` is an empty
`SourceBufferList`, `handle` is **undefined** (it is worker-only — so
`MediaSourceHandle` exists as a global while `ms.handle` is undefined, which is
what we should reproduce), and `addSourceBuffer` throws `InvalidStateError`.
Attached via `URL.createObjectURL`, it opens, `duration` is NaN, and a
`SourceBuffer` comes back with `mode="segments" updating=false
buffered=[object TimeRanges] timestampOffset=0 appendWindowStart=0
appendWindowEnd=Infinity` and all five handlers null. `activeSourceBuffers`
stays 0 until data is appended.

**MediaMetadata.** `new MediaMetadata()` gives `""`/`""`/`""`/`[]`. Artwork
entries are normalised to `{sizes, src, type}` with `""` defaults and the array
is **frozen**. A member without `src` throws a TypeError naming the
`MediaImage`/`MediaMetadataInit` chain. `navigator.mediaSession.metadata` is
null by default (ours agrees) and must accept a MediaMetadata.

**Breakout box.** `new MediaStreamTrackGenerator({kind:'video'})` gives a
MediaStreamTrack subclass with `kind='video'` and `writable` = a
`WritableStream`. A bad kind is `TypeError: Invalid track generator kind` — note
the bare message, not the WebIDL enum wording.

**Capture.** `canvas.captureStream()` gives a `MediaStream` whose sole video
track is a `CanvasCaptureMediaStreamTrack` with `.canvas` pointing back at the
element and a `requestFrame()`. `new ImageCapture(track)` succeeds off that
track and `ic.track === track`. `new ImageCapture({})` is `parameter 1 is not of
type 'MediaStreamTrack'`.

**RemotePlayback.** `video.remote` is a RemotePlayback, `state` is
`disconnected`, `watchAvailability()` with no args is "1 argument required",
with a callback it resolves to a **number** id, `cancelWatchAvailability()`
resolves, and `prompt()` rejects `InvalidAccessError: ... requires user
gesture.`  `video.disableRemotePlayback` is false.

**VideoPlaybackQuality.** `video.getVideoPlaybackQuality()` works on a video
with no source: `creationTime` is a DOMHighResTimeStamp, the other three counts
are 0.

## Harness note

The first run of this probe died on lightpanda the way batch 18's did: an
ungated `await` on an absent API rejected the whole top-level promise, the
`@@PROBE@@` marker never reached the DOM, and `run-page-probe.mjs` happily
base64-decoded the marker's own string literal out of the page source and
printed 50 bytes of garbage — exit code 0, no error. The fix is in the probe:
every async section goes through a `sect()` wrapper that catches, and each one
early-returns `'ABSENT'` when its entry point is missing. Worth keeping as the
default shape for these probes.
