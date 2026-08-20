# Batch 16 (WebGPU) — behaviour ground truth

Measured on a headed Chrome 150, macOS, Apple GPU / `metal-3`.
Raw data: `win37-chrome.json` (shapes + reachable values), `win38-chrome.json`
(behaviours). Probes: `probe-win37.js`, `probe-win38.js`.

## WebGPU is reachable on this machine

`navigator.gpu.requestAdapter()` returns a real adapter. So the values below are
measured, not invented — which is what removed the original reason for having
`GPU.requestAdapter` resolve null ("implementing GPUAdapter would mean inventing
a GPU's limits").

## GPUSupportedFeatures iteration order is NOT stable

The 22-name **set** is fixed. The **order** is not: asking the same page for
three adapters in a row returns three different orders. Two clusters permute,
everything else stays put:

- indices 2–3: `{texture-formats-tier1, bgra8unorm-storage}`
- indices 15–18: `{shader-f16, texture-formats-tier2, clip-distances, timestamp-query}`

Verified across two separate browser launches, three `requestAdapter()` calls
each (`allSame` false both times, same two clusters).

**Consequence:** the order cannot be a fingerprint a detector relies on, and any
one observed order is as authentic as another. Do NOT write "the order is itself
a hashable surface" for this set — that claim is false. Match the *set*.

(This is unlike `Object.getOwnPropertyNames(X.prototype)` order, which *is*
stable and *is* worth transcribing verbatim.)

## An adapter is single use

The second `requestDevice()` on the same GPUAdapter rejects:

```
OperationError: Failed to execute 'requestDevice' on 'GPUAdapter': adapter is "consumed": it has already been used to create a device
    at CreateDeviceInternal (../../third_party/dawn/src/dawn/native/Adapter.cpp:328)
```

Note the Dawn source location is part of the message. This broke the first run of
`probe-win38.js` — every `requestDevice` probe needs its own fresh adapter.

## Object identity

| what | result |
|---|---|
| `requestAdapter()` twice | **different** adapter objects |
| `adapter.features` / `.limits` / `.info` re-read | same object each time |
| `device.queue` / `.adapterInfo` / `.lost` re-read | same object each time |
| `device.adapterInfo` vs `adapter.info` (same adapter) | **different** objects |
| `'requestAdapterInfo' in adapter` | false (Chrome dropped it) |

## Device

- `features` = `['core-features-and-limits']` only; an accepted `requiredFeatures`
  entry is **appended after** it (`['shader-f16']` → `core-features-and-limits,shader-f16`).
- `label` defaults to `''` and is writable; `requestDevice({label:'lp'})` → `'lp'`.
- `lost` is pending while the device is alive; after `destroy()` it **resolves**
  (not rejects) with `GPUDeviceLostInfo {reason:'destroyed', message:'Device was destroyed.'}`.
- `onuncapturederror` defaults to `null`. `device instanceof EventTarget` is true.
- `limits` on a device is the *smaller* default set even when the page asked for
  more — requiredLimits is validated, not honoured observably.

## Argument handling (exact messages)

`requestAdapter`:
- `undefined` / `null` / `{}` / `{nope:1}` / `{powerPreference:'low-power'}` → an adapter
- `{forceFallbackAdapter:true}` → **null**
- `'nope'` → `TypeError: Failed to execute 'requestAdapter' on 'GPU': The provided value is not of type 'GPURequestAdapterOptions'.`
- `{powerPreference:'nope'}` → `TypeError: Failed to execute 'requestAdapter' on 'GPU': Failed to read the 'powerPreference' property from 'GPURequestAdapterOptions': The provided value 'nope' is not a valid enum value of type GPUPowerPreference.`

`requestDevice`:
- `{requiredFeatures:['nope']}` → `TypeError: ... Failed to read the 'requiredFeatures' property from 'GPUDeviceDescriptor': The provided value 'nope' is not a valid enum value of type GPUFeatureName.`
- `{requiredLimits:{maxBufferSize:1e12}}` → `OperationError: ... Required limit (1000000000000) is greater than the supported limit (4294967292).\n - While validating maxBufferSize\n - While validating required limits\n`
- `{requiredLimits:{nope:1}}` → `OperationError: ... The limit "nope" with a non-undefined value is not recognized.`

## The six constructible error types

`GPUValidationError` / `GPUOutOfMemoryError` / `GPUInternalError` — arity 1, extend
`GPUError`:
- `new C('boom').message === 'boom'`; `new C(5).message === '5'`
- `String(e)` is `[object GPUValidationError]` — these are **not** `Error`
  instances, and `e.stack` is undefined
- no own properties; `message` lives on `GPUError.prototype`
  (`getOwnPropertyNames(GPUError.prototype)` → `message,constructor`)

`GPUPipelineError` — arity 1, extends **DOMException**:
- `new GPUPipelineError('boom', {reason:'validation'})` → `name` `'GPUPipelineError'`,
  `code` `0`, `String(e)` `'GPUPipelineError: boom'`, no own props, is an `Error`
- `options` is the **required** argument, `message` is optional. Omitting it, or
  passing the options object as the first argument, gives
  `TypeError: Failed to construct 'GPUPipelineError': The provided value is not of type 'GPUPipelineErrorInit'.`
- `{}` → `... Failed to read the 'reason' property from 'GPUPipelineErrorInit': Required member is undefined.`
- `{reason:'nope'}` → `... The provided value 'nope' is not a valid enum value of type GPUPipelineErrorReason.`

`GPUUncapturedErrorEvent` — arity 2, extends `Event`:
- `bubbles` false, **`cancelable` true**, `composed` false; own props `isTrusted`
- one argument → `TypeError: Failed to construct 'GPUUncapturedErrorEvent': 2 arguments required, but only 1 present.`
- `{}` → `... Failed to read the 'error' property from 'GPUUncapturedErrorEventInit': Required member is undefined.`
- `{error:5}` → `... Failed to convert value to 'GPUError'.`

## Other

- `navigator.gpu.getPreferredCanvasFormat()` → `'bgra8unorm'`
- `canvas.getContext('webgpu')` → a `GPUCanvasContext` whose `.canvas` is the canvas
- `pushErrorScope('validation')` + a bad `createBuffer` + `popErrorScope()` yields a
  real `GPUValidationError`: `Buffer usages must not be 0.\n - While calling [Device].CreateBuffer([BufferDescriptor]).\n`
- `GPUTextureUsage.TRANSIENT_ATTACHMENT` (0x20) is in Chrome 150 but not the spec.

## Engine-side note (not WebGPU)

`tools/fingerprint/README.md` claims Option cannot share a prototype because the
vendored v8 bindings do not export `SetPrototypeProviderTemplate`. That reason is
false: it is declared in the vendored `src/binding.h:942` and
`nm -gU v8/libc_v8.a` shows `_v8__FunctionTemplate__SetPrototypeProviderTemplate`
as an exported `T`. Whether using it actually reproduces Chrome's shape is still
unverified.
