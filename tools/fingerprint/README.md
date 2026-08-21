# Fingerprint measurement harness

Measures what this browser looks like to a fingerprinting script, and diffs it
against the real Google Chrome installed on the same machine. Used to produce
the *before* baseline and, after the masking work lands, the *after* table.

## Run

```bash
zig build -Dprebuilt_v8_path=v8/libc_v8.a        # the collector needs zig-out/bin/lightpanda

node tools/fingerprint/collect-lightpanda.mjs                  # -> results/before-lightpanda.json
node tools/fingerprint/collect-chrome.mjs                      # -> results/reference-chrome-headless.json
node tools/fingerprint/collect-chrome.mjs --headed             # -> results/reference-chrome-headed.json

node tools/fingerprint/diff.mjs \
  tools/fingerprint/results/before-lightpanda.json \
  tools/fingerprint/results/reference-chrome-headed.json \
  --out tools/fingerprint/results/before-vs-chrome.md

node tools/fingerprint/detector-sweep.mjs lightpanda   # -> results/detectors-lightpanda.json
node tools/fingerprint/detector-sweep.mjs chrome       # -> results/detectors-chrome.json
```

Node >= 22 only, no npm dependencies (global `WebSocket` and `fetch`).

## What each piece does

| file | role |
|---|---|
| `cdp.mjs` | ~100-line raw CDP client. Both engines go through it, so a difference in the snapshot comes from the engine, not from a driver. |
| `probe.js` | One async expression collecting ~90 fingerprint surface values. Every read is wrapped, so "this property throws" is recorded as data instead of aborting the run. |
| `header-echo.mjs` | Raw-TCP HTTP server that records the byte-exact request head. `node:http` reorders headers, and header order is itself part of the fingerprint. Serves a page pulling one of every fetch destination (document, style, script, image, iframe, fetch, xhr). |
| `sites.mjs` | URLs + in-page extractors for bot.sannysoft.com and CreepJS, plus the twelve-site detector list the sweep walks. |
| `antibot-sweep.mjs` | Walks the commercial guards in `sites.mjs` (`ANTIBOT`) and records whether each one served the site or served a challenge. The detectors above *report* a fingerprint; these *act* on one, so the reading is the document's HTTP status plus the interstitial's own marks, not a verdict string. `--fresh` gives each station its own engine process, `--trace` records every request and console line for one. |
| `detector-sweep.mjs` | Walks every detector in `sites.mjs` and records how far each page got — nodes, text length, verdict words, and whether the navigation happened at all. Answers "does the detector finish", which the collectors do not. |
| `subresource-check.mjs` | Answers "did the request happen at all", per fetch destination. Exits non-zero on a miss. Takes engine flags after `--`. |
| `collect-*.mjs` | Spawn the engine, run the four steps, write one JSON snapshot. |
| `dump-voices.mjs` | Regenerates `src/browser/webapi/speech/voices.zig` from the real Chrome's `speechSynthesis.getVoices()`. The list arrives asynchronously, so it polls until it stops growing and refuses to write an empty table. |
| `dump-graphics.mjs` | Dumps Chrome's *whole* graphics API surface — every GLenum, every method's arity, every `getParameter` answer, every character's advance width. `probe.js` asks "what does a fingerprinting script see"; this asks "what exactly should we report". The Zig code under `src/browser/webapi/canvas/` is transcribed from its output. |
| `diff.mjs` | Renders a candidate/reference markdown comparison. |
| `run-expr.mjs` | Evaluates one expression file against either engine and prints the result as JSON. The collectors walk a fixed property list; this answers a one-off "what does Chrome say about X", and the answer to "are we aligned" is the diff of the two outputs. |
| `probes/` | The expression files the sections below cite by name, and what `run-expr.mjs` takes. |
| `run-probe.mjs` | Runs one `probe-*.js` on either engine and prints the result as JSON. Takes a url, because `about:blank` is not a secure context and this engine does not run scheduled tasks under an outstanding `awaitPromise` evaluate — a probe that awaits a timer needs a real page. |
| `run-page-probe.mjs` | Runs a probe on this engine as a *page load* rather than through CDP, for the same timer reason. `lightpanda fetch --dump` decides the load is over somewhere between two and six seconds, so this is the short-probe path; anything with a longer wait budget belongs on `run-probe.mjs`. |
| `webrtc-protochain.mjs` | Ground truth for every `RTC*` global: prototype chain, class-side inheritance, the window property descriptor, and the exact `TypeError` text for a few argument shapes. |
| `webrtc-worker-surface.mjs` | The same question for a `DedicatedWorkerGlobalScope` — which `RTC*` names a worker carries, and the full shape of each. |
| `run-iphey.mjs` | Reproduces iphey's `i20: TypeError: Illegal invocation` and attributes it, by patching `alert()` to record a stack and wrapping the reflection entry points so a throw names its receiver. |

## Two things to know before trusting a result

**Never verify with screenshots.** `Page.captureScreenshot` in this engine
returns a fixed `@embedFile` placeholder PNG (see `src/cdp/domains/page.zig`),
and `Page.printToPDF` likewise. An image proves nothing here; everything in this
harness reads the DOM or the wire instead.

**lightpanda allows one browser context at a time** — a second
`Target.createBrowserContext` fails with `Cannot have more than one browser
context at a time`, so the collectors reuse a single page across all four steps.

## Header-layer status (after P3)

On the document request, 13 of Chrome's 14 headers are now present, up from 6:

| | before | after |
|---|---|---|
| headers present | 6/14 | 13/14 |
| missing | `Connection`, `Sec-Ch-Ua-Mobile`, `Sec-Ch-Ua-Platform`, `Upgrade-Insecure-Requests`, `Sec-Fetch-Site/Mode/User/Dest` | `Connection` |
| headers Chrome doesn't send | none | none |

All three gaps at this layer are closed, and the closure is measured the same
way the gaps were: `collect-lightpanda.mjs`'s `localHeaders` step against the
same echo server the Chrome capture used. **Nine of nine probe paths now match
Chrome 151's header order byte for byte** — navigation, iframe, stylesheet,
script, image, favicon, xhr, fetch and a second navigation.

1. **Header order.** Chrome's order is not one order: a navigation leads with
   the three client hints, a subresource leads with `sec-ch-ua-platform` and
   `User-Agent` and only then repeats `sec-ch-ua` / `sec-ch-ua-mobile`. Neither
   is insertion order, and `Referer` arrives after the transfer exists, so the
   list is materialised through a per-destination order table
   (`Transfer.emitHeaders`, with `chrome_navigation_order` and
   `chrome_subresource_order` beside it) rather than by ordering the slist.
2. **`Accept-Encoding` position.** curl wrote it second, one slot after `Host`,
   where Chrome has it second to last. We send it ourselves now: curl skips its
   own copy once the header list carries one (`Curl_checkheaders`), and response
   decoding is gated on `CURLOPT_ACCEPT_ENCODING` being *set* rather than on
   curl having written the header — so the position moves and the body still
   arrives decompressed. One constant (`http.accept_encoding`) feeds both, so
   what we advertise and what curl decodes cannot drift.
3. **`Connection: keep-alive`.** Sent. The version-awareness the old note asked
   for turned out to be curl's already: `h2_permissible_field` drops
   `Connection` when it converts the request to HTTP/2, which is also what
   Chrome does. The vendored curl's `http_hd_t` order moved
   `H1_HD_CONNECTION` to follow `H1_HD_HOST` so the field lands where Chrome
   puts it.
4. **`zstd`.** Advertised, and decodable: libzstd (decoder only) is linked into
   curl via `buildZstd` in build.zig, with `HAVE_ZSTD` set. The test server's
   `/zstd` endpoint answers with a real zstd frame and
   `tests/net/xhr.html#xhr_zstd_response` asserts the page reads it back as
   plain text -- advertising an encoding we could not decode would be worse than
   omitting it.

One residual, worth naming: Chrome's subresource order was measured on one page
shape (the echo harness pulling one of each destination). A page that produces a
destination the harness does not cover would be ordered by the same table, not
by a fresh measurement.

## Subresource status (after S1–S3)

The two engine-level gaps P3 turned up — stylesheets and images never being
requested *at all* — are closed. `subresource-check.mjs` drives a page pulling
one of every fetch destination and reports what reaches the server:

| | after P3 | after S1–S3 |
|---|---|---|
| destinations requested | 5/8 | **8/8** |
| missing | `stylesheet`, `image`, `favicon` | none |

- **stylesheet** — the fetch already existed but was opt-in. The flag was
  inverted to `--disable-external-stylesheets` so CSS loads by default.
- **image** — new. `ResourceType.image` plus `Frame.loadImage`, which requests
  and discards the body; there is no decoder and none is needed.
- **favicon** — new. Requested once per top-level navigation after everything
  else, honouring `<link rel=icon>` and otherwise falling back to
  `/favicon.ico`.

Header values on those requests match the Chrome reference exactly: across all
eight destinations, all 40 compared values (`Accept`, `Sec-Fetch-Dest/Mode/Site`,
`Referer`) are identical to `reference-chrome-headed.json`, and no destination
sends a header Chrome doesn't.

The three gaps above are unchanged by this work and are the only remaining
differences on subresource requests too: every one still lacks `Connection`,
still orders headers differently, and still omits `zstd`. Nothing in the JS
probe moved either (33/90, 11 sannysoft FAILs) — this was a network-layer
change only.

## What the navigator work changed (P4)

Measured with `after-p4-lightpanda.json` against `reference-chrome-headed.json`;
the full table is `after-p4-vs-chrome.md`.

| | after subresources | after navigator |
|---|---|---|
| probe keys identical to Chrome | 33/90 | **52/90** |
| bot.sannysoft.com FAIL rows | 11 | **7** |

The seven that remain are all graphics: `WebGL Vendor`, `WebGL Renderer` and
`Canvas1`..`Canvas5`. Every non-graphics row sannysoft runs now passes,
including `Chrome (New)`, `HEADCHR_CHROME_OBJ`, `HEADCHR_PLUGINS`,
`Plugins Length`, `Plugins is of type PluginArray` and `CHR_BATTERY`.
`CHR_MEMORY` also flipped to pass without `performance.memory` being
implemented — observed, not explained.

What was added, all of it measured off the Chrome 150 install on this machine
rather than recalled — property attributes, prototype member lists and object
identity relations included:

- `navigator.plugins` / `navigator.mimeTypes` — Chrome's five hardcoded PDF
  viewer aliases and two MIME types. `JSON.stringify(navigator.plugins)` now
  produces the same string Chrome does.
- `window.chrome` — an ordinary object (not a platform object), with `app`,
  `csi` and `loadTimes` as own properties whose values are native functions.
- `navigator.connection`, `navigator.mediaDevices`, `navigator.getBattery`.
- Chrome's user-agent, client-hint brands and `appVersion` as the *defaults*.
  The four now derive from one version constant, so they cannot disagree.

Two residual differences worth knowing about:

- `navigator.userAgentData.getHighEntropyValues` returns `platformVersion: ""`
  where Chrome reports the OS version (`26.3.1` here). Reading it needs a
  platform-specific syscall. Everything else in that dictionary matches,
  including that only *requested* hints come back and that the hint is named
  `formFactors`, not `formFactor`.
- `hardwareConcurrency` (8) and `deviceMemory` (8) are deliberately fixed, so
  they differ from whatever the host really has — 10 and 16 on this machine.
  A fleet sharing one pair was preferred over fingerprinting differently on
  every machine.

The three header-layer gaps below are untouched by this work and still apply.

## Reference caveats

`--headless=new` Chrome 150 on this machine differs from headed Chrome in
exactly four probe values, so `reference-chrome-headed.json` is the column to
target:

- `navigator.userAgent` / `appVersion` say `HeadlessChrome` instead of `Chrome`
- `window.outerWidth` / `outerHeight` reflect the smaller default viewport
- `screen.availTop` is `0` instead of `33` (no menu bar), `availHeight` differs
- `screen.colorDepth` / `pixelDepth` are `24` instead of `30`

WebGL is *not* one of them: headless Chrome on macOS still reports the real
Metal/ANGLE renderer, so the GPU strings in either reference file are usable
targets.

## Graphics layer (after P5, WebGL half)

`getContext('webgl')` used to answer `null`, so bot.sannysoft.com failed *WebGL
Vendor* and *WebGL Renderer* outright, and `webgl.params` was absent from the
probe. All three now match Chrome:

| | before | after |
|---|---|---|
| `getContext('webgl' / 'webgl2' / 'experimental-webgl')` | `null`, `null`, `null` | `ok`, `ok`, `ok` |
| `getParameter(VENDOR)` | `""` | `WebKit` |
| `getParameter(UNMASKED_RENDERER_WEBGL)` | `""` | `ANGLE (Apple, ANGLE Metal Renderer: Apple M4, …)` |
| `getSupportedExtensions().length` | 39 (1.0 only) | 39 for 1.0, 36 for 2.0 |
| `WebGLRenderingContext.prototype` own properties | 4 | 441, the same as Chrome |
| `WebGL2RenderingContext` | absent | 790 own properties, the same as Chrome |
| sannysoft hard failures | WebGL Vendor, WebGL Renderer | none |

**Every value is measured, none recalled.** The WebGL spec pins the enum
numbering but says nothing about what a driver answers for `MAX_TEXTURE_SIZE`,
`SAMPLES` or the ANGLE renderer string — and those are exactly the values that
identify a machine. Run `dump-graphics.mjs` to regenerate
`results/reference-chrome-graphics.json`, then update the Zig to match. Two
values came out the *opposite* of what reasoning suggested, and only the
measurement caught them: a fence sync nothing was queued behind reports
`UNSIGNALED`, not `SIGNALED`, and a zero-timeout wait on it reports
`TIMEOUT_EXPIRED`, not `ALREADY_SIGNALED`.

Known deviations from Chrome at this layer, all deliberate:

1. **The handle types inherit from `Object`, not from `WebGLObject`.** In Chrome
   `Object.getPrototypeOf(WebGLBuffer.prototype) === WebGLObject.prototype`, and
   a `WebGLObject` global exists. Reproducing that means a chained-factory
   allocation per handle for a prototype link nothing calls.
2. **`isQuery` / `isVertexArray` / `isTransformFeedback` always answer `false`,
   and `isBuffer` / `isTexture` / … always answer `true` for a live handle.**
   Chrome's answer depends on whether the object was ever bound; we keep no
   binding state. The constants match the measured never-bound case.
3. **Nothing rasterizes.** A page that waits for WebGL output before revealing
   content waits forever rather than taking its no-WebGL path. This is the
   trade-off accepted in exchange for not being the only browser on the machine
   without WebGL; see the comment in `element/html/Canvas.zig`.
4. **`WebGLContextEvent` is not exposed**, so a script cannot construct one or
   find it on `window`. No `webglcontextlost` event is ever fired either, since
   the context is never lost.

## Graphics layer (after P5, canvas-2D half)

Measured with `after-p5-lightpanda.json` against `reference-chrome-headed.json`;
the full table is `after-p5-vs-chrome.md`.

| | after navigator | after graphics |
|---|---|---|
| probe keys identical to Chrome | 52/90 | **59/90** |
| bot.sannysoft.com FAIL rows | 7 | **0** |
| `CanvasRenderingContext2D.prototype` own properties | 42 (6 of them data properties) | **73, the same as Chrome, none a data property** |
| `canvas.toDataURL` | `TypeError: not a function` | `data:image/png;base64,iVBORw0K…` |
| `ctx.measureText` | `TypeError: not a function` | `89.9658203125` for `mmmmmmmmmmlli`, bit-identical to Chrome |
| `getImageData` after a red `fillRect` | `[0,0,0,0]` | `[255,0,0,255]` |

`subresource-check.mjs` still reports 8/8 destinations, so nothing regressed at
the network layer.

Three pieces landed:

- **A minimal rasteriser** (`webapi/canvas/raster.zig`). An RGBA8 buffer,
  `fillRect` / `clearRect` / `strokeRect` compositing into it source-over, and
  `getImageData` reading back out of it. Not a renderer and not becoming one.
- **A PNG writer** (`webapi/canvas/png.zig`) behind `toDataURL`, `toBlob` and
  `OffscreenCanvas.convertToBlob`.
- **Chrome's text metrics** (`src/browser/font_metrics.zig`, generated from the
  dump). `measureText` and `TextMetrics` reproduce Chrome exactly for printable
  ASCII, and the `font` attribute is parsed and normalised the way Chrome
  normalises it.

Verifying the PNG output deliberately used two decoders that are not ours:
node's `zlib` inflates the IDAT to bytes identical to what `getImageData`
reports for the same canvas, and macOS ImageIO (`sips`) reads the file back as
a 4x3 RGBA png.

Known deviations at this layer, all deliberate and all measured:

1. **Text does not rasterise, so a text-based canvas hash still differs.**
   sannysoft's Canvas1..Canvas5 went from `Canvas failed` to a hash, and the
   hash is stable and identical across all five the way Chrome's is — but it is
   our hash, not Chrome's. Landing Chrome's would need Chrome's font
   rasteriser. This is the trade-off accepted when option B was chosen over
   emitting a fixed PNG: two different drawings now produce two different
   strings, which is what every real browser does.
2. **The PNG bytes are ours, not Chrome's**, even for an empty canvas. Chrome
   drives libpng with a per-row filter heuristic, zlib at level 1 and a sync
   flush between passes; we write one IDAT, filter None, default level.
   Matching would mean reimplementing zlib's match finder for no gain while (1)
   stands.
3. **Only PNG is encoded.** `toDataURL('image/jpeg')` falls back to
   `image/png`, which the spec allows for an unsupported type but Chrome — with
   a JPEG encoder — does not do.
4. **No kerning.** `measureText('AV')` is 13.33984375 where Chrome kerns it to
   12.6025390625. None of the strings canvas fingerprints actually use are
   kerned; `mmmmmmmmmmlli`, `Hello, world!` and `Cwm fjordbank glyphs vext quiz`
   are all exact.
5. **Outside U+0020..U+007E there is no table**, so those glyphs are charged the
   family's mean ASCII advance. That number is a guess, and the only one in this
   layer.
6. **Rectangle edges snap to whole pixels** instead of antialiasing, so a
   fractional `fillRect` covers one pixel differently from Chrome.
7. **`ex` / `ch` / `q` and viewport units in a font shorthand are rejected**,
   as are the system font keywords (`caption`, `menu`, …). Chrome accepts them.
   Supporting them needs numbers we did not measure.
8. **`HTMLCanvasElement.captureStream` is still missing** — it needs a
   `MediaStream`, which does not exist in this engine.

### Regenerating the graphics ground truth

`dump-graphics.mjs` now also records, per family, every printable ASCII glyph's
advance *and ink box* at 100px, a sweep of `fontBoundingBox` across 1..120px,
the default value of all 28 2D context accessors, and how Chrome normalises 40
font shorthands. `src/browser/font_metrics.zig` is generated from it and says so
at the top; re-run the dumper before editing it by hand.

Two things the measurement caught that reasoning would not have:

- **`fontBoundingBox` is not linear in font size.** CoreText quantises it per
  size: 16px sans-serif reports an ascent of 14, where scaling the 100px value
  of 92 says 15. Hence the swept table rather than a ratio.
- **`hangingBaseline` is computed in single precision.** Chrome answers
  `10.399999618530273`, not `10.4`, for an ascent of 13 — so ours round-trips
  through `f32` on purpose.

Advances *are* exactly linear, and a string's width is the plain sum of its
glyphs', which is why one 100px table per family is enough. Accumulate at the
100px basis and scale once at the end: scaling each glyph first drifts by an ulp
over a long string, which is how the Arial pangram first came out
`196.86132812500003` instead of `196.861328125`.

## Transport layer (P6)

Everything above is what a *script* can read. A server sees a layer below that
one — the TLS ClientHello and the HTTP/2 preface — before a byte of HTTP is
exchanged, and JA3/JA4 and the Akamai HTTP/2 fingerprint turn it into an
identifier that no amount of `navigator` work can touch.

Measured with `collect-tls.mjs` against Chrome 150 on this machine. Because
Chrome permutes its ClientHello extensions per connection, every run takes
several samples and records which fields moved; a single JA3 proves nothing.

### TLS ClientHello

**On a normal network path the JA4 is byte-for-byte Chrome's, on every
connection** — `t13d1517h2_8daaf6152771_a87ad97598a9`, all three components,
12/12 samples, reproduced twice.

Measuring it from this machine's default route gives a worse number, 1/8, and
that turned out to be the network rather than the engine; the last section
explains how the two were told apart.


| | before | after | Chrome 150 |
|---|---|---|---|
| JA4 (clean network path) | `t13d1711h2_5b57614c22b0_95ca0cbbc74b` | **`t13d1517h2_8daaf6152771_a87ad97598a9`** | `t13d1517h2_8daaf6152771_a87ad97598a9` |
| cipher digest | `5b57614c22b0` | **`8daaf6152771`** | `8daaf6152771` |
| cipher suites offered | 17 | **15** | 15 |
| extensions offered | 11 | **18** | 19 |
| supported groups | X25519, P-256, P-384 | **GREASE, X25519MLKEM768, X25519, P-256, P-384** | same |
| GREASE | absent | **present** | present |
| JA3 across N connections | one value | **N values** | N values |

The cipher list, the cipher order and the supported-groups list are now
byte-identical to Chrome's, and JA3 varies per connection the way Chrome's
does — GREASE and extension permutation are switched on in BoringSSL rather
than simulated, so the variation has Chrome's distribution and not ours.

Seven extensions were added, six of which libcurl has no reason to send:
`status_request` (5), `signed_certificate_timestamp` (18),
`compress_certificate` (27, Brotli), `session_ticket` (35),
`application_settings` (0x44cd, the newer ALPS code point Chrome uses) and a
GREASE `encrypted_client_hello` (0xfe0d). The `padding` (21) extension libcurl
was sending and Chrome was not disappears on its own once the hello is long
enough. Two of these — ALPS and ECH — have no `SSL_CTX`-level setter, so they
are applied from an info callback at `SSL_CB_HANDSHAKE_START`, which BoringSSL
runs before the hello is built.

Two differences remain, both measured:

1. ~~Chrome offers ML-DSA signature algorithms this BoringSSL cannot name.~~
   **Closed.** BoringSSL is now pinned at `7515be5c`, which has
   `SSL_SIGN_ML_DSA_44`/`_65`/`_87`, and the hello offers all eleven of
   Chrome's signature algorithms in Chrome's order. The wrapper that pins the
   revision is carried in `deps/boringssl-zig/`; see the README there.
2. ~~`pre_shared_key` (41) is usually absent.~~ **Not ours.** Session
   resumption works; the local network path was eating the resumed handshake.
   See the last section.

### HTTP/2

| | before | after | Chrome 150 |
|---|---|---|---|
| Akamai fingerprint | `3:100;4:65536;2:0\|1048510465\|0\|m,s,a,p` | `1:65536;2:0;4:6291456;6:262144\|15663105\|0\|m,a,s,p` | identical to after |
| Akamai hash | — | **`52d84b11737d980aef856699f885ca86`** | `52d84b11737d980aef856699f885ca86` |
| SETTINGS | MAX_CONCURRENT_STREAMS=100, INITIAL_WINDOW_SIZE=65536, ENABLE_PUSH=0 | **HEADER_TABLE_SIZE=65536, ENABLE_PUSH=0, INITIAL_WINDOW_SIZE=6291456, MAX_HEADER_LIST_SIZE=262144** | same |
| connection WINDOW_UPDATE | 1048510465 | **15663105** | 15663105 |
| pseudo-header order | `:method :scheme :authority :path` | **`:method :authority :scheme :path`** | same |

All three values are hardcoded in libcurl with no runtime option, so this
needed a patched libcurl. Two files are carried in `deps/curl-patched/` and
swapped into the build in place of the dependency's copies:

- `lib/http2.c`, `populate_settings()` — Chrome's four SETTINGS entries in
  Chrome's order instead of upstream's three.
- `lib/http2.c`, `H2_STREAM_WINDOW_SIZE_INITIAL` and `HTTP2_HUGE_WINDOW_SIZE`
  — the stream and connection windows, hence the announced
  `INITIAL_WINDOW_SIZE` and the `WINDOW_UPDATE` increment.
- `lib/http.c`, `Curl_http_req_to_h2()` — `:authority` before `:scheme`.

Each hunk is marked `LIGHTPANDA:` in the source and explained, with re-sync
instructions, in `deps/curl-patched/README.md`.

Flow control was the risk in widening the windows, so the check that matters is
a large body: an 8.9 MB script over HTTP/2 arrives complete, alongside ten
smaller origins across six CDNs.

### The resumed handshake, and why it looked like our bug (P9)

Symptom: fetches to `tls.peet.ws/api/all` failed about every other time with a
bare `TypeError: fetch error`, and `pre_shared_key` — the extension that is the
whole difference between our JA4 and Chrome's — almost never appeared.

libcurl's verbose log (flip `ENABLE_DEBUG` in `src/network/http.zig`) gives the
mechanism: that endpoint sends `GOAWAY` after every response, so the next
request must open a new connection; libcurl reuses the cached TLS session on it
(`SSL reusing session with ALPN 'h2'`); the resumed handshake then dies with
`SSL_ERROR_SYSCALL` and an empty error queue — the peer closing mid-handshake;
libcurl reports that rather than retrying without the session; the failure
evicts the session, so the next attempt does a full handshake and succeeds.
Hence the alternation.

Two candidates were ruled out by experiment rather than argument: disabling the
ALPS/ECH info callback left the resumed handshake failing three times in four,
and Chrome over the same path fetched the same endpoint 12/12 with a PSK every
time. That pointed at our resumed hello being at fault.

**It was not.** The decisive test was an A/B of the same binary over two network
paths, since this machine's default route goes through a local fake-IP tunnel
(libcurl reports the peer as `198.18.2.217` and the local address as
`198.18.0.1`, both inside `198.18.0.0/15`). Putting a plain SSH SOCKS proxy in
front takes that tunnel out of the path while leaving our own BoringSSL doing
the handshake:

```bash
ssh -f -N -D 127.0.0.1:1080 <some-host-with-a-normal-route>
lightpanda serve --http-proxy socks5h://127.0.0.1:1080
```

Twelve fetches each, run twice:

| | requests OK | resumed (PSK) | distinct JA4 |
|---|---|---|---|
| default route (fake-IP tunnel) | 7/12, then 6/12 | 1/7, then 0/6 | two |
| through the SOCKS proxy | 12/12, twice | **12/12, twice** | **one**, `t13d1517h2_8daaf6152771_a87ad97598a9` |

So session resumption works, the JA4 matches Chrome on every connection, and
the failures belong to the local tunnel — which mishandles *our* resumed
ClientHello while passing Chrome's. Why it treats the two differently is not
established and is not worth chasing: it is one machine's VPN, not something a
server on the internet sees.

The practical note for anyone measuring this engine: **measure from a clean
route.** A fake-IP tunnel in the path will make a correct ClientHello look
broken, and it will do it intermittently, which is the worst way to be wrong.

Two later findings, both from the detector sweep, sharpen that:

- **It is not only the resumed handshake.** A first connection to a host with no
  cached session fails the same way, `SSL_ERROR_SYSCALL` with an empty error
  queue, and the host it lands on drifts over the day.
- **Do not try to bisect it against the TLS profile.** Toggling
  `SSL_set_enable_ech_grease` looked like a clean isolation here — all three
  randomisation switches off gave 3/3 successful navigations, ECH GREASE alone
  gave failures again, and GREASE plus extension permutation without ECH gave
  4/4. Then restoring the file byte-for-byte and rebuilding gave 12/12
  successes on the same route. The baseline moves on its own, so nothing was
  isolated; the earlier claim in this section that disabling the ALPS/ECH
  callback "left the resumed handshake failing three times in four" is no more
  reliable than its opposite. Any A/B against this route needs the route itself
  as the control, which is what the SOCKS table above does.

## How far the detectors actually get

Everything above measures *values* — probe keys against real Chrome, JA4, the
Akamai fingerprint. Those do not depend on any detector agreeing with us. The
separate question is whether a detector page even runs to the end here, and it
gets its own tool (`detector-sweep.mjs`) because a browser that never returns a
fingerprint is a louder signal than one whose fingerprint is slightly wrong.

**First: three of the failures recorded here were the harness, not the engine.**
The original sweep was a script outside the repo that spawned lightpanda with
`stdio: ['ignore', 'pipe', 'pipe']` and never read the pipes. The engine logs
~550KB at the default level over twelve sites; a pipe nobody reads fills at
64KB, and the engine's next write blocks it for good. What that looks like from
the client is `Page.navigate` no longer returning and `Runtime.evaluate` timing
out — so iphey, pixelscan and browserscan were written down as sites that hang
the engine. They do not. Draining the two streams (one line) makes all three
finish, and the isolation is direct: same binary, same site order, same script,
only the child's stdio disposition changed.

That is worth stating plainly because the wrong conclusion was the confident
one: it reproduced identically on three consecutive runs.

**Second: run the sweep through a proxy.** `--proxy socks5h://…` is passed to
both engines, and on a machine whose default route is a fake-IP tunnel it is
mandatory, for the reason the previous section gives: the tunnel drops a
handshake now and then, the engine reports `SslConnectError`, and the site that
happens to be unlucky gets written down as broken. That is not a stable
attribution — over one afternoon here it hit browserscan five times out of nine
and browserleaks twice out of twelve, on the same binary, and a sweep an hour
later had neither. Through a plain SSH SOCKS proxy the same sequence navigated
24/24 with no TLS failure at all. **A `SslConnectError` in a sweep taken over
the default route is a measurement, not a finding.**

Both engines then walk the same list with the same settle times, Chrome 150 as
the control. `nodes` is elements in the document, `text` is `innerText` length.

| site | Chrome | this engine | |
|---|---|---|---|
| bot.sannysoft.com | 290 nodes / 15179 | 291 / 11377 | completes, 0 FAIL rows |
| CreepJS | 3756 / 4698 | 3724 / 41457 | completes, real FP ID (was 246 / 1347) |
| bot-detector.rebrowser.net | 98 / 1541 | 100 / 1664 | full table, 10 tests (was header only) |
| iphey.com | 487 / 7115 | 484 / 7099 | completes; both engines get `Looks Unreliable` |
| pixelscan.net | 1485 / 10607 | 1827 / 14653 | completes |
| amiunique.org/fingerprint | 1550 / 5836 | 1494 / 5741 | completes (was 381 / 1292) |
| tls.browserleaks.com/json | 7 / 1271 | 5 / 1263 | completes on a clean route |
| deviceandbrowserinfo.com/are_you_a_bot | 263 / 5780, `"isBot": true` | 235 / 5326 | renders the legend, not the verdict |
| browserscan.net | 1965 / 4071 | 1231 / 2073 | partial |
| browserleaks.com/javascript | 1180 / 9968 | 853 / 3486 | partial |
| arh.antoinevastel.com (×2) | 8 / 37 | 8 / 37 | endpoints are dead, not a datapoint |

**Eight of ten live detectors now run to completion, none hangs the engine.**
Baselines: `results/detectors-chrome.json`,
`results/detectors-partial-lightpanda.json` (clean route, current),
`results/detectors-after-lightpanda.json` (the earlier default-route sweep).

CreepJS is the one that now says something, since it finally renders its own
verdict: `25% like headless`, `0% headless`, `0% stealth`, with a stable
fingerprint ID. The `computed` flag in the collector snapshot goes from `false`
("Computing…") at P6 to `true`. The value-side numbers are unchanged by this
work — 59/90 probe keys and 0 sannysoft FAIL rows, same as P6
(`results/after-detectors-vs-chrome.md`) — which is the expected result: nothing
here changed a value Chrome and this engine already agreed on, it changed
whether the script that reads them survives.

### What was actually broken, and how it was found

Four engine gaps, each found by reading the page's own error rather than
guessing, and each verified by isolation before writing any Zig:

- **A request that outlived `--http-timeout` was reported to the page as its
  own timeout, and the default was 5s.** Two bugs stacked, and amiunique needed
  both fixed. curl answers `CURLE_OPERATION_TIMEDOUT` for the request's own
  timeout and for the engine-wide ceiling alike, and `XMLHttpRequest` dispatched
  `timeout` for both; with `xhr.timeout` left at 0 the spec has no timeout to
  fire and giving up is an ordinary network error. axios builds its message from
  `xhr.timeout`, so the page reported `timeout of 0ms exceeded` — a 0ms timeout
  is a contradiction, and that is what made it findable. Fixing the event type
  changed the symptom to a plain `Network Error` and nothing else, because the
  request really was being cut off: amiunique answers
  `POST /api/fingerprints` in ~21s. Chrome waits it out on the same route
  (20975ms there, 20661ms here) and puts no comparable ceiling on an ordinary
  request, so the default moved to 30s. The page now renders 1494 nodes against
  Chrome's 1550, up from 381.

- **The table mutation API did not exist.** `HTMLTableElement`,
  `HTMLTableSectionElement` and `HTMLTableRowElement` had their read side
  (`tBodies`, `rows`, `cells`, `deleteRow`) and none of the insertion methods.
  rebrowser's `renderDetections()` calls `tbody.insertRow(-1)` then
  `row.insertCell(n)`, which threw inside its first `addDetection` and aborted
  `window.onload` — one detection logged, empty table, nine tests never run.
  Confirmed before implementing by injecting a three-method JS polyfill: the
  full table appeared. `insertRow` / `insertCell` are now native.
- **`window.outerWidth` and friends were missing.** CreepJS computed its whole
  fingerprint (`Fingerprinting complete in 145ms`, `loose fingerprint passed`,
  `stable fingerprint passed`) and then painted none of it, because its screen
  panel reads `outerWidth` bare — an absent attribute is a ReferenceError, not
  a suspicious value, so the render pipeline died after the measurement
  succeeded. This is why "no uncaught exception, yet nothing rendered" looked
  contradictory: the throw was inside a promise chain. `outerWidth`,
  `outerHeight`, `screenX`, `screenY`, `screenLeft` and `screenTop` are now
  answered; CreepJS renders 3724 nodes with a real ID and its `headless`
  sub-test flipped to passing, since that one read `outerHeight` too.
- **`SVGTextContentElement.getExtentOfChar` was missing**, the one method
  CreepJS's `svg` sub-test calls that we did not have.

### What is still short, with the cause where it is known

- ~~**CreepJS `audio`**~~ **Partly closed, and the rest is a deliberate no.**
  `AudioContext` and its value layer now exist (see F1 below), which is what
  deviceandbrowserinfo needed. CreepJS's own audio sub-test still reads
  `blocked`, because it fingerprints through `OfflineAudioContext.startRendering`
  and there is no DSP here to render with. A constant buffer would hash to a
  value no real Chrome produces, so it stays absent on purpose.
- ~~**CreepJS `speech`**~~ **Closed (F3).** `speechSynthesis` and its four
  companion interfaces exist, `getVoices()` answers the measured 199-voice macOS
  list, and iphey's `ReferenceError` alert is gone.
- ~~**CreepJS `webgl`**~~ **Closed (F2).** `OffscreenCanvas.getContext` serves
  `webgl` and `webgl2`, on the main thread and in a worker.
- ~~**rebrowser's `bypassCsp` is red**~~ **Closed (F4).** The engine enforces
  the page's `script-src` for external script loads.
- ~~**`tls.browserleaks.com/json` navigation is intermittent**~~ **Closed: it
  was the route.** The failing navigations report `SslConnectError`, which is
  the fake-IP tunnel dropping a handshake — the same mechanism as P9, and it
  lands on whichever host is unlucky rather than on a particular one. Through a
  SOCKS proxy it commits every time. Nothing about a long sweep accumulating
  state was involved; the earlier note guessed at that and was wrong.
- **deviceandbrowserinfo renders the legend, not the verdict**: no
  `AudioContext`. `collectFingerprint()` reads
  `window.AudioContext || window.webkitAudioContext` and, two `try` blocks deep,
  does `if ("function" != typeof E) return void (r.audioFingerprint = t)`. That
  early return is why the function comes back `undefined` without throwing,
  which then makes `computeFingerprintHash(undefined)` throw
  `Cannot read properties of undefined (reading 'userAgent')` and the whole
  verdict panel never mounts. Found by planting recording getters on the
  `window.*` / `navigator.*` properties the body reads at known offsets and
  seeing which ones stop firing: the last was `AudioContext` at body offset
  14624, and `navigator.webdriver` at 15641 was never reached. Reading the
  minified source for top-level `return`s had missed it, because it is nested
  inside `try { try { … } } `. Same gap as the CreepJS `audio` item above, so
  one Web Audio stub closes both.
- **browserleaks.com/javascript renders 1039 nodes against Chrome's 1180** (853
  before F1–F3) with
  zero page errors and zero failed requests. It is not a broken script — the
  page renders one section per API family and the ones we do not implement come
  out empty. Closing it is API coverage measured section by section, not a bug
  to fix.
- **browserscan.net renders 1231 nodes against Chrome's 1965.** Navigation and
  scripts are fine on a clean route; what is missing has not been attributed to
  named APIs yet.

Two oddities worth keeping in view, neither of them a verdict:

- CreepJS's `innerText` here is 41457 characters against Chrome's 4698. More
  text, not less — the engine is very likely including content Chrome hides.
- `screen.width/height` are the viewport, so `innerWidth === screen.width` and
  `visualViewport` covers the screen exactly. CreepJS's `hasVvpScreenRes`
  headless heuristic fires on that regardless of what `outerHeight` says, which
  is why the window box was made to match the viewport (a fullscreen window)
  rather than inventing chrome that would not fit on the screen.

## Where the whole run landed (P7)

One table for the plan, each column a measured snapshot in
`results/`, all compared against the same `reference-chrome-headed.json`.

| | before | +subresources | +headers (P3) | +navigator (P4) | +graphics (P5) | +transport (P6) |
|---|---|---|---|---|---|---|
| probe keys identical to Chrome | 33/90 | 33/90 | 33/90 | 52/90 | 59/90 | **59/90** |
| bot.sannysoft.com FAIL rows | 11 | 11 | 11 | 7 | 0 | **0** |
| document headers present | 6/14 | 6/14 | 13/14 | 13/14 | 13/14 | **13/14** |
| subresource destinations requested | 5/8 | 8/8 | 8/8 | 8/8 | 8/8 | **8/8** |
| TLS cipher digest matches Chrome | no | no | no | no | no | **yes** |
| JA3 varies per connection | no | no | no | no | no | **yes** |
| HTTP/2 fingerprint matches Chrome | no | no | no | no | no | **yes** |
| JA4 matches Chrome (clean route) | no | no | no | no | no | **yes, 12/12** |

P6 moves nothing in the first four rows, which is the expected result: the
transport layer is invisible to a script, so a change there should leave the JS
surface untouched. It is listed to show it caused no regression.

The remaining 31 probe keys are enumerated in `after-p6-vs-chrome.md`; the
per-layer sections above say which are deliberate (`hardwareConcurrency`,
`deviceMemory`), which are missing APIs (`RTCPeerConnection`, `AudioContext`,
`speechSynthesis`), and which are known gaps with a measured cost.

## Closing the four API gaps (F1–F4)

The four items the previous section had listed as open — CreepJS's `audio`,
`speech` and `webgl` sub-tests, and rebrowser's red `bypassCsp` row — were taken
as one plan. Everything below was measured through a SOCKS proxy, with the
`main` binary and the branch binary run back to back on the same route, because
the machine's default route is the fake-IP tunnel from P9 and it blames whichever
host it drops.

The reference column is a **headed** Chrome
(`detectors-chrome-headed.json`, `detector-sweep.mjs chrome --headed`). Headless
is not a safe stand-in: some sites treat it differently, and its own APIs can
report differently. Where a row needed a Chrome measurement finer than the sweep
records, the probe is named.

| | before (`detectors-partial-lightpanda.json`) | after (`detectors-api-gaps-lightpanda.json`) | Chrome (headed) |
|---|---|---|---|
| deviceandbrowserinfo nodes | 235, no verdict panel | **262, verdict panel renders** | 263 |
| rebrowser `bypassCsp` | 🔴 "CSP was ignored … invalid behavior for a normal browser" | **🟢 "CSP is enabled, it's expected behavior"** | 🟢 |
| rebrowser nodes / verdict words | 100 / 7 | **98 / 6** | 98 / 6 |
| CreepJS WebGL sub-test | `images/pixels: blocked`, `params (0)`, `exts (0)` | **`images:55a7e17b`, `pixels:85d16b8a`, `params (78)`, `exts (75):901d2431`** | `exts (75): 901d2431` |
| CreepJS speech sub-test | `local (0)/remote (0)/lang (0): blocked` | **`local (180):a158dc36`, `remote (19):036f6dce`, `lang (51):c4951b20`** | the same three hashes, byte for byte — but only when something touches `speechSynthesis` early (see below) |
| CreepJS `blocked` rows, whole report | 20 | **13** | 3 |
| CreepJS nodes | 3724 | **4150** | 3756 |
| browserleaks.com/javascript nodes | 853 | **1039** | 1180 |
| amiunique nodes | 1494 | **1530** | 1550 |
| iphey `alert()`s | 2 (`i9` speechSynthesis, `i20`) | **1 (`i20` only)** | — |

No site in the twelve-site sweep lost content, which is the check that matters
for F4: a CSP implementation that is too strict shows up as a page that stops
rendering, and none did.

**F1 — `AudioContext`.** Seven types (`AudioContext`, `BaseAudioContext`,
`AudioNode`, `AudioDestinationNode`, `AnalyserNode`, `AudioListener`,
`AudioParam`), every value measured off Chrome 150 rather than remembered. This
was the highest-value item: deviceandbrowserinfo's `collectFingerprint()` returns
`undefined` the moment `typeof AudioContext != "function"`, and the whole verdict
panel hangs off that.

Deliberately absent at the time: `OfflineAudioContext`, and therefore no audio
*hash*. The reasoning was that the engine has no audio thread, so rendering it
would mean a fabricated constant buffer, and a constant audio hash matches no
real Chrome at all. **That decision was revisited in G17 batch 13-B and the
constructor now exists** — see the note under G17 below. The analyser's four
`get*Data()` calls report silence, which is not a fabrication: it is exactly what
Chrome returns for an analyser with nothing connected (byte frequency 0, byte
time-domain 128, float frequency `-Infinity`, float time-domain 0, all
measured).

`resume()` returns a promise that never settles and leaves the state
`suspended`, and `currentTime` stays 0. That is Chrome, measured on a headed
window as well as a headless one — still pending after 2s in both. The cause is
the autoplay policy, not a missing audio device: a context created by script with
no user gesture behind it never starts, which is the position every fingerprint
collector is in. `suspend()` and `close()` do resolve, also measured.

An earlier revision had `resume()` resolve and start a clock, on the theory that
the never-settling promise was a headless artefact. Measuring a headed window
disproved it, and the invented behaviour was removed.

**F2 — `OffscreenCanvas` WebGL.** The drawing surface of both WebGL contexts
became a union of the two canvas kinds. Two things fell out of it: the
object-creating calls took a `*Frame` and so could never have run in a worker at
all (they take an `*Execution` now, and the WebGL interfaces joined the worker
scope, which is where Chrome has them — measured), and
`OffscreenCanvas.getContext` now validates its argument as the WebIDL enum it is.
Chrome throws a `TypeError` for `'experimental-webgl'` *there* while returning
null for it on an `HTMLCanvasElement`; that asymmetry is measured, not assumed.

**F3 — `speechSynthesis`.** Five types, plus a generated voice table. The table
is 199 entries because that is what Chrome reports on this machine — 180 local
macOS system voices then 19 Google remote ones, 51 languages, `Samantha` the
default — and an empty `getVoices()` is the headless tell, so it is measured data
rather than a plausible-looking invention. Regenerate with `dump-voices.mjs`.

`getVoices()` reproduces Chrome's *timing* as well as its values, because the
timing is observable. Polling a headed Chrome every 25ms from first access, three
runs: the first synchronous read is always empty, `voiceschanged` fires at
661/662/664ms, and the list is complete at 668/675/675ms. So the first read here
answers `[]`, the list arrives 665ms later, and `voiceschanged` fires then.

That number is worth not rounding. CreepJS reads `getVoices()`, waits 50ms, then
gives up 300ms later if no voice with `localService` has arrived — so whether it
renders hashes or `blocked` depends on whether anything warmed the TTS service
before its own late warm-up call. It is a race in CreepJS, not a property of
Chrome: with a `getVoices()` injected at document start, a headed Chrome renders
`local (180): a158dc36 / remote (19): 036f6dce / lang (51): c4951b20`, which is
byte for byte what this engine produces. Without it, the same headed Chrome —
and a second run against the same warm profile — renders all three blocked.

An earlier revision filled the list on the very next task instead. That reported
the right values for the wrong reason, and it would have shown a filled list in
the window where Chrome shows an empty one.

`speak()` has no synthesiser behind it, so rather than doing nothing — which
hangs any page waiting on `onend` — it delivers Chrome's success pair, `start`
then `end`, from a scheduler task.

**F4 — page CSP.** `src/browser/Csp.zig` parses policies from the
`Content-Security-Policy` response headers and from every `<meta http-equiv>`,
and `ScriptManager.addFromElement` consults it before resolving a remote script.
A blocked load fetches nothing and queues an `error` event on the element.

The scope is `script-src` (falling back to `default-src`), external loads only.
Inline script and `eval` are not blocked, other directives are parsed past, and a
host-source's path is ignored. Every one of those simplifications is in the
more-permissive direction, so none of them can break a page a real browser would
run. Two are deliberately in the *stricter* direction: `'strict-dynamic'` is not
honoured, because honouring it would allow precisely the script-inserted load
rebrowser tests, and `Content-Security-Policy-Report-Only` never blocks.

### What is still open after F1–F4

- **CreepJS `audio`** — was `blocked` for want of an `OfflineAudioContext`.
  G17 batch 13-B added the constructor, and its `startRendering()` now resolves
  with a silent buffer, which is exactly what Chrome renders for the graph this
  engine can render (an unconnected destination — measured, `allZero: true`).
  What still differs is a graph with a *source* in it: a headed Chrome renders
  real numbers through CreepJS's oscillator-and-compressor chain (`sum:
  124.04347624466754`, `gain: -20.538288116455078`, `unique: 4736`, measured) and
  this engine renders silence, so the row now reports a constant rather than
  nothing. That trade is written up in `OfflineAudioContext.zig`'s header; the
  alternative, a `startRendering()` that never settles, is something no Chrome
  does.
- **CreepJS still shows 13 `blocked` rows against Chrome's 3.** The remaining
  ones are WebRTC (`sdp capabilities`), SVG (`bBox`), the nine audio rows, MIME
  types (`mimes (0/12)`), and CSS media queries (`@media`). Each is a separate
  API surface, none of them attributed to a bug.
- **iphey's second alert, `i20: TypeError: Illegal invocation`**, is unchanged
  and was present before this work, so it is a separate pre-existing gap rather
  than fallout. It has not been attributed to a named API yet.
- **browserscan.net renders 1231 nodes against Chrome's 1965**, unchanged by this
  plan.
- **CreepJS's `innerText` is 50525 characters against the headed Chrome's 4568 in
  the same sweep.** The Chrome column is the one that looks wrong — its record
  shows a report that had not finished rendering when the sweep read it — so the
  ratio says nothing about the engine either way. Node counts (4146 vs 3760) are
  the honest comparison.

## G17 batch 14: the streams remainder and WebTransport (P8)

Eleven more window (and worker) globals, all measured on a headed Chrome 150
first: `ByteLengthQueuingStrategy`, `CountQueuingStrategy`,
`ReadableByteStreamController`, `ReadableStreamBYOBReader`,
`ReadableStreamBYOBRequest`, `CompressionStream`, `DecompressionStream`,
`WebTransport`, `WebTransportBidirectionalStream`,
`WebTransportDatagramDuplexStream`, `WebTransportError`. The ground truth is in
`results/probes/`: `win20` for the shapes, `win22` and
`win26` for the behaviour, `win27` for the worker scope.

CreepJS after the batch: window missing keys **185 → 163**, window spans
**236 → 204**, total `.unsupport` spans **360 → 328**, own window keys
**958 → 982**.

### Where this engine now differs from Chrome, on purpose or otherwise

- **`CompressionStream` compresses for real.** The bytes *are* the fingerprint —
  a detector can gzip a known string and compare — so this links the same zlib
  curl already carries rather than reporting a shape. Chrome's answers for
  `'hello hello hello'` (28 gzip / 16 deflate / 10 deflate-raw bytes) come back
  byte for byte, and the test asserts the arrays, not the lengths. Zig's own
  `std.compress.flate` does *not* match: it emits 9 raw bytes for that input
  where zlib emits 10, so it was not an option.
- **A BYOB read copies rather than transfers.** Chrome detaches the view and
  transfers its buffer, so the chunk a read resolves with shares the source's
  `ArrayBuffer`. Here the bytes are copied into a fresh `Uint8Array`: the
  contents and the length are Chrome's, the buffer identity is not.
- **`constructor` sits last on both readers.** Chrome puts it third on
  `ReadableStreamDefaultReader` and `ReadableStreamBYOBReader`, between
  `releaseLock` and `closed`, because `closed`/`cancel` come from a mixin. This
  bridge always appends it, which is the same structural limitation already
  recorded for `PerformanceNavigationTiming`. It is the only shape difference
  left across all sixteen streams and WebTransport interfaces; `win22` and
  `win26` behaviour diffs are at zero.
- **A WebTransport handshake fails on the next task, not in the constructor.**
  Chrome exposes the race: `close()` called before the handshake gives up wins,
  and both promises then reject with "close() is called while connecting."
  instead of "Opening handshake failed." Scheduling the failure reproduces both
  measurements; raising it in the constructor would only reproduce one.
- **`WebTransportError` takes one dictionary, not `(message, options)`.**
  `new WebTransportError('x', {...})` reports "The provided value is not of type
  'WebTransportErrorInit'." because the *string* is what fails the conversion —
  measured, and easy to get backwards from the spec text. `source` always reads
  "stream" and `streamErrorCode` is a clamped octet (4294967295 → 255, -1 → 0).

## G17 batch 15: the misc window globals (P9)

Forty-seven more window globals — every name Chrome 150 has that this engine did
not, out of the forty-nine "misc" candidates. The two it does *not* add are
`MutationEvent` and `openDatabase`: Chrome 150 has neither, and the CreepJS
baseline is Chrome 115, which had both, so they stay missing on purpose.

The batch went in five groups: the twelve leftover `Event` subclasses; the
geometry and collection types (`Path2D`, `DOMQuad`, `DOMRectList`, `TimeRanges`,
`Touch`, `TouchList`, the two `DeviceMotionEvent*` payloads); the text-track and
capture types; the CSS/DOM leftovers (`Highlight`, `HighlightRegistry`,
`CustomStateSet`, `MathMLElement`, `XSLTProcessor`, `Sanitizer`, `DOMError`); and
the window-and-navigation leftovers (`URLPattern`, `Option`, `Profiler`,
`EyeDropper`, `IdleDetector`, `InputDeviceCapabilities`, `ReportingObserver`,
`ClipboardItem`, `KeyframeEffect`, `NavigationDestination`,
`NavigationTransition`, `IDBOpenDBRequest`). Nine of them are also in the worker
scope, which is exactly the nine Chrome's workers carry.

Ground truth is in `results/probes/`: `win28` for the shapes
of all forty-seven, `win29` for the behaviour, `win30` for the worker scope, and
`win31`–`win36` for the pieces that needed a second pass (the Sanitizer config
algebra, the Highlight iterators, the Option constructor cases, the
IDBOpenDBRequest split).

CreepJS after the batch: window own keys **982 → 1029**, window spans
**204 → 150**, total `.unsupport` spans **328 → 274**.

`win28` shape diff after the batch: forty-six of forty-seven interfaces are
field-for-field identical to Chrome (arity, constructor name, statics, prototype
members with their kind and flags, prototype chain, `new X()` behaviour, the
error for calling without `new`). The forty-seventh is `Option` — see below.

### Where this engine now differs from Chrome, on purpose or otherwise

- **`Option` is the same function object as `HTMLOptionElement`.** Chrome has two
  distinct functions that share one prototype: `Option !== HTMLOptionElement`,
  `Option.name === 'Option'`, and `Object.getPrototypeOf(Option)` is
  `Function.prototype`. The bridge's `constructor_alias` installs one function
  under two global names, so all four of those read the `HTMLOptionElement`
  answer here (and `new Option()` called without `new` names
  `HTMLOptionElement` in its message). A faithful legacy factory function needs
  a second `FunctionTemplate` whose `prototype` is re-pointed at the
  interface's. That needs `SetPrototypeProviderTemplate`, which the vendored
  bindings *do* export — it is declared at `src/binding.h:942` and
  `nm -gU v8/libc_v8.a` shows `_v8__FunctionTemplate__SetPrototypeProviderTemplate`
  as a `T` symbol. (An earlier revision of this file said the symbol was
  missing, which was wrong.) Whether wiring it up actually reproduces Chrome's
  shape is unverified; nobody has tried. The same four differences
  already applied to the shipped `Image` and `Audio`. Everything a page can
  *do* with `Option` matches: `length` is 0, `Option.prototype ===
  HTMLOptionElement.prototype`, both global names are `value[-cw]`, and all
  eight measured construction cases produce Chrome's markup.
- **An empty boolean attribute serialises bare.** `new Option('T','V',true)`
  gives `<option value="V" selected>T</option>` where Chrome gives
  `selected=""`. This is `formatAttribute` in `webapi/element/Attribute.zig`
  special-casing the boolean-attribute table, and it applies to every
  `outerHTML` / `innerHTML` in the engine, not just to options. Chrome's HTML
  fragment serialiser always writes `name="value"`.
- **`HTMLOptionElement` lost its `name` member.** It reflected the `name`
  content attribute, which Chrome does not do for this interface at all — the
  prototype now has Chrome's eight members in Chrome's order (`disabled`,
  `form`, `label`, `defaultSelected`, `selected`, `value`, `text`, `index`).
- **`ReportingObserver` never produces a record.** Nothing here generates a
  deprecation, intervention or crash report, so `takeRecords()` is always `[]`.
  Chrome answered with one during the measurement, but it was Chrome reporting
  its own `XSLTProcessor` deprecation back at the probe.
- **`XSLTProcessor` does not transform.** There is no XSLT engine, so
  `transformToDocument` / `transformToFragment` log `not_implemented` and answer
  null — which is also Chrome's answer before a stylesheet is imported.
- **`CustomStateSet` is unreachable from a page.** The only route to an instance
  is `element.attachInternals().states`, and `ElementInternals` does not exist
  yet (it is still in `results/creep-features-missing.json`). The global and the
  prototype shape are what this batch delivers.
- **`ctx.fill(path)` still paints nothing.** `Path2D` records its segments and
  `getPathData`-style reads are right, but the canvas path rasteriser is a noop,
  so a filled path leaves no pixels.
- **`BeforeInstallPromptEvent.platforms` is not frozen.** Chrome hands back a
  frozen array; the v8 bridge has no `SetIntegrityLevel`.
- **A method missing an argument says "invalid argument".** Chrome says
  "1 argument required, but only 0 present.". The bridge only counts arguments
  for *constructors*; the classes in this batch that needed the Chrome wording
  (`XSLTProcessor`, `Highlight`, `HighlightRegistry`, `Sanitizer`,
  `ClipboardItem.supports`, `URLPattern`) count them by hand with a variadic
  `[]js.Value`. `TimeRanges.start()` and the rest still say "invalid argument".
- **A typed dictionary argument says "invalid argument" too.** `new DOMQuad(5)`
  should say "The provided value is not of type 'DOMPointInit'.". The
  hand-rolled reader in `webapi/dictionary.zig` produces Chrome's three messages
  and is what the classes that were measured against them use; the bridge's own
  typed dictionaries still do not.
- **`CSS` is missing most of its numeric factories.** Chrome's
  `Object.getOwnPropertyNames(CSS)` is sixty-odd names (`Hz`, `Q`, `cap`, `ch`,
  `cm`, every `cq*`/`dv*`/`lv*`/`sv*` unit, `registerProperty`,
  `paintWorklet`, …); this engine has `highlights`, `escape` and `supports`.
- **`UIEvent.prototype` is missing `pseudoTarget`.** Chrome 150 carries it after
  `initUIEvent`; its semantics were not measured.
- **`HTMLElement` and `SVGElement` prototypes are missing `focusGroup` and
  `focusGroupStart`.** `MathMLElement` has them because it was built to Chrome's
  measured prototype in this batch; aligning the other two is separate work.
- **`HTMLVideoElement`'s own picture-in-picture members are still missing**
  (`requestPictureInPicture`, `disablePictureInPicture`,
  `onenterpictureinpicture`, `onleavepictureinpicture`). `PictureInPictureEvent`
  and `PictureInPictureWindow` are here; the element side needs its own round.
- **Two `Sanitizer` details are unmeasured.** A newly inserted element entry gets
  an empty `removeAttributes` (which matches the dictionary default), and
  whether an explicitly empty `replaceWithChildrenElements: []` is emitted by
  `get()` was never checked.
- **`URLPattern` matches a string input only.** A `URLPatternInit` passed to
  `exec()`/`test()` as the *match target* is legal in Chrome and answers null
  here; Chrome's behaviour for it was not measured.

## G17 batch 16: WebGPU (P10)

The whole `GPU*` family — forty-one interfaces, thirty-nine of them new globals
(`GPU` and `WGSLLanguageFeatures` were already here from the navigator work).
Not a shape-only batch: `navigator.gpu.requestAdapter()` now hands back a real
`GPUAdapter`, so an adapter, a device, its queue, every `create*` and the canvas
context are all reachable from script.

The reason it could be built for real rather than stubbed is that the reference
machine has a working WebGPU: every number, every default and every error string
below was read off a headed Chrome 150 on it (Apple GPU, `metal-3`), not off the
spec. The probes are `probes/probe-win37.js` (shapes
of all forty-one), `-win38` (adapter and device behaviour), `-win39` (the
resource `create*` defaults and refusals), `-win40`/`-win40b`/`-win40c` (the
pipeline and encoder half), `-win41` (the error family), `-win42`/`-win42b`
(every method called with no arguments). `win38-findings.md` is the readable
summary.

It went in six groups: the five flag namespaces (`GPUBufferUsage`,
`GPUColorWrite`, `GPUMapMode`, `GPUShaderStage`, `GPUTextureUsage`); the entry
and device types (`GPU`, `GPUAdapter`, `GPUAdapterInfo`, `GPUDevice`,
`GPUQueue`, `GPUSupportedFeatures`, `GPUSupportedLimits`, `GPUDeviceLostInfo`,
`WGSLLanguageFeatures`); the nine resources (`GPUBuffer`, `GPUTexture`,
`GPUTextureView`, `GPUSampler`, `GPUExternalTexture`, `GPUBindGroup`,
`GPUBindGroupLayout`, `GPUPipelineLayout`, `GPUQuerySet`); the twelve pipeline
and encoder types; and the six-strong error family.

CreepJS after the batch: window own keys **1029 → 1068**, window spans
**150 → 111**, total `.unsupport` spans **274 → 235**.

`win37` shape diff after the batch: **all forty-one interfaces are
field-for-field identical to Chrome** — arity, constructor name, statics,
prototype members with their kind and flags, prototype chain, `new X()`
behaviour, and the error for calling without `new`. The behaviour diffs
(`win40`–`win42b`) come back clean except for the asynchronous-validation gap
below.

Three findings from the measurement are worth keeping, because each one
contradicts something that looked obvious:

- **`GPUSupportedFeatures`' iteration order is not stable in Chrome.** The
  twenty-two-name set is fixed; the order is not. Three `requestAdapter()` calls
  in a row give three different orders, with two clusters permuting (indices 2–3
  and 15–18), verified across two separate browser launches. So the order is
  *not* a hashable surface for this set and any one of Chrome's orders is as
  authentic as another — only the set has to match. (Prototype member order, by
  contrast, is stable and is transcribed verbatim everywhere in this family.)
- **A required dictionary argument refuses `undefined` and `null` outright.**
  `device.createBuffer(undefined)` is *not* "Required member is undefined." for
  `size`; it is "The provided value is not of type 'GPUBufferDescriptor'.", and
  the same holds for all eleven `create*` calls whose descriptor is required.
  The two whose descriptor is optional (`createSampler`, `createCommandEncoder`)
  take it. An earlier revision of this batch had inferred the opposite for
  `createBuffer` and shipped a test asserting it; `win40d` measured it.
- **Chrome's WebGPU differs from the spec in three places this batch touched.**
  `GPUTextureUsage.TRANSIENT_ATTACHMENT` (0x20) exists in Chrome 150 and not in
  the spec; `GPUPipelineError`'s required argument is `options`, not `message`;
  and a core device rejects a feature-gated `GPUTextureFormat` as an *invalid
  enum value* rather than as a validation error, which is why only 42 of the
  spec's 101 formats are listed in `webgpu/resources.zig`.

### Where this engine now differs from Chrome, on purpose or otherwise

- **Nothing produces a `GPUValidationError`.** This is the batch's one real gap
  and it has a single cause: WebGPU splits validation in half, and only the
  synchronous half is here. A missing or ill-typed descriptor member throws the
  TypeError Chrome throws, down to the wording; a value that is well-formed but
  wrong — `usage: 0`, a size past a limit, ill-formed WGSL, a pipeline whose
  entry point does not exist, a second `finish()` on a spent encoder — is an
  *asynchronous* `GPUValidationError` in Chrome, delivered through an error
  scope or `onuncapturederror`. Here every one of those succeeds. The scope
  machinery itself is faithful (`pushErrorScope` checks its filter, scopes nest,
  one pop too many rejects with `OperationError: No error scopes to pop`), but a
  scope always pops `null`. Reproducing the other half means re-implementing
  Dawn's validation rules, which is a project of its own.
- **`getCompilationInfo()` always reports zero messages.** Nothing compiles
  WGSL, so a module with a syntax error reports as clean where Chrome lists the
  message, its type, and its line, column, offset and length.
- **`GPUCompilationInfo.messages` is not frozen.** Chrome hands back a frozen
  array; the v8 bridge has no `SetIntegrityLevel`, the same reason
  `BeforeInstallPromptEvent.platforms` is not frozen.
- **`buffer.getMappedRange()` answers undefined on a mapped buffer.** There are
  no bytes behind the handle to hand out. The *refusal* on an unmapped buffer is
  Chrome's (`OperationError: … getMappedRange failed`), and `mapState` walks the
  measured `unmapped → mapped → unmapped` path; what is missing is the usage
  check, so `mapAsync` on a buffer without `MAP_READ` resolves here and rejects
  in Chrome. Chrome's intermediate `'pending'` state is never observable here
  either: the map completes at once.
- **The canvas context presents nothing.** `getCurrentTexture()` hands back a
  `GPUTexture` of the canvas' live size with the configured format and usage,
  and re-configuring or a resize replaces it, which is what a page reads back —
  but no pixels are ever produced, exactly as for the WebGL contexts.
- **`canvas.getContext()` with no arguments still says "invalid argument".**
  Chrome says "1 argument required, but only 0 present.". This is the
  engine-wide bridge limitation recorded under batch 15; every method *inside*
  the WebGPU family counts its own arguments and produces Chrome's wording
  (measured for all fifty-odd of them in `win42`).
- **A setlike's `@@iterator` is not the same function object as its `values`.**
  Chrome's `GPUSupportedFeatures.prototype[Symbol.iterator] === …values`; here
  it is a separate function with the same name. The name is what an enumeration
  reads, and it now matches — it did not before this batch, which is the one
  field the shape diff caught.

## G17 batch 17: WebCodecs (P11)

The whole WebCodecs family — twelve globals, all new: `VideoFrame`,
`VideoColorSpace`, `EncodedVideoChunk`, `EncodedAudioChunk`, `AudioData`,
`VideoDecoder`, `VideoEncoder`, `AudioDecoder`, `AudioEncoder`, `ImageDecoder`,
`ImageTrack`, `ImageTrackList`.

Like batch 16 it is not shape-only, and for the same reason: the reference
machine has a real implementation to read. Every default, every refusal string
and the whole codec matrix below came off a headed Chrome 150 on it, not off the
spec. The probes are `probes/probe-win43.js` (shapes
and entry points for all twelve), `-win45` (the sample containers), `-win46`,
`-win46b`, `-win46c`, `-win48`, `-win49`, `-win50` (the four codec classes), and
`-win47`, `-win51` (the image half). `win46-findings.md`, `win48-findings.md`,
`win47-findings.md` and `win51-findings.md` are the readable summaries.

Two things about the harness are worth recording, because both cost a session:

- **The four codec classes are `[SecureContext]`.** On `about:blank` a probe
  reports `VideoDecoder is not defined`; it needs an https page. That, not
  headed-vs-headless, is why the earlier findings said "headed Chrome" —
  `run-probe.mjs` now takes a url for exactly this.
- **`JSON.stringify` flattens `Infinity` to `null`.** An earlier probe recorded
  `ImageTrack.repetitionCount` as null for a looping GIF; reading it directly
  (`probe-win51.js`) shows **Infinity**. Any probe field that can be a
  non-finite number has to be stringified by hand.

It went in four groups: the frames and colour space; the three sample
containers; the four codec classes; and the three image-decoding types.
`run-page-probe.mjs` was added alongside `run-probe.mjs` because this engine
does not run scheduled tasks while a CDP `Runtime.evaluate` with `awaitPromise`
is outstanding, so any probe that awaits a `setTimeout` hangs there — loaded as
a page, the same probe runs fine.

CreepJS after the batch: window own keys **1068 → 1080**, window spans
**111 → 87**, total `.unsupport` spans **235 → 211**.

Shape and behaviour diff after the batch: across the nine probes replayed
against this build, **970 fields, 2 diffs** — and both of those are the same
timing artefact, `probe-win48`'s 60ms window catching Chrome's real encoder
before it had dispatched `dequeue`, which `probe-win49`'s 600ms window shows
matching exactly. All twelve interfaces are field-for-field identical to
Chrome: arity, constructor name, statics, prototype members with their kind and
flags, prototype chain, `new X()` behaviour, and the error for calling without
`new`.

Three findings are worth keeping, because a detector can read each one and none
is guessable from the spec:

- **The codec matrix is machine-specific, and its case sensitivity is mixed.**
  `VideoDecoder.isConfigSupported` answers true for exactly `vp8` and anything
  starting `vp09.`, `avc1.`, `av01.`, `hev1.` or `hvc1.`, and it is
  case-sensitive throughout: `VP8`, `Vp8` and `AVC1.42E01E` are all false. Audio
  is *mixed*: `Opus`, `PCM-S16` and `ALAW` are true while `MP3` and `Mp4a.40.2`
  are false, so the opus / alaw / ulaw / pcm-\* names fold case and the mp3 /
  mp4a.40.\* / vorbis / flac ones do not. `hardwareAcceleration:
  'prefer-hardware'` turns every video codec unsupported on this box — a second
  axis to enumerate on top of the codec list. All of it is reproduced literally.
- **`configure()` has two refusal paths and they look nothing alike.** A
  malformed config throws synchronously and leaves the state alone; a
  well-formed one naming a codec nothing supports returns undefined, leaves
  `state` at `'configured'`, and only on a later task fires the error callback
  with a real DOMException and turns `state` to `'closed'`. The four messages
  differ, and AudioEncoder's reports a channel count it never parsed
  ("received 0" for a config that passed 2). Transcribed as measured.
- **`close()` means opposite things on the two halves of the family.** A second
  `close()` on any of the four codec classes is an InvalidStateError; on
  `VideoFrame`, `AudioData` and `ImageDecoder` it is a no-op. And `configure()`
  after `close()` names `'decode'` on both decoders and `'configure'` on both
  encoders — a Blink slip, transcribed rather than tidied.

Two engine-wide gaps this batch had to close to get there, both outside
WebCodecs:

- **`EventManagerBase.dispatchDirect` never set `eventPhase`.** A listener on
  any internally-dispatched event — `dequeue`, `abort`, `message` — read back 0
  where Chrome reads 2 (`AT_TARGET`). It now sets it for the duration of the
  dispatch.
- **`testing.js`'s `withError` threw without recording a failure.** An
  `expectError` that did not fire left the suite green while silently skipping
  the rest of its script. It now records it, which immediately surfaced one such
  case in this batch's own `frames.html`.

### What is still missing

- **Nothing is encoded or decoded.** The four codec classes hold a state
  machine, a queue and a `dequeue` event; their `output` callback never fires,
  because there is no codec behind them. Every observable a detector reads
  without real media — state, queue size, refusal wording, the support matrix —
  matches; what does not exist is a page handing in an `.mp4` fragment and
  getting frames back.
- **`VideoDecoder.decode()` can never succeed.** That is Chrome's behaviour for
  a synthesised chunk too (it refuses one for not being a key frame), so the
  two agree — but they agree for different reasons, and a page with a real key
  frame would part company here.
- **Only PNG is decoded to pixels.** `ImageDecoder.decode()` hands back a
  `VideoFrame` whose samples a page can read with `copyTo`, and for PNG those
  are real: inflate, unfilter, the 8-bit colour types including palette with
  `tRNS`. JPEG, GIF, WebP, AVIF and BMP report the right geometry and frame
  timing — the GIF frame delays are parsed, so an animation's timestamps and
  durations are Chrome's — but their frames come back transparent black. Each
  would need its own entropy decoder.
- **A `ReadableStream` `data` is not accepted by `ImageDecoder`.** The union is
  named correctly in the refusal; only the two buffer arms work.
- **`AudioData.copyTo` across formats fills zeroes.** The byte count is right
  and the plane layout is right; converting samples between formats is not
  done, which is deliberate — see the note in `chunks.zig`.
- **`VideoFrame` from an `<img>` or `<video>` is always an InvalidStateError.**
  Neither element ever has decoded data in this engine, which is the state
  Chrome refuses an unloaded one in, so the refusal matches — but a loaded one
  would not.
- **`ctx.fillStyle = 'rgb(255,0,0)'` is silently ignored.** `RGBA.parse` in
  `src/browser/color.zig` reads hex and named colours only, so the commonest
  spelling in a canvas fingerprint keeps the previous fill. Not a WebCodecs
  problem — it belongs with the G3/G4 rasteriser work — but it is what
  `frames.html` had to route around, and it is worth fixing before any canvas
  claim is made.

## G17 batch 18: WebXR (P12)

Forty-nine new window globals, which is the largest single block in G17 and is
larger than the sixty-five-key gap it was scoped from. `creep-features-missing`
named 34 `XR*` keys, because CreepJS's key table is frozen at Chrome 115.
`Object.getOwnPropertyNames(window)` on the reference Chrome 150 carries **50**;
this engine had exactly one, `XRSystem`. The batch closes all 49.

The probes are `probes/probe-win52.js` (the whole
family's shapes, the entry point, and the two constructible types), `-win53`
(the fifteen globals CreepJS's table predates, plus a live session end to end),
`-win54` (the frame loop), `-win55` (the collections and `end`), and `-win56`
(a short-window replay of the last two, for diffing this engine against
Chrome). `win52-findings.md` is the readable summary. Everything ran at
`http://localhost:8731/` — WebXR is `[SecureContext]` and localhost counts, so
no https server was needed.

One measurement decided the shape of the whole batch:
**`navigator.xr.requestSession('inline')` RESOLVES on a plain desktop Chrome
with no headset.** `isSessionSupported('inline')` is true, the two immersive
modes are false, and the inline session hands out a reference space, a render
state and a running frame loop. So the session surface is reachable from
ordinary script on an ordinary machine and could not be stubbed as "no device,
everything rejects" — that is itself a fingerprint. This engine used to answer
`false` to `isSessionSupported('inline')` and throw `SecurityError: The
operation is insecure` from every `requestSession`.

Three behaviours behind that are measured, are not in the spec, and are the
kind a detector can read directly:

- **An inline session's `requestAnimationFrame` does not fire until a
  `baseLayer` is set.** With no layer the callback never arrives — five seconds,
  while `window.requestAnimationFrame` keeps ticking in the same page. Set one
  through `updateRenderState` and the callback lands on the next frame. That
  timeout is what made `probe-win53` come back empty, and the frame loop here is
  gated on the render state for exactly that reason.
- **`updateRenderState` is not visible synchronously.** Right after the call
  `session.renderState.baseLayer` is still `null` and `depthNear` is still its
  old value; inside the next frame callback both have landed. So a pending state
  is held and applied at the top of a frame.
- **`session.end()` never completes.** It flips the session to ended right away
  — a second `end()` hands back a promise rejecting with "XRSession has already
  ended." — but the promise it returns stays pending and no `end` event is ever
  dispatched. Confirmed with a ten-second window and a 100 ms ticker running
  alongside (105 ticks observed, so the task queue was healthy), and
  `visibilityState` stays `"visible"` afterwards.

The inline defaults are all on the record in `win52-findings.md`:
`environmentBlendMode` "opaque", `interactionMode` "screen-space",
`preferredReflectionFormat` "rgba16f", `maxRenderLayers` 1, `enabledFeatures`
`["viewer"]`, `depthNear` 0.1, `depthFar` 1000, `inlineVerticalFieldOfView`
pi/2, one view with `eye` "none", a projection matrix derived from the render
state rather than fixed, and a `getViewport` of `0,0,0,0` even though the layer
reports the canvas' 300x150.

Two smaller measured details worth keeping: `XRRigidTransform` normalises its
orientation in **double** precision while `XRRay` normalises its direction in
**float32** (`{3,0,0,4}` gives exactly 0.6 on the transform, `{0,3,4}` gives
0.6000000238418579 on the ray), and every object-returning accessor hands back
the same object each time, with `t.inverse.inverse === t` being the original
object rather than a rebuilt equal one.

CreepJS after the batch: window own keys **1080 → 1129**, window spans
**87 → 37**, total `.unsupport` spans **211 → 161**. The window key gap went
from 65 to 31, and every one of the 34 `XR*` entries is closed.

Shape and behaviour diff after the batch, replaying the probes against this
build: **789 fields, 7 diffs** — `probe-win52` 538 fields / 1 diff,
`probe-win53` 185 / 4, `probe-win56` 66 / 2. Every one of the seven is a
pre-existing engine-wide gap rather than anything WebXR-specific; they are
listed below.

### Where this engine now differs from Chrome, on purpose or otherwise

- **FrozenArray is not reachable from Zig (4 of the 7 diffs).** `enabledFeatures`,
  `renderState.layers` and `XRInputSourcesChangeEvent.added` are frozen arrays
  in Chrome with a stable identity; here they are ordinary arrays rebuilt on
  each read. The contents match. There is no `SetIntegrityLevel` binding in the
  vendored v8 C API, so this cannot be closed without touching that shim —
  the same gap `navigator/usb.zig` already records for `packets`.
- **`X.prototype[Symbol.iterator] === X.prototype.values` does not hold (2 of
  the 7).** `bridge.iterator` installs a separate function with the right name;
  Chrome hands out the method itself. Already recorded for the WebGPU setlikes,
  and it now covers `XRAnchorSet`, `XRPlaneSet` and `XRInputSourceArray` too.
  The names are right, which is what an enumeration reads.
- **`HTMLElement.prototype.onbeforexrselect` is still missing (1 of the 7).**
  `window.onbeforexrselect` exists here; the element one is one of G20's
  twenty-four `HTMLElement.prototype` members and belongs to that batch.
- **The set-like iterators are unbranded.** Chrome's `trackedAnchors.values()`
  is `[object XRAnchorSet Iterator]` and `inputSources.entries()` is `[object
  Array Iterator]`; the generic iterator here carries no `Symbol.toStringTag`
  and no window global, matching what the WebGPU setlikes already do. Both
  collections are empty on any machine without a device, so an enumeration sees
  the same thing either way.
- **`XRInputSourceArray.forEach()` with no argument** is a plain
  "invalid argument" here against Chrome's "undefined is not a function". The
  set-likes' `forEach` *is* WebIDL-checked in both, and that message is
  reproduced exactly — the difference between the two is itself measured.
- **`pauseDepthSensing` / `resumeDepthSensing` pick their refusal from whether a
  frame has ever run.** Chrome answers InvalidStateError ("Not called from
  inside an active animation frame.") before any frame and NotSupportedError
  ("Depth sensing feature is not supported by the session.") after one. Both
  readings are measured — `probe-win53` before a baseLayer existed, `probe-win56`
  after a frame — and this reproduces both, but the exact Blink predicate was
  not isolated.

### What is still missing

- **No device, so nothing moves.** Every pose is the identity and the single
  view sits at the origin. That is what Chrome reports on the same machine, so
  the numbers agree; a headset would part company immediately.
- **`XRWebGLBinding` can never be constructed.** Every session this engine hands
  out is inline, and Chrome refuses a binding for an inline session outright, so
  the constructor always ends in the same InvalidStateError. That means
  `XRCompositionLayer` and its five subclasses, `XRSubImage` and
  `XRWebGLSubImage` have no instance — only their interface objects, which is
  what the window surface is about.
- **Eleven of the thirteen feature interfaces have no instance.** Anchors, plane
  detection, hit-test, light estimation and depth sensing are all refused by
  name, so `XRAnchor`, `XRPlane`, the four hit-test types, the two light types
  and the three depth types exist as interface objects only. `XRAnchorSet` and
  `XRPlaneSet` do have instances: any frame hands back an empty one, and a new
  one on each read, the way Chrome does.
- **`XRWebGLLayer.framebuffer` is null and its viewport is all zeroes.** Both
  match Chrome for an inline session, and both would be real numbers for an
  immersive one this engine cannot enter.

## G17 batch 19: EME, Media Source and media capture (P13)

Seventeen new window globals. `creep-features-missing` named sixteen; the
seventeenth, `ChapterInformation`, exists on the reference Chrome 150 and not in
CreepJS's Chrome-115-era table. Scope was set from the live browser rather than
from that table in both directions: `ManagedMediaSource`, `ManagedSourceBuffer`,
`PhotoCapabilities` and `MediaKeysPolicy` are **absent** from the reference
Chrome 150 too, so they are not added. Shipping a global a real Chrome does not
have is as loud as missing one.

The probes are `probes/probe-win57.js` (the whole
family's shapes, the entry points, MSE end to end and a full EME chain),
`-win60` (canvas capture, ImageCapture, VideoPlaybackQuality and RemotePlayback
behaviour), `-win61` (the branches this engine can reach that -win60 did not
cover), and `-win62` (id/label identity). `win57-findings.md` is the readable
summary. Everything ran at `http://localhost:8731/`.

Two measurements decided the shape of the batch, and both cut the same way:
these families are not refusable.

**`navigator.requestMediaKeySystemAccess` resolves.** On a plain desktop Chrome
with no special CDM, both `org.w3.clearkey` and `com.widevine.alpha` come back
with a real `MediaKeySystemAccess`; only the other three key systems are
refused, and the match on the key system string is exact — no case folding, no
trimming, no prefix match. So EME here is a real negotiation with two supported
key systems, producing real `MediaKeys` and `MediaKeySession` objects, rather
than the unconditional `NotSupportedError` this engine used to give.

**`canvas.captureStream()` is the one capture path that needs no permission and
no device.** getUserMedia still refuses and no camera exists, but a canvas is a
video source a browser is always willing to open, so a page reaches a live
`CanvasCaptureMediaStreamTrack` and a working `ImageCapture` in two calls. That
makes `grabFrame()` produce a real `ImageBitmap` rather than a refusal.

### Five behaviours only a measurement gets right

- **A capture track's size is frozen at `captureStream()` time.** Resizing the
  canvas afterwards moves neither the live track's settings nor its capability
  ranges. Only a track opened after the resize sees the new size.
- **A zero-area canvas still captures**, but its settings then *omit*
  `width`, `height` and `aspectRatio` rather than reporting 0, while every
  capability range clamps to 1.
- **`grabFrame()` on a video track with no frames rejects with `undefined`.**
  Not a DOMException — nothing at all. A reader that reaches for `e.name` on
  that rejection throws, which is exactly how this was found: the first probe
  run died there and lost the whole ImageCapture section.
- **`takePhoto('nope')` rejects rather than throwing.** The failure is an
  argument-conversion TypeError, which normally throws synchronously, and here
  it does not.
- **`watchAvailability()` ids come from a counter shared by every
  `RemotePlayback` in the window** — a second media element continues the
  sequence instead of starting at 1 — while the bookkeeping
  `cancelWatchAvailability()` checks is per-object, so cancelling another
  object's id is a `NotFoundError`. The counter and the ledger live in different
  places.

### What the track rework closed

`MediaStreamTrack` now carries which source produced it (WebAudio destination
node, breakout-box generator, or canvas capture). Chrome's settings and
capabilities dictionaries are per-source and barely overlap — only `deviceId` is
common to all three — so they branch on it. That also closed the gap batch 19's
own P5 had recorded: a generator used to answer the WebAudio track's values.
Three more per-source differences came out of the same measurement: `stats` is
`null` on a video track rather than a zeroed object, the `contentHint`
vocabulary splits by kind (`speech`/`music` for audio, `motion`/`detail`/`text`
for video, and a hint from the wrong list is dropped rather than refused), and
`clone()` keeps the deviceId on a capture track while minting a fresh one on a
WebAudio track.

Two prototype orders were corrected in passing.
`HTMLCanvasElement.prototype` now matches Chrome's own-property order exactly —
`captureStream` sits after the two dimensions, and `toBlob` before `toDataURL`.
`HTMLMediaElement.prototype` takes Chrome's `load`/`pause`/`play` order with
`remote` and `disableRemotePlayback` after them; the rest of that prototype is
still short and belongs to G20.

### What is still missing

- **`getConstraints()` does not echo.** A capture track accepts constraints and
  resolves, the way Chrome does, but Chrome then remembers what it recognised
  and reports it back: after `applyConstraints({width: 10})` its
  `getConstraints()` is `{"width":10}` where this engine's stays `{}`. This is
  the only field-level difference left across the four probes once the
  per-instance random deviceIds are normalised.
- **`URL.createObjectURL` still only accepts a Blob**, so a MediaSource cannot
  be attached to an element. Adding the URL would not help: there is no media
  pipeline behind it, so `sourceopen` would never fire, and the trade is a
  visible refusal for an invisible hang.
- **`takePhoto()` never succeeds.** There is no still-image pipeline behind a
  canvas track — and Chrome fails it the same way, with
  `UnknownError: setPhotoOptions failed`, rather than falling back on the frame
  `grabFrame()` would have handed over.
- **FrozenArray cannot be frozen** (`MediaMetadata.artwork`), and
  `X.prototype[Symbol.iterator] === X.prototype.values` does not hold. Both are
  engine-wide gaps older than this batch; `SourceBufferList` is the sharpest
  case, because Chrome's `@@iterator` there *is* `Array.prototype[@@iterator]`
  itself, an identity this engine has no way to reproduce.

## G17 batch 20: the legacy leftovers, and the floor (P14)

The last fifteen names in `creep-features-missing`'s window list. Scope came
from the live browser, not the table: **two of the fifteen do not exist on the
reference Chrome 150 at all.** `openDatabase` (WebSQL) and `MutationEvent` are
both `ReferenceError` there, and `document.createEvent('MutationEvent')` is a
`NotSupportedError`. Adding them would ship globals a real Chrome does not have.

So **CreepJS will count those two as missing forever. G17's window-key gap has a
floor of 2, not 0, and this batch reached it.** That is a scoring artefact of a
Chrome-115-era table, not a defect.

Of the thirteen that do exist, seven are pure aliases — the same constructor
object as an unprefixed name, `===` and all:

| prefixed | is |
|---|---|
| `webkitSpeechRecognition` | `SpeechRecognition` |
| `webkitSpeechGrammar` | `SpeechGrammar` |
| `webkitSpeechGrammarList` | `SpeechGrammarList` |
| `webkitSpeechRecognitionEvent` | `SpeechRecognitionEvent` |
| `webkitSpeechRecognitionError` | **`SpeechRecognitionErrorEvent`** |
| `WebKitCSSMatrix` | `DOMMatrix` |
| `WebKitMutationObserver` | `MutationObserver` |

Note the fifth row: the prefixed name aliases an interface with a *different*
name. `SpeechRecognitionPhrase` is a global on Chrome 150 and not in CreepJS's
table, so it was added on the same measured-not-tabulated grounds.

Probes are `probes/probe-win63.js` (every target's
shape), `-win64` (the ElementInternals and misc behaviour), `-win65`
(recognition lifecycle), `-win66` (coercion and the filesystem), `-win67`
(data-URI encoding and the Entry family). `win63-findings.md` is the readable
summary. Everything ran at `http://localhost:8731/`.

### Behaviours only a measurement gets right

- **`SpeechRecognition.start()` fails asynchronously.** It returns undefined and
  ~50ms later fires `error` (`not-allowed`) then `end`. A second `start()` while
  running is an `InvalidStateError`; a `stop()` or `abort()` in the same task
  pre-empts the failure and emits a lone `end`; on an idle object they emit
  nothing at all.
- **`addFromString` percent-encodes with a keep-set that is neither
  `encodeURI`'s nor `encodeURIComponent`'s.** Measured character by character
  over printable ASCII: unreserved plus `!`, `(`, `)`, `*`, `/`. `'` is escaped
  where encodeURIComponent keeps it; `/` is kept where it escapes it.
- **`window.TEMPORARY` and `PERSISTENT` live on `Window.prototype`,** whose own
  keys on Chrome are exactly `TEMPORARY PERSISTENT constructor`.
  `getOwnPropertyDescriptor(window, 'TEMPORARY')` is `undefined`.
- **None of the filesystem interfaces is a global.** `DOMFileSystem`, `Entry`,
  `DirectoryEntry`, `FileEntry`, `DirectoryReader`, `Metadata` and `FileWriter`
  are reachable only through the callbacks, and their brands are not the WebIDL
  names.
- **ARIA on `ElementInternals` is separate storage, not a reflection.** After
  `i.ariaLabel = 'hello'` the element's `aria-label` attribute is still absent
  and `el.ariaLabel` keeps reading the attribute independently. Nothing parses
  its value either: `i.ariaLevel = 3` reads back the string `"3"`.
- **`states.add()` does not validate the dashed-ident form, and `:state()` does
  not fold it.** `add('nope')` is accepted, and after `add('--on')`,
  `el.matches(':state(on)')` is false — the ident has to match the stored string
  exactly.
- **`ImageBitmapRenderingContext.transferFromImageBitmap` consumes the bitmap
  without resizing the canvas.** The source reads 0x0 afterwards and the canvas
  keeps its own dimensions.

### What the diff closed in passing

Diffing `probe-win63` field by field against the Chrome snapshot left fourteen
differing paths of 548. Four were fixable and are gone: DOMMatrix declares its
mutating operations and its statics alphabetically (WebKitCSSMatrix inherits
both, being the same object); MutationRecord lists the node members before the
attribute ones; `MutationObserver.prototype.observe` reports arity 1, not 2; and
`createEvent` names the type it refused instead of answering a bare "operation
is not supported". Wiring `WebKitMutationObserver` had already exposed two more
in P4 — the prototype order was `observe disconnect takeRecords` where Chrome
has `disconnect observe takeRecords`, and the constructor reported arity 0.

`:state()` was not a selector this engine knew: it threw a `SyntaxError` where
Chrome answers a boolean. It now reads the element's `CustomStateSet`, which
stopped being a shape-only interface in the same commit.

The form-owner walk had been copied out four times across `Input`, `Button`,
`Select` and `TextArea`; ElementInternals needed a fifth, so it moved to
`Form.ownerOf`.

### Result

`window own keys 1146 -> 1165`, `window spans 18 -> 5`, `total spans 142 -> 129`.
Window missing keys **15 -> 2**, and those two are the floor described above.
The js and css blocks are unchanged (`js 4 spans`, `css 120 spans`).

Seven probe paths still differ. Two are the harness's own origin — Chrome ran on
`localhost:8731` while lightpanda serves the probe page from an ephemeral port,
which shows up in `origin` and in the filesystem name derived from it. The other
five are the engine-wide gaps below.

### What is still missing

- **The bridge produces WebIDL's "N argument(s) required, but only M present."
  only for constructors.** An operation gets `TypeError: invalid argument`
  unless the module reads the argument as `?js.Value` and throws by hand, which
  is what `recognition.zig`, `filesystem.zig`, `CustomStateSet.zig` and
  `ElementInternals.zig` do.
- **`new HTMLDivElement()` — and every other element interface — throws a
  TypeError with an empty message** where Chrome says `Failed to construct
  'HTMLDivElement': Illegal constructor`. `HTMLFrameElement` and
  `HTMLMenuElement` read the same way, which is two of the seven remaining probe
  differences.
- **`new DOMMatrix('nope')` says "The string did not match the expected
  pattern"** where Chrome says `Failed to construct 'DOMMatrix': Failed to parse
  'nope'.`
- **`constructor` always lands last on a prototype.** Chrome puts a partial
  interface's members *after* it: `DOMMatrix.prototype` ends
  `… translateSelf constructor setMatrixValue`, because `setMatrixValue` comes
  from the legacy WebKitCSSMatrix partial. This engine can only produce
  `… translateSelf setMatrixValue constructor`. Same limitation as G14's.
- **`getOwnPropertyDescriptor(SomeInterface, 'prototype')` throws `TypeError:
  Illegal invocation`** for any interface whose instances carry an indexed or
  named interceptor — `FileList`, `MediaSource` and `SpeechSynthesis` all did
  before this batch. It is why `expectInterfaceObject()` is unusable in
  `speech_recognition.html`.
- **`bridge.indexed` renders an indexed slot `writable:true, enumerable:false`**
  where Chrome renders `writable:false, enumerable:true`. `FileList` read the
  same way before this batch.
- **The bespoke `?js.Function` handler accessors on `SpeechSynthesis` and
  `SpeechSynthesisUtterance` throw on a non-callable** where Chrome (and
  `window.onload`, `el.onclick`, `xhr.onload`, `signal.onabort` here) store null.
  The modules added in this batch use the `Window.FunctionSetter`-shaped union
  to get it right.
- **`internals.labels` is an Array, not a NodeList.** `input.labels` reads the
  same way; the brand is an engine-wide property of how label lists are built,
  not something this batch introduced.

## G17 batch 21: the floor, measured against the browser instead of the baseline

Batch 20 left 129 `.unsupport` spans and a plan to go after the 120 in the css
block. That plan was wrong, and finding out why took one command:

```
SITE=http://localhost:8731/ node tools/fingerprint/dump-creep-features.mjs chrome --headed
```

**Real Chrome 150 scores 128 spans against creep.js's own baseline.** Block for
block, before this batch:

| block | Chrome 150 | lightpanda |
|---|---|---|
| window | missing 2 + mapUnlit 2 = **4** | missing 2 + mapUnlit 3 = **5** |
| js | **4** | **4** |
| css | **120** | **120** |

The js and css blocks were already identical. Those 120 css keys are
`-webkit-mask-*`, `-webkit-animation-*`, `background-repeat-x/y` and the rest of
the Chrome-115-era aliases that **Chrome 150 no longer has either**. Adding them
would not have closed a gap; it would have opened a louder one, the same way
shipping `openDatabase` would.

The whole remaining difference was one entry. Chrome's unlit window map entries
are `!BarcodeDetector` and `CanvasFilter`; this engine's were `BarcodeDetector`,
`!SharedArrayBuffer` and `CanvasFilter`. `BarcodeDetector`/`!BarcodeDetector` is
a pair where exactly one is always unlit, so it costs both engines 1 and cancels;
`CanvasFilter` is unlit for both. The extra was `!SharedArrayBuffer` — lit only
when the engine does *not* have `SharedArrayBuffer`.

**So the last span was a global this engine exposed and the reference browser
does not.** Measured directly rather than inferred from the map, on a headed
Chrome 150 at the same `http://localhost:8731/` with `crossOriginIsolated`
equally false: `typeof SharedArrayBuffer` is `"undefined"` and it is not a window
own property. `Atomics` (`waitAsync` included) and `WebAssembly.Memory` are not
gated with it and stay.

This engine had always answered `crossOriginIsolated: false` while still handing
out the constructor — a page could read the contradiction directly. V8 installs
`SharedArrayBuffer` unconditionally, so it is deleted at context setup, the same
treatment the built-in `console` already gets. It lives in `Env.zig` rather than
in the snapshot because cross-origin isolation is a property of the page, not of
the engine: the day COOP+COEP is negotiated, that is where the condition goes.

### Result

`window own keys 1165 -> 1164`, `window spans 5 -> 4`, `total spans 129 -> 128`.
**That is the reference browser's own score, block for block.** G17's window
surface is finished.

### What "finished" does and does not mean

The remaining 128 spans are not reachable by adding anything:

- **120 css** — Chrome-115-era property aliases the reference Chrome dropped.
- **2 window keys** — `openDatabase` and `MutationEvent`, both `ReferenceError`
  on the reference Chrome.
- **2 window map entries** — `CanvasFilter` (absent from Chrome 150 too) and one
  half of the `BarcodeDetector`/`!BarcodeDetector` pair, which is unlit for
  whichever engine you point it at.
- **4 js** — `Element.getInnerHTML`, `Element.onbeforexrselect` and `Error.cause`
  read the same way on the reference browser; G18 already took this block to its
  floor.

Closing any of them would mean shipping something Chrome 150 does not have,
which is the louder signal. This metric is done; the next surface to work is not
CreepJS's feature spans.

## G20: HTMLElement.prototype and HTMLBodyElement.prototype

CreepJS never looks at either interface — its `globalObjects` list does not
include them — so nothing here moves the feature-span number. browserleaks-js
and anything else that walks prototypes per interface does count them, and both
were visibly short: 122 of Chrome 150's 144 own properties on
`HTMLElement.prototype`, 8 of 32 on `HTMLBodyElement.prototype`.

Everything below was measured on a headed Chrome 150 over `http://localhost`
with the `probe-g20*` scripts in `results/probes/`, not read
off the spec. The mappings the two disagree on are the point of the exercise.

### Result

| interface | Chrome 150 | before | after |
|---|---|---|---|
| `HTMLElement.prototype` | 144 | 122 (+1 surplus) | 144, 0 surplus |
| `HTMLBodyElement.prototype` | 32 | 8 | 32 |

Own-property **order** matches too: `HTMLBodyElement.prototype` is identical
entry for entry, and `HTMLElement.prototype` differs at exactly one index (see
below). Descriptor flags and getter/setter shapes match everywhere. Behaviour
probes: 963 fields compared, 18 differences, all one pre-existing bug (also
below).

### The surplus member

We declared `insertAdjacentHTML` on both `Element.prototype` and
`HTMLElement.prototype`. Chrome declares it once, on `Element`. A member no
browser has is as loud as a missing one, so the duplicate went; `Element.zig`
already forwarded to `HtmlElement.insertAdjacentHTML`, so nothing changed
behaviourally.

### Reflections that are not what they look like

Four shapes hide behind "22 missing attributes":

- **`spellcheck` and `writingSuggestions` walk ancestors, and disagree about
  how.** Both answer off the first ancestor whose value maps to a state, but
  `spellcheck`'s invalid-value default is *inherit*, so `<div spellcheck=false>
  <div spellcheck=garbage><span>` gives the span `false` — the garbage keeps
  walking. `writingsuggestions`' invalid-value default is *true*, so the same
  nesting gives `"true"` — anything that is not the `false` keyword stops the
  walk. Their empty-string states differ for the same reason: an empty
  `spellcheck` is the true state and stops, an empty `writingsuggestions` also
  stops but only because everything non-`false` does.
- **`inert` does not inherit** even though inertness as a *state* does. The IDL
  attribute is a plain boolean content attribute.
- **`draggable`'s default is per element**: `img`, and `a`/`area` carrying
  `href`. An `href` on `link`, `base` or `object` changes nothing. The getter is
  enumerated (only an ASCII case-insensitive `"true"`), the setter is a boolean
  coercion.
- **`autocapitalize` carries two legacy aliases** — `off` reads as `none` and
  `on` as `sentences` — and an absent *or empty* attribute is `""` while any
  other value is `sentences`.

`contentEditable` is the only one whose setter validates: `inherit` removes the
attribute, the three keywords are lowercased, and anything else is a
`SyntaxError` naming the value.

`focusGroup` is a `DOMTokenList` over `focusgroup`, which gave `DOMTokenList` a
second supported-token set next to `rel`'s: `inline block wrap none nomemory
toolbar`, ASCII case-insensitive. `supports()` only reports — `add('bogus')`
still writes the attribute.

### editContext dragged in a whole interface

`HTMLElement.prototype.editContext` is not a content attribute but a live
association, so its setter has to type-check against `EditContext` — and a
prototype slot whose type is not a global is a shape no browser has. So
`EditContext` (18 prototype members, `EventTarget` prototype) came with it.

It models the text buffer and the selection and nothing else, which is what
Chrome does too outside a composition: after
`updateCharacterBounds(0, [new DOMRect(0, 0, 1, 1)])` its `characterBounds()`
is still empty and `characterBoundsRangeStart` still 0. Faking those would be
inventing behaviour no headless run can produce.

Worth naming, because none of it is guessable:

- `attachedElements()` and `characterBounds()` are **methods**, not getters, and
  return a fresh array per call.
- `EditContextInit`'s selection members are plain `unsigned long` — ToUint32,
  not `[EnforceRange]` — so `-1` wraps to 4294967295 and then clamps to the text
  length, while `NaN`, `Infinity`, `{}` and `null` all become 0. The offsets
  count UTF-16 code units, so the splice has to convert from our UTF-8.
- `updateText` normalises its range but leaves the selection alone, which can
  leave it pointing past the end of the new text.
- The host set is 19 tags (`article aside blockquote body canvas div footer
  h1`–`h6 header main nav p section span`) plus anything with a valid custom
  element name, registered or not. `pre`, `li`, `form` and `textarea` are all
  refused. When a host is both unsupported *and* already carrying another
  context, the unsupported-element error is the one that comes out.

### The webkit handlers listen for a name they do not spell

`el.onwebkitanimationend` fires for `new Event('webkitAnimationEnd')` and stays
silent for `new Event('webkitanimationend')`. Our event-type map derived every
name by stripping `on` from the enum tag, which produced only the lowercase
spelling. It now takes an override table, and the derived entry is *replaced*
rather than supplemented — Chrome routes only the camel case. The same is true
of `onwebkitanimationiteration`, `onwebkitanimationstart` and
`onwebkittransitionend`. `webkitfullscreenchange` and `webkitfullscreenerror`
are genuinely lowercase and stay derived.

### HTMLBodyElement: two of the eighteen are not window handlers

Sixteen of the eighteen handlers are aliases for the Window's slot —
`document.body.onunload = f` makes `window.onunload === f`, and clearing either
clears both. `ongamepadconnected` and `ongamepaddisconnected` look identical and
are not: they are element-local, and the event has to be dispatched at the body.

The six presentational attributes do nothing at all beyond reflecting a string.
No colour parsing on the five colour ones, and no URL resolution on
`background` — `body.background` hands back the raw `"x.png"` even once the body
is in the document. The five colour ones are `[LegacyNullToEmptyString]`,
`background` is not, and that is the entire difference between them.

### Measured and not closed

- **`constructor` at index 141.** Chrome puts `constructor` there with
  `onpointerrawupdate` (a partial-interface member) after it. V8 always puts
  `constructor` last on a template's prototype, so ours are swapped. Same
  engine-level limitation already recorded for `DOMMatrix.setMatrixValue` and
  `SVGLength`. `HTMLBodyElement` is unaffected — `constructor` is last there in
  Chrome too.
- **`JSON.stringify(el.classList)` is `{}` for us and `{"0":"a","1":"b"}` for
  Chrome.** Our `DOMTokenList` serves indexed access through an interceptor but
  does not report the indices as own properties, so
  `Object.getOwnPropertyNames(classList)` is empty. Pre-existing and
  interface-wide — `classList`, `relList` and the new `focusGroup` all do it —
  and every one of the 18 behaviour-probe differences is this one bug.
- **`window.onhashchange` does not fire for a manually dispatched
  `hashchange`.** The engine dispatches its own hashchange through
  `dispatchDirect`, passing `_on_hashchange` explicitly, so the generic
  inline-handler lookup never learns about it. Same for the other five handlers
  with a dedicated Window field (`onmessage`, `onpageshow`, `onpopstate`,
  `onrejectionhandled`, `onunhandledrejection`). Surfaced here because
  `body.onhashchange` now aliases that slot; the cause is on the Window side and
  wiring it into the generic lookup risks double-firing on the real path.
- **`Document.createEvent`'s refusal message is a use-after-free.**
  `invalidEventType` in `Document.zig` builds the message from
  `frame.local_arena` and hands it to `DOMException.init`, which keeps the slice
  rather than copying (every other caller passes a literal). The arena is reset
  after the call, so reading `err.message` later reads freed memory. The same
  mistake in `contentEditable`'s setter segfaulted the suite under a dirty heap
  before being caught; the fix there was `frame.arena`.

## G8: iphey's `i20: TypeError: Illegal invocation`, attributed

iphey has alerted this since before any of this work started and it had never
been pinned to an API. It is now: **every `console` method throws
`Illegal invocation` when called without a receiver.**

### How it was pinned

iphey swallows the error and alerts `String(err)`, which throws away the stack —
but `String(err)` on an `Error` routes through `Error.prototype.toString`, and
that is reachable. Patching it from
`Page.addScriptToEvaluateOnNewDocument` records `this.stack` before the message
is flattened (`run-iphey.mjs` in `results/probes/`):

```
TypeError: Illegal invocation
  at Object.<anonymous>  (cdn.iphey.com/index.js:25:2520)
  at Object.isOpen       (cdn.iphey.com/index.js:25:2418)
  at m5                  (cdn.iphey.com/index.js:26:435002)
```

`i20` is a **devtools detector** called `dep-reg-to-string`, the classic
"a RegExp whose toString sets a flag, logged and then cleared":

```js
var I = / /, T = false;
I.toString = function () { T = true; return D.name; };
var D = { name: 'dep-reg-to-string', isOpen: function () {
  T = false;
  Object(t.c)({ dep: I });   // <- throws here
  Object(t.a)();
  return T;
} };
```

`Object(fn)(...)` is a call with **no receiver**. `t.c` and `t.a` are console
methods, so what iphey is doing is `console.log.call(undefined, …)` — and every
one of ours refuses it.

### The isolated repro

`probe-g8a.js`, both engines, `http://localhost`:

| | Chrome 150 | this engine |
|---|---|---|
| `const f = console.log; f({})` | runs | `TypeError: Illegal invocation` |
| `console.log.call(undefined, {})` | runs | `TypeError: Illegal invocation` |
| `console.log.call(window, {})` | runs | `TypeError: Illegal invocation` |

All 18 of our console methods fail all three ways. Chrome's only complaint
across its 24 is `createTask`, and that is about its argument, not its receiver.
Chrome's console is a namespace whose methods do not brand-check `this` at all;
ours go through the bridge's normal receiver unwrap, which does.

### Also measured while there, not part of i20

- **`i19` is a second alert, new since the last sweep**: `TypeError: Cannot set
  properties of undefined (setting 'position')`, thrown in iphey's `T2`
  (`index.js:63:126758`), not yet attributed.
- **Our console roster does not match Chrome's.** We expose `exception`, which
  Chrome does not, and we are missing `dir`, `dirxml`, `profile`, `profileEnd`,
  `timeStamp`, `context` and `createTask`. Chrome has 24 function members and we
  have 18.
- **Fourteen of iphey's own probes throw inside its `permissions.query` sweep**
  on Chrome too (`'speaker' is not a valid enum value`, `Web NFC is not
  enabled`, …). Those are Chrome's own refusals for unsupported permission
  names, caught and expected by iphey — noise, not signal.

## G8b: the console surface, closed

G8 left two things open on `console`: the receiver check behind iphey's `i20`,
and a member roster that matched neither Chrome's contents nor its order. Both
are now closed, and every console probe (`probe-g8a` … `probe-g8f`) diffs clean
against a headed Chrome 150 apart from live heap byte counts.

### The receiver check

Every member is now bound `.static`. That drops two things at once: v8's
`Signature` on the method's `FunctionTemplate` (which is what actually produced
`Illegal invocation`, before our callback ever ran) and the bridge's
`TaggedOpaque.fromJS` unwrap of `this`. The five members that really do need
state — `count`, `countReset`, `time`, `timeLog`, `timeEnd` — reach the realm's
`Console` through `exec.js.global` instead of through `self` (`Console.realm`).

**iphey's `i20` is gone**: re-running `run-iphey.mjs` against the patched binary
leaves exactly one alert, the already-known `i19`.

### The member table

Chrome 150, `Object.getOwnPropertyNames(console)` — 25 members, in an order that
is neither alphabetical nor the Console Standard's IDL order, so it can only be
copied:

```
debug, error, info, log, warn, dir, dirxml, table, trace, group,
groupCollapsed, groupEnd, clear, count, countReset, assert, profile,
profileEnd, time, timeLog, timeEnd, timeStamp, context, createTask, memory
```

We were at 18 with `exception` — which Chrome does not have — in the set.
`memory` is the 25th: G8's count of 24 came from a probe that filtered to
`typeof === 'function'`, and `memory` is an accessor.

Every function reports `length` 0, `context` excepted (1). A variadic argument
contributes nothing to `length`, and every console operation but `context` is
variadic — including `assert`, whose IDL declares a required `condition`.

### What the new members actually do (measured, not guessed)

| member | Chrome's behaviour |
|---|---|
| `dir`, `dirxml` | log and return undefined; the interactive tree is devtools-only |
| `profile`, `profileEnd`, `timeStamp` | return undefined with or without an argument |
| `context(name)` | a **fresh** plain object (`[object Object]`, `Object.prototype` proto) carrying its own 22 logging operations, each writable/enumerable/configurable with `length` 1. Note `dirXml` — capitalised differently there than on `console` itself. `console.context()` with no argument works too |
| `createTask(name)` | a plain object with one own `run` (`length` 0) that invokes its callback and returns the result. `run()` with no function throws `Error: First argument must be a function.` |
| `memory` | the same `MemoryInfo` `performance.memory` hands out — the two share a prototype — fresh per read |

Two traps worth keeping:

- **`createTask` runs no ToString on its name.** `123`, `null`, `true`,
  `new String('t')` and `{toString: () => 't'}` are all rejected with the same
  plain `Error: First argument must be a non-empty string.` (`probe-g8f`).
  Taking a `?[]const u8` parameter would have coerced them and answered a task
  where Chrome answers an error — and iphey's devtools probes pass objects.
- **Both errors are a plain `Error`, not a `TypeError`.**

### `console.memory` is not a WebIDL attribute

Blink names every WebIDL attribute's accessor pair `get X` / `set X`, and we
match that: `Navigator.prototype.userAgent`, `Document.prototype.title` and
`performance.memory` all report `"get …"` on both engines. `console.memory` is
V8's own accessor instead, and both halves of it are anonymous with a
zero-length setter. That is what the new `anonymous` option on
`bridge.accessor` is for; `console.memory` is its only user.

The setter is a silent no-op on Chrome — `console.memory = 5` leaves
`typeof console.memory === 'object'` — so ours ignores its argument too.

### Still open on iphey

`i19: TypeError: Cannot set properties of undefined (setting 'position')`,
thrown in iphey's own `T2` (`index.js:63:126758`). Unattributed; it is the only
alert left.

## G9: where an `on*` handler sits in the listener order

Per DOM, an event handler *is* an event listener. It joins the target's
listener list the moment the property (or content attribute) is first set, and
it runs from that place: re-assigning the property swaps the function without
moving the listener, assigning `null` removes it, and assigning again appends at
the end. We kept handlers in a side table (`Frame._event_target_attr_listeners`)
and ran them ahead of the list at all three dispatch points, so a handler always
fired first.

Measured with `probe-g9` on a headed Chrome 150 versus our pre-fix binary — five
of nine cases were wrong:

| case | Chrome | ours (before) |
|---|---|---|
| `addEventListener` → `onclick` → `addEventListener` | `al1,on,al2` | `on,al1,al2` |
| `onclick` → `addEventListener` | `on,al1` | same |
| re-assign `onclick` without clearing | `al1,on-second,al2` | `on-second,al1,al2` |
| `onclick = null`, then assign again | `al1,al2,on-second` | `on-second,al1,al2` |
| parsed `onclick=` before `addEventListener` | `on,al1` | same |
| `setAttribute('onclick')` after `addEventListener` | `al1,on,al2` | `on,al1,al2` |
| `window.ong9evt` (not a handler name) | `al1,al2` | same |
| same three steps on `document` | `al1,on,al2` | `on,al1,al2` |
| ancestor capture listener vs handler at target | `parent-capture,child-on,child-al,parent-bubble` | same |

### The fix

`EventManagerBase.registerHandler` appends a real `Listener` whose `Function` is
just the handler *kind*; the function is resolved from the side table (or
compiled from the content attribute) when the listener runs. That is what buys
the re-assignment semantics for free — the table entry changes, the list node
does not — and it deletes the three special-cased inline-handler branches.

The content attribute was the one part that could not stay lazy. We compiled
`onclick="…"` at first dispatch and only then recorded it, which is far too late
to decide where it sits; the spot is now claimed when the attribute is set —
`Frame.attributeChange` / `attributeRemove` for scripted changes, and
`Attribute.List.putNew` for the attributes the parser puts on a new element,
which fires no change reactions.

`Frame.setEventHandler` is the single entry point, so Element, Document,
ShadowRoot, EditContext, MediaQueryList and the Window's ~120 store-backed
handler properties all get the ordering. After the change `probe-g9` diffs clean
against Chrome, as does `probe-g9b`, which pins the parts the first probe left
untested: `stopImmediatePropagation` from a handler, `stopPropagation` from one
(it does *not* skip the target's remaining listeners — we used to, and that is
fixed by the same move), `return false` cancelling, `removeEventListener` being
unable to take a handler away, the same function registered both ways running
twice, a content attribute overriding a property without moving it,
`removeAttribute` clearing the handler, re-`setAttribute` recompiling, and a
handler assigned mid-dispatch not running for that event.

### Still open: the handlers that live in a dedicated field

Only the side-table-backed handlers moved. Anything whose handler is a field on
its owner still runs ahead of the listener list, because nothing records *when*
that field was first written. Measured with `probe-g9c` (`al1,on,al2` is
Chrome's answer in every row):

| target | ours |
|---|---|
| `window.onscroll` / `onblur` / `onfocus` / `onresize` (4 of the Window's 6 dedicated slots) | `on,al1,al2` |
| `XMLHttpRequest.onprogress` | `on,al1,al2` |
| `AbortSignal.onabort` | `on,al1,al2` |
| `FileReader.onload` | `al1,al2` |
| `BroadcastChannel.onmessage` | `al1,al2` |

The last two are a second, older gap: their handler field is only consulted on
the object's own internal dispatch path, so a synthetic `dispatchEvent` skips it
entirely. Closing this row of the table means giving ~30 classes
(`XMLHttpRequestEventTarget`, `WebSocket`, `EventSource`, `FileReader`, the IDB
trio, `Worker`, `MessagePort`, `BroadcastChannel`, …) the same treatment, plus
untangling the Window's six slots from the explicit `dispatchDirect` calls that
pass them by hand (page load, pageshow, hashchange, popstate).

## G10: can an OfflineAudioContext render be aligned with Chrome sample for sample?

**No — not as a computation.** The render is a function of the host, by
construction, so there is no single set of samples that "Chrome" produces.
Below is what we read in Blink's source (fetched from Chromium main this
session) and what we measured on a headed Chrome 150.

### What a detector actually reads

The canonical audio fingerprint — fingerprintjs and every clone — is one graph:
a triangle `OscillatorNode` at 10 kHz through a `DynamicsCompressorNode`
(threshold -50, knee 40, ratio 12, attack 0, release 0.25) into a
`OfflineAudioContext(1, 5000, 44100)` destination, then the sum of
`|sample|` over frames 4500..4999, read at full double precision.

Measured here (`probe-g10`, macOS/arm64, Chrome 150):

| quantity | value |
|---|---|
| canonical sum | `124.04347624466754` |
| same graph rendered twice in one page | identical |
| headed vs headless | identical |
| oscillator alone, no compressor | `258.09813959815074` |
| built-in 440 Hz "sine" vs closed-form `sin()` | max deviation `1.18e-6` |

The last row is the important one: the built-in sine is *not* `sin()`. It is a
band-limited wavetable, and reproducing it means reproducing how that table was
built, not what it approximates. Head/headless parity says the number is a pure
function of the build and the CPU — which is exactly what makes it a
fingerprint.

### Why the number is host-dependent (read in source, not inferred)

**The wavetable.** `PeriodicWaveImpl::PeriodicWaveSize()` is 4096 at 44.1 kHz
and `NumberOfRanges()` is `0.5 + 3*log2(4096)` = 36. `CreateBandLimitedTables`
runs **36 inverse FFTs of size 4096**, one per pitch range, culling partials
per range, and normalizes every table by `1/peak` of range 0.
`FFTFrame::DoInverseFFT` is backed by **Accelerate/vDSP on macOS and PFFFT
everywhere else** (`#if BUILDFLAG(IS_MAC)` in `platform/audio/fft_frame.h`).
Two different FFT implementations do not agree in the last bits, so the tables
themselves differ by platform before a single sample is rendered.

**The interpolation.** `modules/webaudio/BUILD.gn` adds
`cpu/x86/oscillator_kernel_sse2.cc` on x86 and `cpu/arm/oscillator_kernel_neon.cc`
on NEON; `oscillator_handler.cc` guards its generic versions with
`#if !(ARCH_CPU_X86_FAMILY || CPU_ARM_NEON)`. Same for `vector_math`, which
picks mac/neon/x86/scalar and does a **runtime** AVX check on non-Mac x86. The
floating-point operation order therefore depends on the arch and, on x86, on
the CPU the page happens to be running on.

**The compressor.** `DynamicsCompressor::Process` is careful in three places —
`fdlibm::powf` twice and `fdlibm::asinf` once, which are Chromium's own
deterministic implementations — and not careful anywhere else:

- `audio_utilities::DecibelsToLinear` / `LinearToDecibels` call **unqualified**
  `powf` / `log10f`. That file includes `third_party/fdlibm/ieee754.h` but does
  not use it here, so these are the platform's libm. Both are called *per
  sample* in the inner loop.
- The gain warp in the inner loop is `sin()` on a `double` — platform libm.
- `KneeCurve` uses `exp()` on a `double` — platform libm.
- `DenormalDisabler::FlushDenormalFloatToZero` is applied to the two state
  variables every 32 frames, so the FPU's denormal mode is part of the answer.

### What matching one chosen platform would cost

Picking a single target (say Linux/x86-64 with a fixed SIMD level) makes the
question well posed, and it is still expensive:

1. A bit-exact port of that platform's FFT. PFFFT is portable C and small, so a
   non-Mac target is at least *possible*; **vDSP is closed source, so a macOS
   target is not**.
2. A bit-exact port of that arch's oscillator interpolation kernel, matching
   operation order, not just the formula.
3. Bit-exact `powf`, `log10f`, `exp` and `sin` for that platform's libm.
   Chromium's own fdlibm covers the first two shapes but is *not* what
   `audio_utilities` calls, so using fdlibm gives a different answer than
   Chrome on that same platform.
4. The graph plumbing around it: 128-frame render quanta, channel up/down mix,
   the 6 ms pre-delay ring buffer, AudioParam automation.

And the tolerance is unforgiving. The detector reads the sum of 500 `f32`
samples printed as a double: one 1-ULP difference anywhere in the tail
(~6e-8) changes the printed string, so "close" is worth exactly as much as
"silent".

### The options, and which one is worth it

- **(a) Keep rendering silence** (what we do today). Correct for an empty
  graph — Chrome renders zeros there too, measured in win18/win19 — and a
  constant for every graph with a source in it. Cheap; the tell is that the
  number never moves.
- **(b) Replay a captured buffer.** Record Chrome's 5000 samples for the
  canonical graph on one chosen platform and return them when the graph matches
  that shape. Exactly right for the one graph detectors actually use, wrong for
  anything else, and it pins us to whatever platform the rest of the fingerprint
  claims to be.
- **(c) Implement the graph honestly** with a ported PFFFT and fdlibm
  throughout. Gives audio that is non-constant and moves with the parameters,
  which defeats a detector that only checks "did it change", but matches no real
  Chrome's number, which defeats nothing that compares hashes.

**Recommendation: (b) if the audio hash is worth spending on, otherwise stay on
(a).** (c) is the most work for the least benefit against a hash-comparing
detector; it only pays off against a detector that probes the graph rather than
hashing one fixed render.

## G11: the re-sweep, and the regression it found

All twelve detectors, both engines, same day, **matched viewport** — the point
of the exercise. `detectors-chrome-headed.json` and `detectors-lightpanda.json`
are the current pair; `detectors-api-gaps-lightpanda.json` and its siblings stay
as the historical columns of the plans that produced them, not as live
baselines.

### Two things had to be fixed before the numbers meant anything

**The viewport.** `--window-size` is not enough on macOS: the window manager
clamps a real Chrome window to the display, so a request for 1920 silently
became 1512 here. The sweep now sends `Emulation.setDeviceMetricsOverride` to
whichever engine it is driving, and `extractReach` records the width each page
actually saw. That guard paid for itself immediately — the first run after
adding it reported `w=1512` instead of the 1920 it had asked for.

**The route.** The README's standing rule is that a sweep over a fake-IP tunnel
is a measurement, not a finding. Checked before running rather than assumed:
the system proxies are all disabled, the default route is a plain LAN gateway on
`en0` with no `utun` in the path, and eleven of the twelve sites answered a
direct `curl` in under 2.4 s with no TLS failure. `arh.antoinevastel.com` (which
hosts both `areyouheadless` and `fpscanner`) returns a persistent HTTP 502 — the
site is down, on three consecutive checks, which is why both read 8 nodes.

### The regression: CreepJS had stopped finishing

The sweep found lightpanda rendering **249 nodes / 1347 characters** of CreepJS
against Chrome's 3758, stuck on `FP ID: Computing...`. The page had every
section heading and not one value: `Window keys (0)`, `Navigator properties (0)`,
`Computed Style keys (0)`, `mimeTypes (0)`, `plugins (0)`.

`git bisect` over the 154 commits since the last good sweep (`dev.56+339149740`,
which produced a full fingerprint, id `cc9eb98f6aa9…`) landed on **`b2ebdb27e`,
the commit that added `OfflineAudioContext`** — seven builds, each one asked the
same question: does CreepJS produce an id?

The mechanism, once pointed at:

```js
// creep.js, hasFakeAudio()
context.startRendering();
return new Promise((resolve) => {
    context.oncomplete = (event) => { /* … */ };   // assigned AFTER the call
});
```

That promise has no timeout and no reject path. `getRenderedBuffer()` does the
same through `addEventListener('complete', …)`, also after the call, and a
`Promise.all` upstream awaits both. Our `startRendering()` did the entire render
inline — state transitions, clock, `complete` event, promise — so by the time
either handler was attached the event had already been dispatched to nobody, and
CreepJS waited forever.

Isolated rather than assumed: the viewport override was ruled out first (same
249/1347 with and without it), then a page that logs each step showed
`startRendering()`'s promise resolving while neither `oncomplete` nor the
listener ever fired — and both firing when attached *before* the call.

**The fix** moves the completion into a scheduled task. Measured on a headed
Chrome 150 (`probe-g11b`) and now reproduced: the call returns with the state
still `running`, a microtask queued right after it runs *before* the event, the
`complete` event fires, and the promise settles last. The clock also lands on a
whole number of 128-frame render quanta — 100 frames at 44100 gives `128/44100`,
not `100/44100` — measured across 1/100/128/129/5000 at 44100 and 256/300 at
48000.

CreepJS went from 1347 characters to **87881**, with a real fingerprint id.

### Where the twelve stand now

Node counts, both engines at 1920×1080 on the same day:

| site | Chrome (headed) | lightpanda | note |
|---|---|---|---|
| pixelscan | 1828 | **1828** | exact |
| deviceinfo | 263 | **263** | exact |
| sannysoft | 290 | 291 | +1 |
| iphey | 487 | 485 | −2 |
| browserleaks-js | 1180 | 1184 | +4 |
| rebrowser | 91 | 98 | +7 |
| browserleaks-tls | 7 | 5 | −2 |
| creepjs | 3758 | 3607 | −151 |
| browserscan | 2063 | 1376 | **−687, open** |
| amiunique | 1551 | 571 | **−980, open** |
| areyouheadless / fpscanner | 8 | 8 | host is 502, not measurable |

**G7's pixelscan finding is settled.** It recorded us +184 elements over Chrome
and suspected the viewport; at a matched 1920 the two are 1828 and 1828. The
gap was entirely the window width — there was never a pixelscan difference.

**G6's browserleaks-js −141 is closed** as a side effect of the batches since:
1180 against 1184.

Two sites remain open — **amiunique (−980)** and **browserscan (−687)**. Both
render their shell and stop short. Both are attributed and amiunique is closed
in the G23 section below; browserscan's remainder is −178 and is waiting on RSA
in SubtleCrypto.

## G23: amiunique and browserscan, attributed

Both sites rendered their shell and stopped short. They turned out to share a
first cause, and browserscan has a second one behind it.

### One missing accessor cost amiunique its whole result table

amiunique's Vue bundle (`_nuxt/66e1ca0.js`) does `t.style[r] = n` where `t` is
an SVG element. On lightpanda `t.style` was `undefined`, so that line threw
`TypeError: Cannot set properties of undefined (setting 'transform')`, the
uncaught throw aborted the render, and the *Javascript attributes* table — the
entire point of the page — displayed "No data available".

`probe-g23.js` asks fourteen kinds of element for their `style` and reports
where the descriptor lives. Chrome answers `[object CSSStyleDeclaration]` for
every SVG element including one with an invented tag, and finds the descriptor
on **`SVGElement.prototype`, three hops up**. We answered `undefined` for all
four and "not found on the chain": `style` was declared on
`HTMLElement.prototype` only. `attributeStyleMap` sits next to it in Chrome and
was missing for the same reason.

Both now forward to the machinery `Element` already had (`getOrCreateStyle` /
`setStyle` / `getPropertyMap`). The measured Chrome semantics that
`element/svg/style.html` pins: `e.style === e.style`; `setAttribute('style',
'fill:red')` then `e.style.fill === 'red'` and `cssText === 'fill: red;'`;
`e.style.fill = 'blue'` then `getAttribute('style') === 'fill: blue;'`.

| site | Chrome (headed) | lightpanda before | after |
|---|---|---|---|
| amiunique | 1551 | 571 (−980) | **1560 (+9)** |
| browserscan | 2063 | 1376 (−687) | **1885 (−178)** |
| iphey | 487 | 485 (−2) | **487 (0)** |

iphey's outstanding `i19: Cannot set properties of undefined (setting
'position')` was the same shape and went with it.

**Known divergence, not closed here:** a `CSSStyleDeclaration` is parsed from
the `style` attribute when it is first materialised and is not resynced
afterwards, so `el.style` read *before* a later `setAttribute('style', …)` keeps
the old text. This is engine-wide (a plain `div` behaves the same), not an SVG
thing, and out of G23's scope.

### browserscan's remaining −178: ads, and one algorithm

Section diff (`browserscan-diff.mjs`, `DEPTH=7`, both engines pinned to 1920):

* **~75–80 nodes are third-party** and carry no detection signal: the
  `fc-ccpa-root` consent dialog (21), `google-auto-placed` / `ins.adsbygoogle`
  units inside the page (≈47), body-level ad iframes (≈8), a hover tooltip (4).
  The only console error either engine logs on this page comes from AdSense.
* **The rest are values that never arrived.** The *Hardware* card renders every
  label — visitor ID, Canvas, WebGL, Unmasked Vendor/Renderer, Audio, Client
  Rects, WebGPU, Screen Resolution, Color Depth, Device Memory, Hardware
  Concurrency — and each value slot holds `<div class="skeleton">` instead of a
  hash. It is not that we answer blank: the data never came back.

Nothing is logged because Vue swallows it, so `browserscan-sentry.mjs` taps
`fetch` / XHR / `sendBeacon` through `Page.addScriptToEvaluateOnNewDocument`
before any page script runs (browserscan ships ~20 envelopes to
`sentry.adspower.com` while rendering — that was the tell). Wrapping the async
suspects gives the name back:

```
reject crypto.subtle.importKey => NotSupportedError: The operation is not supported
                                  args=spki,[object ArrayBuffer],RSA-OAEP,…
```

browserscan imports an RSA-OAEP public key, encrypts a session key with it, and
sends it as `_k` alongside the encrypted payload `_p`. Measured, same tap on
both engines:

```
chrome      /api/a60aeea3?_k=JloqJCNwzfy35U2ihTXovIhw%2BB%2FrdxNP…&_p=…
lightpanda  /api/a60aeea3?_k&_p=…
```

Every `/api/*` call we make comes back **407**; Chrome's succeed. `probe-g23c.js`
against both engines: `importKey('spki', …, 'RSA-OAEP')`, `generateKey`
RSA-OAEP and `generateKey` RSASSA-PKCS1-v1_5 all reject NotSupportedError here
and all work in Chrome, while AES-GCM, ECDH P-256 and SHA-256 digest work in
both. **Our SubtleCrypto has no RSA at all.** That is one algorithm family
standing between us and every value-bearing card on browserscan.

### Smaller things this measurement turned up

* `document.fonts.ready` resolves to `undefined` (Chrome resolves the
  `FontFaceSet` itself), so `(await document.fonts.ready).status` throws.
* `Element.setAttributeNS` ignores the xlink namespace, so browserscan's
  `<use xlink:href="#icon">` serialises as `<use href="#icon">`.
* browserscan's font list reads 0 fonts against Chrome's 342 (hash `DA39A3EE`
  is SHA-1 of the empty string) and its WebRTC rows read "disabled" — both are
  known engine surfaces, both cost only a handful of nodes.
* `document.createElementNS(SVG, 'nope')` brands as `SVGGenericElement` where
  Chrome says `SVGElement`; `SVGGenericElement` is already on G17's list of
  globals Chrome does not have.

## G24: what `createElementNS` builds outside the three known namespaces

Found while fixing G23. `probe-g24.js` asks for nine element/namespace
combinations and reports the brand, the constructor, the full prototype chain,
the tag name casing and whether a `style` and a `dataset` came with it.

Chrome's rule is one line: **only the XHTML namespace produces an HTML
element.** `null`, `''`, `urn:x` and the XML namespace each produce a bare
`Element` — `[object Element]`, `constructor === Element`, chain exactly
`Element < Node < EventTarget`, tag name case-preserved, and no `style` or
`dataset` at all. An empty namespace string reads back as `namespaceURI ===
null`, not `""`.

We built an `HTMLUnknownElement` for all of them, which meant a foreign element
answered `[object HTMLUnknownElement]`, carried a `CSSStyleDeclaration` and an
extra `HTMLElement` on its prototype chain, and reported `namespaceURI === ""`
for the empty namespace.

The interesting constraint is in the fix rather than the finding.
`Element._type` is the union the JS bridge reads to decide which class to brand
an instance with: it walks to whatever the active variant points at. Any
payload — a pointer or an inline struct — is therefore a class of its own, and
a class of its own is a fourth prototype in the chain, which the probe would
see. The one variant the bridge passes through untouched is `void`, so `plain`
carries no payload and the tag name lives on `Element` instead of on a subtype.

Measured after the change: `probe-g24` is **0 diffs across all 11 keys** against
headed Chrome 150.

**Not closed, and pre-existing:** Chrome matches a type selector against a
foreign element ASCII-case-insensitively (`querySelector('Thing')` and
`querySelector('thing')` both find `<Thing>` in an HTML document), while
`getElementsByTagName` stays case-sensitive. We match neither selector — for a
plain element or for an SVG element with a mixed-case tag such as `clipPath` —
because `matchesPart` compares a lowercased selector against a case-preserved
tag name. Unchanged by this task, in either direction.

## G12: CSS custom properties, all three layers

CreepJS's `@media` row reads a `--custom-property` back out of
`getComputedStyle` after setting it inside a media block. Ours answered `""`,
and `probe-g12.js` (23 observations against headed Chrome 150) found the gap
starts one layer earlier than the plan assumed and runs two layers deeper.

### Layer 1 — the style attribute dropped them at the tokenizer

`el.setAttribute('style', '--a: 1')` left `el.style` empty, `el.style.length`
zero, and a later `setProperty` rewrote the attribute with only the new value.
The imperative path (`setProperty('--a', '1')`) worked, which is why the
existing Typed OM coverage never caught it: it only ever set custom properties
that way.

`isIdentStart` rejected a second dash, so `--a` tokenised as a delim and the
declaration was skipped as invalid. Per CSS Syntax §4.3.9 a second `-` ends the
check on its own. Three measured Chrome behaviours came with the fix
(`probe-g12b`):

* names are case-sensitive — `--Case` and `--case` are two properties, and only
  custom names escape the lowercasing every other property name gets;
* values are stored verbatim minus the surrounding whitespace: `--c: 01.50`
  stays `01.50` (no leading-zero normalisation), `--e: a  b   c` keeps its
  inner runs, `1PX` keeps its case;
* an empty value is a valid declaration for a custom property (`--d:;` is kept
  and enumerated) where the same for a normal property is not.

### Layer 2 — stylesheet rules never reached the cascade

`StyleManager` keeps a fixed set of properties per rule — the visibility
filter's four, plus font-size and font-family — because those are all the faux
computed style ever answered. A custom property has no fixed name to pick from,
so rules now carry every custom declaration they hold, and a computed read
resolves one through the same cascade: importance over the style attribute,
then specificity, then document order, then a walk to the parent, because
custom properties inherit. Measured and pinned in
`tests/css/custom_properties_cascade.html`: inline beats the sheet, `#id` beats
`.class`, `!important` beats `#id`, a later rule of equal specificity wins, a
matching `@media` block contributes and a non-matching one does not, `:root`
reaches every element, and a detached element inherits nothing.

### Layer 3 — var() substitution

Substitution happens at computed-value time; the specified value keeps its
`var()` text (`el.style.getPropertyValue('--x')` still reads `var(--y)`). What
`probe-g12d` measured, and what `tests/css/custom_properties_var.html` now
pins:

| input | Chrome |
|---|---|
| `--with-var: var(--defined)` | `dv` (chains resolve) |
| `--fallback-used: var(--nope, fb)` | `fb` |
| `--fallback-unused: var(--defined, fb)` | `dv` |
| `--empty: ;` then `var(--empty, fb)` | `""` — declared-empty suppresses the fallback |
| `var(--nope, a, b)` | `a, b` — the fallback is everything after the first comma |
| `var(--nope, var(--defined))` | `dv` |
| `pre var(--defined) post` | `pre dv post` |
| `--cycle-a: var(--cycle-b); --cycle-b: var(--cycle-a)` | `""` — invalid at computed-value time |

### Where it landed

`probe-g12` against headed Chrome 150: **20 of 23 observations identical**, from
3 of 23 before. What is left:

* `color: var(--never, rgb(1, 2, 3))` and `width: var(--never2, 42px)` declared
  **in a stylesheet** still read the engine's defaults. Not a var() gap — the
  same declaration inline resolves correctly — but the pre-existing one where
  the faux computed style consults stylesheet rules for `display` and
  `visibility` only. Closing it means a general cascade for arbitrary
  properties, which is its own task.
* The custom names a computed style enumerates now match Chrome's set exactly
  (the same ten on the probe page); the order within that tail is Blink's
  internal one and is not reproduced.

## G22: the handler properties that lived in a field

G9 moved the store-backed handlers into the listener list and left a table of
what still ran in the wrong order — "the handlers that live in a dedicated
field", ~30 classes plus the Window's own slots. G22 is that table, closed.

A handler kept in a field on its owner has two problems at once. It has no
place in the listener list, so it cannot be ordered against `addEventListener`;
and it is only read on whatever internal dispatch path its owner happens to
have, so a scripted `dispatchEvent` skips it entirely. Which of the two a page
sees depends on the class, which is why the row for `window.onscroll` measured
`on,al1,al2` and the row for `FileReader.onload` measured `al1,al2`.

Both are the same fix: the function goes in the event manager's handler store,
and a `Listener` standing for the handler joins the target's list at the moment
the property is first set. Re-assigning swaps the stored function and leaves
the list node alone; assigning `null` removes the node, so assigning again
appends at the end. The owner's own dispatch path stops passing the handler by
hand and passes `null` — the list already has it.

| step | what moved | properties |
|---|---|---|
| P1 | the store itself, from `Frame` to `EventManagerBase`, so workers reach it too; `BroadcastChannel` as the first class through it | 2 |
| P2 | the Window's dedicated slots, including `onerror`'s five-argument / `return true` convention | 12 |
| P3 | `XMLHttpRequestEventTarget` + `XMLHttpRequest.onreadystatechange` | 8 |
| P4 | the classes with a real internal dispatch path: `FileReader`, `MessagePort`, `AbortSignal`, `WebSocket`, `EventSource`, `Worker`, `Animation`, the IDB four | 32 |
| P5 | the wide G17 stub surface — webxr, webgpu, webcodecs, sensor, midi, presentation, payment, speech, media, webrtc, the navigator singletons | 168 |

### What P5 had to change underneath

* **`Handler` outgrew a `u8`.** The stub surface needed 95 names it did not
  have, for 261. `Key` used to fuse the target pointer and the tag into a
  single `u64` and compare *that*, which is where the 256 cap came from.
  Hashing the pair and comparing the two fields instead lifts the cap and drops
  the pointer-alignment assumption the fusion carried.
* **`hasListeners` answered from the wrong thing.** It returned true when the
  lookup *entry* existed, and `removeListener` leaves the emptied list behind.
  Harmless while handlers lived in fields; once `target.onx = f; target.onx =
  null` goes through that list, it left the target looking permanently
  subscribed — caught by `cookie_store.html`, which asserts that a change
  enqueued with nobody listening is not delivered to a listener that registers
  later.
* **The lenient setters were four copies of one union.** An IDL `EventHandler`
  takes anything: `rec.onend = 5` reads back null on Chrome rather than
  throwing. `FileWriter`, `SpeechRecognition`, `CookieStore`, the codecs and the
  worker scopes each had their own two-variant union for that; they share
  `handler_property.lenientAccessors` now.

### Where it landed

`probe-g22g` covers 100 rows across 60 interfaces. Against a headed Chrome 150:
**97 of 100 identical**, 94 of them the `al1,on,al2` that every handler property
owes. `probe-g9`, `probe-g9b` and `probe-g9c` — the probes that opened G9 — now
diff clean at 9/9, 14/14 and 8/8, so the table G9 left open has no rows in it.

What the last three rows are, both of them structural rather than ordering:

* **`Performance` is not an `EventTarget` here and is one in Chrome**
  (measured: `performance.addEventListener` is undefined for us and runs
  there). The store is keyed by EventTarget, so
  `onresourcetimingbufferfull` is the one handler property still in a field.
  Giving `Performance` that prototype is a separate change — it adds a link to
  a prototype chain, which is its own observable.
* **`ScreenOrientation.prototype.onchange` is missing entirely.** Chrome has it;
  we never declared it. Not an ordering gap — there is nothing to order.

Adjacent, measured while probing, and deliberately left alone: an uncaught
exception thrown from a `setTimeout` callback never reaches the Window's error
listeners (Chrome runs them with the five-argument convention), our error
messages lack Chrome's `Uncaught ` prefix, `Worker.prototype.onmessageerror`
exists here and does not in Chrome, `IDBDatabase.prototype` is missing
`onabort` / `onclose` / `onversionchange`, `FileReader.prototype`'s six `on*`
are in alphabetical order where Chrome's are in spec order, and
`WorkerGlobalScope`'s own `onerror` / `onrejectionhandled` /
`onunhandledrejection` are still field-backed — `onerror` there wants the same
five-argument treatment P2 gave the Window's, which is what makes it its own
task rather than part of the sweep.

## G25: SubtleCrypto's RSA family

G23 attributed browserscan's empty value cards: it wraps its fingerprint
payload with RSA-OAEP before it POSTs, and every RSA algorithm here answered
`NotSupportedError` — `generateKey` never got as far as producing a key, so
nothing downstream ran. G25 is that family, implemented.

`probe-g25` generates its own key for every row and round-trips it, so a row
that fails fails on the operation rather than on a stale test vector. The one
hardcoded SPKI in the output is a key the probe generated in Chrome, which
makes it real DER by construction.

| step | what it added |
|---|---|
| P1 | `generateKey` for RSA-OAEP / RSASSA-PKCS1-v1_5 / RSA-PSS: a real `EVP_PKEY` pair, the usages split across the two halves, `publicExponent` read back off the generated key |
| P2 | `exportKey` `spki` / `pkcs8` |
| P3 | `importKey` `spki` / `pkcs8` |
| P4 | `exportKey` / `importKey` `jwk`, both halves |
| P5 | `encrypt` / `decrypt` under RSA-OAEP, label included |
| P6 | `sign` / `verify` under both signature schemes |

### What the implementation had to get right

* **Every RSA operation goes through an `EVP_PKEY_CTX`, never the `RSA_*`
  entry points.** Those cannot set the OAEP or MGF-1 digest — BoringSSL
  documents them as always SHA-1 — so a `RSA_encrypt` shortcut would have
  produced blocks that are valid RSA and wrong WebCrypto. MGF-1 itself is left
  unset, because its default *is* the OAEP digest, which is what the spec asks
  for.
* **`pkcs8` is not `i2d_PrivateKey`.** That emits the bare PKCS#1
  `RSAPrivateKey`; the format names the PKCS#8 `PrivateKeyInfo` wrapper, which
  is `EVP_PKEY2PKCS8` + `i2d_PKCS8_PRIV_KEY_INFO`.
* **The OAEP label has to be a libcrypto allocation.**
  `EVP_PKEY_CTX_set0_rsa_oaep_label` takes ownership of the buffer and frees it
  with `OPENSSL_free`, so an arena slice would have been freed twice.
* **`alg` in a JWK tracks the hash, not just the algorithm.** RSA-OAEP under
  SHA-256 is `RSA-OAEP-256`, the same pair under PSS is `PS256`, and SHA-1 is
  the unsuffixed form.
* **The hash for a signature comes from the key.** Neither `RSASSA-PKCS1-v1_5`
  nor `RSA-PSS` carries one in its call parameters; only PSS's `saltLength` is
  a call parameter.
* **A JWK may omit the CRT members.** A key carrying only `n`, `e` and `d` is
  legal, and `RSA_new_private_key_no_crt` is what takes it.

### Where it landed

`probe-g25` covers 31 rows. Against a headed Chrome 150: **31 of 31 agree on
the value and on the `DOMException` name** — the 294-byte SPKI opening
`MIIBIjANBgkqhkiG`, the JWK member set `alg,d,dp,dq,e,ext,key_ops,kty,n,p,q,qi`,
the 256-byte ciphertext that differs between two encryptions of the same
plaintext, the deterministic PKCS1 signature against the randomised PSS one,
and the six refusals (`InvalidAccessError` on exporting a private key as
`spki`, on a non-extractable export and on signing with a public key;
`OperationError` on a 500-byte OAEP plaintext; `DataError` on garbage SPKI;
`SyntaxError` on a bad usage list).

Six of those rows differ in the `DOMException` *message* only: ours are the
fixed per-code strings (`The object does not support the operation or
argument`), Chrome's are written per call site (`Failed to execute 'exportKey'
on 'SubtleCrypto': key is not extractable`). That is engine-wide rather than
anything about RSA — `DOMException.fromError` maps an error to a code and the
code owns the message — so it is left alone here.

Deliberately not in scope: EC and OKP keys still export no DER at all
(`exportKey('spki', ecPublicKey)` stays on the old `NotSupportedError` path —
only RSA was measured), and `SubtleCrypto` declares no `wrapKey` / `unwrapKey`
at all, for any algorithm, even though an RSA-OAEP pair splits those usages
across its halves correctly.

## G21: replaying the canonical audio render, per platform

G10 answered "can the audio fingerprint be computed?" with a firm **no** — the
oscillator's wavetable comes from 36 inverse FFTs backed by vDSP on macOS and
PFFFT everywhere else, and the compressor calls the platform's libm per sample,
so there is no "Chrome" answer to reproduce. G21 takes the other road: record
what real Chrome renders on each platform we claim to be, and replay it for the
one graph a detector actually builds.

### The recording (P1)

`tools/fingerprint/dump-audio-buffer.mjs` drives two Chromes and writes
`src/browser/webapi/audio/chrome_audio_{macos,linux}.bin` — 5000 little-endian
f32 each, the destination channel of the canonical graph. macOS comes from the
Chrome on this machine; Linux comes from the official amd64 package in a
container (`tools/fingerprint/linux-chrome.mjs`, reusable for any Linux
measurement).

Four things measured alongside the buffers, all of which the design leans on:

| measured | value |
|---|---|
| canonical tail sum, macOS/arm64 | `124.04347624466754` |
| canonical tail sum, Linux/x86_64 | `124.04347527516074` |
| Rosetta-emulated container vs a native x86-64 Xeon (avx512f) | byte-identical buffer |
| the same graph on Chrome 150 vs Chrome 151 | byte-identical buffer |

The container being trustworthy as a Linux baseline is established **for audio
only** — it is a CPU-bound render with no device behind it. It says nothing
about WebGL or speech, which G21's P4 measures separately.

Stored as raw bytes rather than Zig float literals on purpose: the tail sum a
detector hashes moves with one ULP, and a decimal round-trip through source text
is exactly where a ULP goes missing.

### The replay, and why it is fussy (P2)

`src/browser/webapi/audio/canonical_render.zig` fills the render buffer only
when the graph is the canonical one, and leaves it silent otherwise. Two
decisions shape that predicate.

**Exact on the signal, indifferent to the rest.** A detector that probes the
graph's *shape* instead of hashing one render is the obvious next move against
this trick, and a stored buffer handed back for a graph that would render
something else is a much louder tell than silence — every deviation measured
lands somewhere completely different (threshold -50 → -40 gives `141.40542197437026`,
44100 → 48000 Hz gives `122.60269225055163`). But "exact" has to mean the signal
reaching the destination, not the context containing nothing else: a gain node
hanging off the side changes nothing in Chrome, so refusing to replay for one
would invent a divergence rather than avoid one. So the match is on *incoming*
edges — exactly one node feeds the destination and it is the canonical
compressor, exactly one feeds the compressor and it is the canonical oscillator
— and everything else in the context is ignored, the way Chrome ignores it.
`BaseAudioContext._nodes` exists for this: `AudioNode._outputs` records only
forward edges, so there is no walking back from the destination without it.

**A longer render replays a prefix rather than falling back to silence.** Only
5000 frames were recorded — what fingerprintjs asks for — and a 44100-frame
render is frame-for-frame identical to a 5000-frame one over the frames they
share (measured, `first_diff = -1`). So a longer ask gets the recorded 5000
frames and zeros after. This is strictly closer to the truth than all-zero at
every frame a detector might read, and full silence over the canonical window is
itself a known signature (CreepJS's `hasFakeAudio()` reads it as blocked audio).

Gaps left open, all of them silence where Chrome renders something, all of them
deliberate rather than overlooked:

* **past frame 5000** — nothing recorded, see above.
* **a stereo destination** — only the mono render was recorded. Whether Chrome
  up-mixes it into identical channels was never measured, and a wrong guess
  costs more than the silence does.
* **a source that was stopped** — `stop()` records that it happened but not
  when, so a stop past the end of the render (which changes nothing in Chrome)
  cannot be told from one that truncates.
* **a graph that modulates an AudioParam** — param edges are not recorded at
  all, only counted (`BaseAudioContext._param_edges`), so a modulated graph
  declines rather than replaying a render that no longer applies.

### Can a container stand in for the Linux machine we claim to be? (P4)

Four of the recorded tables in `src/` were captured on this macOS machine, and
claiming Linux makes each of them a contradiction until it is re-recorded. The
container from P1 is the only Linux Chrome reachable from here, so the question
is which of those tables it can legitimately supply — and the answer is not the
same for all of them.

Measured with `probe-g21b.js` (in the probe workspace) on **three** browsers, not
two: `mac150-headless`, `mac151-headed` / `mac151-headless`, and
`linux151-headless` in the container. The third run is what makes the table
below possible — a plain mac-vs-Linux diff cannot tell a platform difference
from a Chrome 150 → 151 one, and it turns out several of the loudest differences
are the version.

> A trap worth knowing about: the first attempt at this measured a *stale*
> headless Chrome 150 left listening on the probe port by an earlier session,
> for both "mac" runs. `run-probe.mjs` now refuses to start when the port is
> already serving CDP instead of silently attaching to whatever answers.

| table | container usable as the Linux baseline? | what the measurement says |
|---|---|---|
| CSS property list (`css/chrome_properties.zig`) | **yes, entirely** | `mac151` and `linux151` agree on all 475 computed longhands and all 745 alias names, *including order*. Every difference from the checked-in table is the version, not the platform. |
| media MIME answers (`media/chrome_mimes.zig`) | **yes, except the HEVC rows** | 30 of 34 probed types identical. Linux answers `""/false/false` for `hvc1`/`hev1` where macOS says `probably/true/true`, and `MediaRecorder` refuses AAC-in-MP4 where macOS takes it. |
| WebRTC SDP + RTP capabilities (`webrtc/chrome_sdp.zig`) | **the scaffolding yes, the hardware codecs no** | Audio capabilities are identical. Video loses H264 High profile (`profile-level-id=64001f`, `640034`) and H265 entirely. |
| WebGL identity and limits (`canvas/WebGLRenderingContext.zig`) | **no** | The container renders through SwiftShader, which is the no-GPU signature detectors already look for. |
| speech voices (`speech/voices.zig`) | **no** | 19 voices, every one of them `localService: false`. |

The split is not per-table, it is per-*dependency*: the container is a faithful
Linux Chrome for anything that is pure software inside the browser build, and no
Linux machine at all for anything backed by a device.

**WebGL.** `unmasked_renderer` reads `ANGLE (Google, Vulkan 1.3.0 (SwiftShader
Device (Subzero) (0x0000C0DE)), SwiftShader driver)` against macOS's `ANGLE
(Apple, ANGLE Metal Renderer: Apple M4, Unspecified Version)`, and every numeric
limit that moved moved with it: `MAX_TEXTURE_SIZE` and `MAX_RENDERBUFFER_SIZE`
16384 → 8192, `MAX_VIEWPORT_DIMS` likewise, `ALIASED_POINT_SIZE_RANGE` [1,511] →
[1,1023], `MAX_VARYING_VECTORS` 30 → 31, four WebGL1 and eight WebGL2 extensions
gone (`OVR_multiview2` gained). Those are SwiftShader's numbers, not a Linux
GPU's, so taking them would trade a macOS-string contradiction for a
software-rasteriser one — the second is worse, because it is the exact string a
detector uses to decide it is talking to a headless browser. Getting this table
honestly needs a Linux box with a GPU; the container cannot provide it.

**Voices.** The suspicion going in was that the container would report an empty
list. It does not — it reports the 19 Google *network* voices, `localService:
false` on every one. That is worse than it sounds: what CreepJS renders as
"local (0): blocked" is a count of *local* voices, so nineteen remote ones read
the same as none. A real Linux desktop with speech-dispatcher installed would
report local voices beside them, and that is what this table would need.

**MIME and WebRTC, and the part that is inference.** That Linux Chrome ships no
HEVC decoder and no H264 High profile *in this container* is measured. Whether a
Linux desktop with VAAPI hardware decoding would answer differently is **not**
measured here — Chrome routes HEVC and H264 High through platform decoders, so it
plausibly would. Treat those specific rows as device-dependent like WebGL rather
than as settled Linux facts.

**A finding that outgrows P4.** The checked-in tables were all captured from
Chrome 150 and the reference Chrome is now 151, which is not a cosmetic gap: 151
adds the `ruby-overhang` longhand (474 → 475 computed) and rewrites a large part
of the offer SDP (`a=rtcp-xr:rcvr-rtt=all` plus an `a=rtcp-fb:<pt> rrtr` line per
payload type, and a renumbered video payload list). So bumping `chrome_major` to
151 cannot be done on its own — the CSS and SDP tables have to be re-recorded in
the same change, or the version the engine claims contradicts the tables beside
it.

### What got replaced, and what is still macOS (P5)

Re-recorded from the container (`CDP_ENDPOINT` now points any of the generators
at a Chrome it did not spawn, which is how a Linux table gets measured from a
macOS host at all):

| table | before | after |
|---|---|---|
| `css/chrome_properties.zig` | 474 computed / 735 aliases, Chrome 150 macOS | 475 / 736, Chrome 151 Linux |
| `media/chrome_mimes.zig` | 21 containers, Chrome 150 macOS | 21 containers, Chrome 151 Linux — HEVC gone, `MediaRecorder` no longer takes AAC-in-MP4 |
| `webrtc/chrome_sdp.zig` | 15 send / 23 receive video codecs, Chrome 150 macOS | 13 / 19, Chrome 151 Linux — no H264 High profile, no H265, video payload types renumbered, `rrtr` feedback and `a=rtcp-xr:rcvr-rtt=all` added by 151 |

The CSS numbers moving is the version, not the platform: `mac151` and
`linux151` agree exactly (P4), so this refresh would have been due anyway.

Nine assertions across four test files pinned the old counts and had to move
with the tables — `cs.length`, the last computed longhand's index, the alias
count, `computedStyleMap().size`, the video payload-type count, the H264 payload
number, the receive-codec count and the per-codec feedback set. They are the
tables' regression net, so each one moving is a table that changed, not a test
that was wrong.

**The other two tables, and the trade that was made deliberately.** WebGL and
the voice list had no honest option, only two dishonest ones: keep the macOS
values beside a Linux user-agent, or take the container's — SwiftShader and a
voice list with no local voices in it, both of which are signatures a detector
already looks for. The call was to take the container's, on the grounds that
those at least describe a machine that exists (a Linux server with no GPU and no
speech-dispatcher, which is what most headless deployments are), where the
macOS-values-on-Linux combination describes nothing at all and fails on the
first cross-check.

So both are now measured Linux values, and both carry a cost worth writing down
rather than forgetting:

* `canvas/WebGL*.zig` reports `Google Inc. (Google)` / `ANGLE (Google, Vulkan
  1.3.0 (SwiftShader Device (Subzero) (0x0000C0DE)), SwiftShader driver)` with
  SwiftShader's limits — `MAX_TEXTURE_SIZE` 8192, `MAX_VIEWPORT_DIMS`
  [8192, 8192], `ALIASED_POINT_SIZE_RANGE` [1, 1023], `MAX_DRAW_BUFFERS` 6 (so
  `DRAW_BUFFER6`/`DRAW_BUFFER7` answer null rather than a slot), 35 WebGL1 and
  29 WebGL2 extensions. **SwiftShader is a headless signal.** Replacing it needs
  a Linux box with a GPU, not a change of mind.
* `speech/voices.zig` lists the 19 Google network voices, `localService: false`
  on all of them — the 180 macOS system voices are gone and nothing local
  replaces them. **Zero local voices reads to CreepJS the same as an empty
  list.** Replacing it needs speech-dispatcher on that same box.

Not touched, and out of scope here: the font metric tables behind
`measureText` (G5) were also measured on macOS, and Linux ships entirely
different default families. That is a bigger surface than the five above and has
not been measured on Linux at all yet.

### The version bump, and what the probe caught (P6)

`chrome_major` is 151 and `chrome_full_version` is `151.0.7922.137` — the Linux
build's, because that is the platform being claimed and the build every table
above was recorded from. The bump is deliberately last: P4 established that 151
is not a cosmetic difference from 150 (a new CSS longhand, a rewritten offer
SDP), so the number could only move once the tables had.

Re-running the end-to-end probe against the rebuilt engine caught one thing the
test suite could not, because nothing pinned it: **the Sec-Ch-Ua brand list was
still Chrome 150's.** Not the versions — those track `chrome_major` — but the
GREASE entry and the order:

| | Chrome 150 | Chrome 151 |
|---|---|---|
| GREASE brand | `"Not;A=Brand";v="8"` | `"Not=A?Brand";v="99"` |
| order | Chromium, then Google Chrome | Google Chrome, then Chromium |

Both move between builds *by design* — GREASE exists so servers cannot hardcode
the list — which is exactly why neither survives a version bump and why a
150-era list beside a 151 user-agent is a mismatch rather than a harmless
default. Measured twice in separate container runs before being written down, so
it is this build's answer and not one roll of the die.

Final parity run, engine vs the Linux Chrome 151 in the container, same probe on
both (`probe-g21e.js`): **14 of 14 comparable rows identical** — user-agent,
`navigator.platform`, the brand list, `architecture`/`bitness`/`uaFullVersion`,
the WebGL renderer strings and limits, the extension counts (35 / 29), the
computed-property count (475), the canonical audio tail sum
(`124.04347527516074`, the Linux recording), the voice counts (19 / 0 local),
HEVC (`""`) and the video RTP codec count (13). The two rows not compared are
`navigator.userAgentData.platform` and the brand list, which are
`[SecureContext]` and so absent on the container's `about:blank`; both were
verified separately against `https://example.com` in the container, where Chrome
answers `Linux` and the same three brands.

## G21 re-sweep: all twelve detectors, and why the baseline itself is now wrong

The last full sweep was G11's. Six plans shipped after it — G12, G22, G23, G24,
G25, G21 — and none of them re-measured the detectors, so "the plans are done"
was not the same claim as "the engine got better". This run closes that.

Both engines, same day, matched 1920 viewport, route checked first (system
proxies off, default route a plain LAN gateway on `en0`, no `utun`). Chrome is
the headed 151.0.7922.138 on this machine; lightpanda is `dev.250+126f2dae3`.

| site | Chrome 151 | lightpanda | delta | G11 delta | moved |
|---|---|---|---|---|---|
| pixelscan | 1828 | 1828 | 0 | 0 | — |
| deviceinfo | 264 | 264 | 0 | 0 | — |
| rebrowser | 98 | 98 | 0 | +7 | **closed** |
| sannysoft | 290 | 291 | +1 | +1 | — |
| iphey | 487 | 490 | +3 | −2 | overshoots by 3 |
| amiunique | 1565 | 1560 | −5 | **−980** | **closed (G23)** |
| browserleaks-tls | 7 | 5 | −2 | −2 | — |
| browserscan | 2021 | 1870 | −151 | **−687** | mostly closed (G23+G25) |
| browserleaks-js | 1180 | 1004 | −176 | +4 | see below — not a regression |
| creepjs | 4066 | 3589 | −477 | −151 | see below — mostly the baseline |
| areyouheadless / fpscanner | 8 | 8 | 0 | 0 | host still 502 |

### browserleaks-js: −176 is the voice list, and the baseline is macOS

This looked like the worst news in the run — a row that was closed at G11 (+4)
reading −176. It is neither a regression nor a surprise once measured instead of
guessed. Per-`<tbody>` row counts are identical to Chrome's across all fifteen
tables (we are +1 on two of them, the same +4 as G11). The entire gap is `<br>`
elements: 28 against 208. All of it in one place:

| | `<br>` in `#speech-tbody` | voices |
|---|---|---|
| Chrome (macOS) | 198 | 199 |
| lightpanda | 18 | 19 |

browserleaks prints one voice per line, so 199 → 19 voices is exactly −180
nodes, and −180 + 4 is the −176 on the table. This is the cost of the Linux voice
table, priced: **one detector, 180 nodes, all of it one row.**

**The structural finding matters more than the number.** Every detector baseline
in `results/` is a *macOS* Chrome, and as of G21 the engine claims Linux. So any
platform-specific row now reads as a gap against a browser we are deliberately
no longer imitating — the voice list is simply the first one big enough to see.
Against the Linux Chrome in the container the same row matches (19 voices, same
names). Two consequences for whoever sweeps next:

* **Do not chase a platform-specific gap against the macOS baseline.** Check it
  against the container first; `run-linux-probe.mjs` in the probe workspace does
  this for a single surface, and `CDP_ENDPOINT` points any generator at it.
* **A container Chrome is not a full substitute either** (P4): it has no GPU and
  no speech-dispatcher, so it cannot be the reference for WebGL, hardware video
  codecs, or what a Linux *desktop* would list for voices. The honest reference
  for the whole sweep is a Linux box with a GPU, which is the same thing the two
  open gaps from P5 need.

### creepjs: −477, of which −18 is ours

Chrome moved from 3758 nodes to 4066 between the G11 sweep and this one — the
same browser upgrading 150 → 151, measured, not assumed. Over the same period
lightpanda went 3607 → 3589. So of the −477, **−308 is the baseline growing and
−18 is us**; the −151 in the G11 table was against a Chrome that no longer
exists. The −18 is small, unattributed, and not investigated here.

### Still open, and honestly unattributed

* **browserscan −151.** G23 attributed the then −178 as ~75–80 third-party ad
  and consent nodes plus the value cards blocked on RSA. RSA landed in G25, and
  the number moved to −151 — but the sections were not re-diffed, so which part
  of the −178 the +27 came out of is unknown.
* **iphey +3, sannysoft +1, browserleaks-tls −2.** Unchanged from G11 and never
  attributed.

## Switching the reference to a headed Linux Chrome

The G21 re-sweep ended on a structural complaint about itself: every baseline in
`results/` is a macOS Chrome, and the engine claims Linux, so any
platform-specific row reads as a gap against a browser we deliberately no longer
imitate. This replaces the reference.

`detectors-linux-chrome-headed.json` is the reference column from now on.
`detectors-g21-chrome-headed.json` and its older siblings stay as historical
macOS columns — useful for reading old sections, not for judging the engine.

### The reference has to be headed, which is why there is an X server in the image

`linux-chrome.mjs` now runs Chrome under `xvfb-run` instead of `--headless=new`.
Not neatness: several of these detectors treat headless differently on purpose,
so a headless Linux reference would trade the macOS-vs-Linux confound for a
headed-vs-headless one and the sweep would still be measuring two things at once.
`sweep-linux-baseline.mjs` refuses to run if the reference's user-agent says
`HeadlessChrome`, so that cannot regress quietly.

Two things this cost, both worth knowing before reusing the image:

* `xvfb-run` will not start without `xauth` — it exits with `xauth command not
  found` and the Chrome behind it never reaches CDP.
* the image tag is now a hash of the Dockerfile and `start.sh`. It used to be a
  fixed name checked with "does an image by this name exist", which makes editing
  the recipe a silent no-op: the switch to headed would have kept handing back the
  cached headless image and the sweep would have reported a headed baseline it
  never ran. Adding `xauth` produced a new tag immediately, which is the
  behaviour wanted.

### What the engine looks like against the browser it claims to be

Same lightpanda run (`dev.250+126f2dae3`), scored against both references:

| site | Linux Chrome 151 (new) | lightpanda | vs Linux | vs macOS |
|---|---|---|---|---|
| areyouheadless / fpscanner | 8 | 8 | 0 | 0 |
| rebrowser | 98 | 98 | 0 | 0 |
| deviceinfo | 264 | 264 | 0 | 0 |
| browserleaks-tls | 7 | 5 | −2 | −2 |
| sannysoft | 287 | 291 | +4 | +1 |
| iphey | 484 | 490 | +6 | +3 |
| browserleaks-js | 995 | 1004 | **+9** | −176 |
| pixelscan | 1838 | 1828 | −10 | 0 |
| amiunique | 1528 | 1560 | +32 | −5 |
| creepjs | 3546 | 3589 | **+43** | −477 |
| browserscan | 2032 | 1870 | **−162** | −151 |
| | | **total \|gap\|** | **268** | **815** |

**The two large gaps were the baseline, not the engine.** creepjs goes from −477
to +43 and browserleaks-js from −176 to +9 — the latter is the voice-list
artefact the G21 section priced at 180 nodes, now confirmed to have been an
artefact of comparing against macOS rather than a cost the engine pays. Against
the browser we claim to be, eleven of twelve sites are within a few dozen nodes.

Rows that read *worse* against the new reference are not regressions either; they
are the first honest measurement of surfaces where we overshoot a Linux Chrome —
amiunique +32, pixelscan −10, iphey +6, sannysoft +4. Small, and none of them
attributed yet.

**browserscan −162 is the one real remaining gap**, and it barely moved between
references (−151 macOS, −162 Linux), which is itself informative: whatever it is,
it is not platform-specific. G23 attributed the then −178 as ~75–80 third-party
ad and consent nodes plus value cards blocked on RSA; RSA landed in G25 and the
sections have not been re-diffed since.

### What this reference still is not

The container has no GPU and no speech daemon (measured, `## G21` P4). WebGL
reads SwiftShader and there are no local voices, so those rows agree with the
engine only because the engine took the container's values too — neither side is
standing in for a Linux desktop. That is the same machine the two open P5 gaps
need, and it is now also what a fully trustworthy baseline needs.

### browserscan's remainder, re-attributed against the Linux reference

The sweep reads −162; a separate structural run the same evening read −113. The
number moves run to run because most of it is advertising, which is the first
half of the answer. Structural dump of both engines at 1920, lightpanda
`dev.250+126f2dae3` against the headed Linux Chrome 151 in the container:

| block | lightpanda | Linux Chrome | note |
|---|---|---|---|
| `div.fc-ccpa-root` | absent | 20 | funding-choices consent root |
| `div.fc-dialog-container` | absent | 19 | its dialog |
| `div.google-auto-placed` | absent | 3 | AdSense |
| `ins.adsbygoogle` | 1 | 2 | AdSense |
| `div#aswift_0_host` | 0 | 1 | AdSense |
| body-level `<iframe>` | absent | 7 | ad frames |
| `main._v2yk82` | 844 | 898 | **the real content gap, −54** |
| `footer._1d8svxj` | 90 | 93 | −3 |

So roughly **half the gap is third-party** — consent dialog plus AdSense, ~50
nodes, carrying no detection signal — and the remaining **~54 nodes are inside
`main`**, where the largest tag deltas are `SPAN` −23 and `DIV` −39 (the DIV
figure spans both halves).

**G23's blocker is gone.** That section found every Hardware-card label rendered
with `<div class="skeleton">` where the value should be, because browserscan
could not import an RSA-OAEP key. Both engines now report **zero** skeleton
nodes, and lightpanda logs no exception on the page at all. G25's RSA family did
what it was scoped to do.

Two smaller observations from the same run, neither chased:

* The Linux Chrome logs two failed WebSocket attempts that lightpanda does not —
  `wss://localhost:22` (blocked as an unsafe port) and `wss://localhost:3389`
  (connection refused). browserscan port-scans localhost over WebSocket; we
  neither connect nor produce the same failures, which is a behavioural
  difference worth a look on its own.
* `div#c21op6sf` against `div#y5i9tfn7`: both engines render one two-node div
  under a randomised id, so that pair is the same thing named differently, not a
  difference.

**Next step for whoever picks this up:** diff inside `main._v2yk82` card by card.
The ~54 nodes there are the only part of browserscan still worth chasing; the
~50 third-party nodes are not, and should be excluded from the target rather than
counted against the engine.

## browserscan: the node count was the wrong question

The card-by-card diff got done, and it retired the target. Inside `main` the
gap is advertising too — AdSense and the consent dialog place nodes *within* the
content column, not only at body level, so splitting the page into "third-party
at body level" and "the real content gap inside main" split it in the wrong
place. Of the 49 nodes the reference renders and we do not, 44 are the consent
root, seven ad iframes and four AdSense blocks. The remainder is five nodes
across four leaves.

There is no meaningful structural gap on browserscan, and the headline figure
was never measuring one. `detector-sweep.mjs` will keep reporting somewhere
between −100 and −165 for this site, and that number is the ad server's mood.

**What the site actually says about us is a number it prints on the page**, and
`browserscan.mjs` reads it — the trust score, the warning list that itemises
each deduction, and every label/value row with the class browserscan puts on a
value it considers anomalous. Run it against both engines and diff:

```bash
node tools/fingerprint/browserscan.mjs        > results/browserscan-lightpanda.json
node tools/fingerprint/browserscan-linux.mjs  > results/browserscan-chrome-linux.json
node tools/fingerprint/browserscan.mjs --diff results/browserscan-lightpanda.json \
                                              results/browserscan-chrome-linux.json
```

### Read that way, we were losing 15 points to two things

| | lightpanda (before) | lightpanda (now) | Linux Chrome 151 |
|---|---|---|---|
| trust score | 85% | **95%** | 90% |
| deductions | Incognito mode −10%, WebGL exception −5% | WebGL exception −5% | Different time zones −10% |
| `main` nodes | 844 | 839 | 843 |

The reference's own −10% is the container, not Chrome: its clock is UTC while
the exit IP is in Los Angeles, so browserscan calls the timezone mismatched. On
a correctly configured machine the reference would read 100% and we would read
95%. We now score above the reference, which is not a win — it is the same
warning as ever that this container is not a trustworthy baseline.

**Incognito mode −10%, fixed.** The private-window probe every detector library
ships reads the temporary storage pool's quota and calls the browser incognito
when it comes back under twice `performance.memory.jsHeapSizeLimit`. Our three
quota surfaces answered three different numbers — 1 GiB from
`navigator.storage.estimate()`, 4 GiB from `webkitTemporaryStorage`, 0 from
`webkitPersistentStorage` — and the one the probe reads was small enough to trip
it. The reference answers the same 10 GiB from all three (measured), so all
three quote it now. `estimate()` also had to start resolving with a plain
dictionary: with the values on a prototype instead of own properties,
`JSON.stringify()` of the result gave `{}`, which is the same tell by another
route. Verified after: the row reads `No` and the warning is gone.

**WebGL exception −5% is the SwiftShader string, proven by isolation.** No
WebGL call throws — wrapping every method and getter on
`WebGL{,2}RenderingContext`, `CanvasRenderingContext2D` and `HTMLCanvasElement`
before the page loads caught zero throws across the whole run, so "exception" is
browserscan's label for a check that failed, not a real one. Swapping only the
two `WEBGL_debug_renderer_info` strings for a plausible desktop GPU and changing
nothing else removed the deduction (0 warnings, 100%); restoring them brought it
back (2/2 runs, `WebGL exception -5%`, both rows flagged). It is those strings.

**But do not swap them.** The same experiment showed why: with the GPU string in
place, fifteen further rows came back blank — visitor ID, Canvas, WebGL, Audio,
Client Rects, WebGPU, screen resolution, colour depth, touch support, device
memory, hardware concurrency. browserscan's whole hardware card stops computing,
and scores 100% because there is nothing left to score. A blank hardware card is
a far louder anomaly than a 5% deduction, and a 100% earned that way is the kind
of number this harness exists to distrust. (3/3 runs on the GPU string, 2/2 on
the control, so it is not rate limiting.) Why the card gives up was not chased.

That leaves the last deduction pointing where the `## G21` P5 gaps already
point: a Linux machine with a real GPU. Claiming one we do not have is not a
shortcut around it.

### Three unscored differences found along the way, none chased

* **Fonts: we detect zero.** *Fixed — see the next section.* browserscan listed
  13 fonts for the reference and `(0)` for us, hashing our empty list to
  `DA39A3EE`, the front of SHA-1("").
* **WebGPU.** We report a `WebGPU Report` hash where the reference reports `not
  support`. Overshooting a surface the browser we claim to be does not have.
* **`Available Screen Size` 1920×1040 against 1920×1080.** Ours is the more
  plausible of the two — a Linux desktop has a panel — but it is a difference
  against the reference and nobody has checked which value a real one gives.

## Zero fonts was not a font problem

The engine has real measured tables for seven families, and canvas font
enumeration already worked with them: probe `"Courier New", monospace` against
`monospace` through `measureText` and the width moves, probe a name we have no
table for and it does not. Six of eight candidates detected, the two fakes
correctly rejected — the same six the reference Linux Chrome finds.

The DOM route found nothing, because there was no DOM route. `offsetWidth` came
from `Element.getElementDimensions`, which answered a placeholder `5 × 5` for
any element without an explicit CSS width. Not five per character — five, flat,
for an empty span and for fifty-two characters alike, at every size and in every
family:

| | reference Chrome 151 | before | after |
|---|---|---|---|
| `offsetWidth` of 1 char at 72px | 43 | 5 | 43 |
| …13 chars | 562 | 5 | 564 |
| …52 chars | 2247 | 5 | 2254 |
| …13 chars at 8px | 62 | 5 | 63 |
| …at 200px | 1560 | 5 | 1565 |
| `offsetHeight` at 8 / 16 / 72px | 9 / 18 / 82 | 5 / 5 / 5 | 9 / 19 / 84 |
| base widths, mono / sans / serif | 562 / 648 / 620 | 5 / 5 / 5 | 564 / 648 / 620 |
| **fonts detected via the DOM** | **6** | **0** | **6** |

Every font-enumeration probe in the wild is that comparison, so a width that
ignores its contents makes all of them report an empty font list. That is what
browserscan was reading.

Width now comes from `text_measure` — the same tables and the same code path
`measureText` uses, so the two routes agree with each other and a fingerprint
that cross-checks them sees one browser. Height is the font's own box, ascent
plus descent. Both apply only to an element with no element children that does
hold text, and only when CSS gives no explicit dimension.

browserscan now lists **10 fonts** and hashes them to `8533CA74`, against the
reference's 13 and `6C722935`. Not the same set — the container's font
packages are not ours to match, and a font list that differed from every real
machine would be no worse than one that matched this particular container — but
a plausible list rather than the empty-string hash.

### What this is not

* **Not a layout engine.** There is no cascade to read: `getStyle` hands back
  the element's own inline declaration, so the font is resolved by walking to
  the nearest ancestor that names `font-size` or `font-family`. An element
  styled from a stylesheet still measures at the default 16px, and the `font`
  shorthand is not expanded — an element set with `font: 72px monospace`
  measures as 16px serif. Both were true before too; neither is now hidden.
* **Not Chrome's line box.** Chrome adds a line gap these tables do not carry —
  83 for 72px serif where ascent and descent sum to 80 — so heights run one to
  five pixels short.
* **Not applied to empty elements.** An element holding no text keeps the `5 × 5`
  placeholder where Chrome collapses it to `0 × 0`. The position and
  element-from-point machinery is built on that box; collapsing it is a change
  to those, not to text metrics.
* **Not measured on Linux.** The tables are still the macOS recording from
  `## G5`. They land within a few pixels of the container's Chrome, which is
  reassuring and not the same as being right — the sans-serif and serif base
  widths match it exactly, monospace is two pixels wide.

## The platform claim, before touching it

The engine claims Linux (`src/claimed_platform.zig`), while two of its measured
tables — `font_metrics.zig` and `emoji_metrics.zig` — were recorded from the
macOS Chrome on this machine. The question this experiment asks is whether
claiming macOS and recording *every* surface from that same Chrome reads as more
plausible than the split we have. Before changing anything, what the three
detectors that produce a readable verdict actually say:

| | lightpanda (claims Linux) | reference Chrome, Linux container | reference Chrome, macOS |
|---|---|---|---|
| browserscan score | **95%** | 90% | **100%** |
| browserscan warnings | `WebGL exception -5%` | timezone only | none |
| browserscan flagged rows | 2 (`Unmasked Vendor`, `Unmasked Renderer`) | — | **0** |
| browserscan rows read | 56 | — | 58 |
| browserscan `Fonts` | `8533CA74` (10) | `6C722935` (13) | `A6BE88C9` (342) |
| CreepJS like-headless | **38%** | 44% | **38%** |
| CreepJS headless / stealth | 0% / 0% | 0% / 0% | 0% / 0% |
| iphey headline | **no verdict at all** | no `Trustworthy` | `Trustworthy` |

Three things fall out of that column, and two of them cut against the
experiment's premise:

**CreepJS is already at the macOS Chrome number.** 38% like-headless, while
claiming Linux, on tables recorded from macOS — the same 38% the real macOS
Chrome scores, and better than the real Linux Chrome's 44%. Whatever CreepJS is
scoring, the platform claim is not an input to it. A macOS claim cannot improve
this row; it can only hold or break it.

**browserscan's whole remaining deduction is the renderer pair.** One warning,
`-5%`, and exactly two flagged rows: `Google Inc. (Google)` and the SwiftShader
`ANGLE (...)` string. Nothing else on the card is marked. So the ceiling here is
100%, the same as the macOS reference, and the only thing between us and it is
what `WEBGL_debug_renderer_info` answers — which is what M2 records.

**iphey reaches no verdict, and never did.** The card is not saying
`Unreliable`; it is not saying anything. All five sections — Browser, Location,
IP address, Hardware, Software — read `Temporary value`, iphey's placeholder,
after 20 seconds. `Your Digital Identity Looks` is followed by empty space.
Chrome in the Linux container does not print `Trustworthy` either, so the
absence is not evidence about the platform claim; it is a page whose fingerprint
pipeline does not finish. Two earlier attempts in the same session died
differently — a 3-node `about:blank` navigation, and a `Runtime.evaluate` that
blew past the 30s CDP cap while the page's own timers held the engine — so this
row needs retries before it can be read at all
(`macos-claim-before-iphey-lightpanda.json` records which attempt produced it).

The three readings live in
`results/macos-claim-before-{verdicts,browserscan,iphey}-lightpanda.json`, with
the two reference columns beside them as `macos-claim-ref-*`. CreepJS and iphey
were each read twice with identical hashes in the previous session, so these are
determinate readings rather than samples.

## The graphics face, re-recorded and split per platform

Re-running `dump-graphics.mjs --headed` against the Chrome on this machine
produced a file byte-identical to the July recording, so the macOS column is a
stable reading rather than a snapshot of one afternoon
(`results/macos-claim-graphics-chrome-macos.json` against
`results/reference-chrome-graphics.json`).

Against the Linux container's Chrome, 1176 leaves differ. 1125 of them are the
text section — the font metrics, which the engine already reports from the macOS
recording — leaving 51 that belong to the driver:

| | macOS (Apple M4, Metal) | Linux container (SwiftShader) |
|---|---|---|
| `UNMASKED_VENDOR_WEBGL` | `Google Inc. (Apple)` | `Google Inc. (Google)` |
| `UNMASKED_RENDERER_WEBGL` | `ANGLE (Apple, ANGLE Metal Renderer: Apple M4, …)` | `ANGLE (Google, Vulkan 1.3.0 (SwiftShader …))` |
| `MAX_TEXTURE_SIZE`, `MAX_RENDERBUFFER_SIZE`, `MAX_VIEWPORT_DIMS` | 16384 | 8192 |
| `MAX_VERTEX/FRAGMENT_UNIFORM_VECTORS` | 1024 | 4096 |
| `MAX_TEXTURE_IMAGE_UNITS` | 16 | 32 |
| `MAX_DRAW_BUFFERS`, `MAX_COLOR_ATTACHMENTS` | 8 | 6 |
| `MAX_ELEMENT_INDEX` | 4294967294 | 1073741823 |
| `UNIFORM_BUFFER_OFFSET_ALIGNMENT` | 16 | 256 |
| WebGL1 / WebGL2 extensions | 39 / 36 | 35 / 29 |
| lowp & mediump float | 127/127/23 | 15/15/10 |
| lowp & mediump int | 31/30/0 | 15/14/0 |
| `RGBA8` `SAMPLES` | `[4, 2]` | `[4]` |

All 51 now live in `src/browser/webapi/canvas/gpu.zig`, one table per claim,
selected by the same constant the user-agent and `navigator.platform` follow.
Both contexts read it, so the WebGL 1 and WebGL 2 answers for a shared name
cannot drift apart — and swapping the renderer string alone, which is what the
first attempt at this did and what emptied browserscan's whole hardware card, is
no longer expressible.

Writing the Linux column down found two values that were already the macOS ones
under a Linux claim, both invisible until the table had two columns to disagree
about:

* **Shader precision was folded.** `getShaderPrecisionFormat` answered one
  triple for lowp, mediump and highp alike — Metal's, which promotes everything
  to highp. SwiftShader reports 15/15/10 and 15/14/0 for the lower two, so a
  Linux-claiming engine was reporting an Apple GPU's precision behaviour.
* **`getInternalformatParameter` answered `[4, 2]`**, the two multisample counts
  Metal offers. SwiftShader offers only 4x.

Both are what the platform-keyed tests catch: the failing run before the change
was exactly those two assertions, and nothing else.

### What is still not per-platform

* **Extension objects.** A supported extension that exposes constants —
  `WEBGL_compressed_texture_s3tc`, `WEBGL_blend_func_extended` — hands back an
  empty object here, on both claims. That predates this work and is uniform
  across platforms, so it is a gap in the extension surface rather than in the
  platform claim.
* **The font metrics.** Still the macOS recording, on both claims (see
  `## Zero fonts was not a font problem`). That is M5's subject.

## Voices: 19 remote becomes 180 local plus 19 remote

`speechSynthesis.getVoices()` was the clearest case of the split claim. The table
in the tree was recorded from the Linux container — its own header said so — and
carried 19 voices, every one of them a remote Google voice with
`localService: false`, because a container with no speech-dispatcher has no local
voices to list. The line above that in the same file claimed it was "the macOS
system voice list", left over from before the switch to a Linux reference.

Re-recorded from the local Chrome with `--headed`:

| | Linux container | macOS reference host |
|---|---|---|
| voices | 19 | **199** |
| local (`localService: true`) | 0 | **180** |
| remote | 19 | 19 |
| distinct languages | 18 | **51** |
| default voice | `Google Deutsch` (remote) | `Samantha` (local) |

The order is the system's local voices first, then Chrome's remote block, and the
default is the first entry either way. Zero local voices is a documented tell —
CreepJS reads it much as it reads an empty list — so this is the one table where
the macOS recording is not merely more specific but strictly more plausible: no
real desktop has zero local voices.

## Fonts: from seven families to the set the reference Chrome reports

The font tables were seven hand-transcribed families. Against the 65 names
fingerprintjs2 shipped — still the list most probes use — that engine detected 6.
The macOS Chrome on the same host detects 26.

`dump-fonts.mjs` now measures every family the host has (`system_profiler -json
SPFontsDataType`, 250 of them) plus the CSS keywords and legacy names a probe
might ask for, and regenerates `src/browser/font_metrics.zig` from that. Its
output for the seven original families is byte-identical to the hand
transcription, which is what makes the other 167 trustworthy.

Getting the *set* right, rather than just making it bigger, took three
corrections, each of which was a measurement disagreeing with the obvious rule:

1. **Comparing a family against the fallback face cannot tell "absent" from
   "resolves to the default".** `100px "Times"` measures exactly like `100px
   serif` on macOS — because the default serif *is* Times. Read that way, Times
   is absent; a probe listing `"Times", monospace` sees it move and reads it as
   present. The test has to be the probe's: does putting the name ahead of a
   generic change that generic's measurement.
2. **One generic base is not enough.** Each generic is blind to the family it is
   itself resolved from: `"Times", serif` does not move, and `"Menlo", monospace`
   does not move. Real probes use three bases and take any movement as presence,
   so the recorder does too.
3. **Chrome falls back per glyph, and this engine cannot.** 52 of the 250
   families cover only part of U+0020..U+007E — every Hebrew, Arabic, Indic and
   symbol family, plus Apple Color Emoji. For those, Chrome mixes faces inside a
   single string: `100px "Arial Hebrew"` answers serif's width for `m` and Arial
   Hebrew's own for `$`, and `"Arial Hebrew", monospace` answers monospace's `m`
   with the same `$` — 58 of the 95 characters move with whatever follows in the
   list. An engine that picks one family per string cannot reproduce that, and
   keeping the family made it detect a font the real Chrome does not. They are
   dropped, so the list falls through to the next name, which is what Chrome
   effectively does for Latin text.

What lands: **174 faces and 30 aliases**, and on the fingerprintjs list the
engine now detects **exactly the 26 names the reference Chrome detects, in both
the canvas and the DOM route** — not 25, not 27. That equality is the test
(`src/browser/tests/element/text_metrics.html`), and the third correction above
is why: before it, the engine detected Arial Hebrew and Chrome did not.

| | before | after | reference Chrome |
|---|---|---|---|
| families with a table | 7 | 204 | — |
| detected, fingerprintjs2's 65 names | 6 | **26** | **26** |
| set matches the reference | no | **yes** | — |

### What this still is not

* **No per-glyph fallback.** A partial-coverage family is absent rather than
  mixed, so `100px "Arial Hebrew"` measures as serif throughout where Chrome uses
  Arial Hebrew's own `$`. The 52 dropped families are listed in
  `results/reference-chrome-fonts.json`.
* **Still ASCII only.** A probe that enumerates fonts with CJK text finds none of
  the CJK families, where Chrome finds them all.
* **A single machine's collection.** These are this Mac's fonts. Another Mac with
  Office installed reports a superset, and matching a *particular* Mac is not the
  same as being unremarkable among Macs.

## Was claiming macOS worth it? Three answers, not one

Everything above changed one platform claim and every table behind it. Measured
against the same three detectors the before column came from, and against the two
reference Chromes:

| | lightpanda, Linux claim | lightpanda, macOS claim | Chrome, macOS | Chrome, Linux |
|---|---|---|---|---|
| CreepJS like-headless | 38% | **31%** | 38% | 44% |
| CreepJS headless / stealth | 0% / 0% | 0% / 0% | 0% / 0% | 0% / 0% |
| iphey headline | no verdict | **no verdict** | `Trustworthy` | no `Trustworthy` |
| browserscan score | 95% | 100%\* | 100% | 90% |
| browserscan hardware card | complete | **never completes** | complete | complete |
| browserscan `OS` row | `Linux x86_64` | `Mac OS 26.3.1` | `Mac OS 26.3.1` | — |
| browserscan fonts | 10 | 135 | 342 | 13 |

\* The 100% is not a pass. Reading the page after 25s and again after 90s, 45
loading skeletons are still on it and every hardware row — visitor ID, Canvas,
WebGL, the renderer pair, Audio, Client Rects, WebGPU, touch, memory — is empty.
There was nothing left to deduct from. This is the same shape of false 100% the
earlier renderer-string experiment produced, and it is why a score is never read
without `skeletons` beside it.

**CreepJS: yes, and by more than the reference.** 38% → 31%, deterministic across
two runs (hash `da88474c`), and lower than either real Chrome — the macOS one
scores 38%, the Linux container 44%. Whatever CreepJS is adding up, the coherent
macOS surface subtracts from it.

**iphey: no change, and the claim was never the problem.** Still five cards
reading `Temporary value` and no headline verdict, exactly as under the Linux
claim. Its fingerprint pipeline does not finish in this engine, which is its own
bug and not a platform mismatch.

**browserscan: worse, and localised.** Three isolation runs, each a single change
on top of the finished branch:

| what was changed | card | score | warnings |
|---|---|---|---|
| nothing (macOS claim, macOS GPU table) | **blank**, 45 skeletons | 100%\* | none computed |
| `claimed` back to `.linux`, new font table kept | complete | 95% | `WebGL exception -5%` |
| macOS claim, whole GPU table forced to Linux | complete | 90% | `WebGL exception`, **`WebGL vendors vary`** |
| macOS claim, macOS limits, Linux renderer strings | complete | 90% | same two |

Two findings fall out, and they point in opposite directions:

1. **The Apple renderer strings alone hang the hardware card.** Not the limits,
   not the extension lists, not the fonts — the last row above keeps every macOS
   number and only puts the SwiftShader strings back, and the card completes.
   Blank 3/3 with the Apple strings, complete 2/2 without. No exception reaches
   `window.onerror`, `unhandledrejection` or `console.error` — the page's only
   errors are AdSense's and a rate-limited `ip-api.com` — so this reads as a
   promise that never settles rather than something that throws, which is also
   why waiting longer does not help.
2. **browserscan cross-checks the WebGL vendor against the claimed OS.** Claiming
   macOS while reporting SwiftShader earns a warning that did not exist before:
   *"Your WebGL vendor does not match your actual hardware information. You appear
   to be hiding actual hardware information."* −5%, on top of the existing
   `WebGL exception -5%`. So the SwiftShader strings are not a workaround under a
   macOS claim: reporting an Apple GPU is required, and reporting one is what
   hangs the card.

browserscan therefore cannot benefit from the macOS claim until (1) is found.
Until then the claim trades a real 95% for a hollow 100%.

### What the experiment settles, and what it does not

* Recording every surface from one machine is achievable and it was worth doing on
  its own terms: the split that had the engine claiming Linux while serving macOS
  font metrics, macOS shader precisions, macOS multisample counts and an Apple
  WebGPU adapter is gone, and three of those were only visible once the tables had
  two columns.
* The claim is one constant. Flipping it back is one line, and the suite passes
  on both settings, which is what the platform-keyed tests are for.
* Nothing here says macOS is the better claim *in general*. It is better on
  CreepJS, neutral on iphey, and currently worse on browserscan. A fourth
  detector could go either way.

## iphey did produce a verdict; the harness could not hear it

The row above reads `iphey headline: no verdict` under both platform claims, and
that was the premise this plan started from. Re-measured on the finished branch,
it is wrong twice over.

**The verdict is there, and it is Chrome's verdict.** Polling the page every two
seconds instead of reading it once:

| t | lightpanda | Chrome |
|---|---|---|
| 0–7s | 290–294 nodes, 5× `Temporary value` | 286–294 nodes, 5× `Temporary value` |
| 9s | 294 nodes, still `Temporary value` | **487 nodes, `Trustworthy`, 0 temporary** |
| 17s | **487 nodes, `Trustworthy`, 0 temporary** | same |
| 17–60s | unchanged | unchanged |

The terminal state is identical — 487 nodes, the headline reading `Trustworthy`,
not one card left on `Temporary value`. The engine takes 17s to Chrome's 9s, and
the five-`Temporary value` state every earlier reading captured is not a stall at
all: it is the state Chrome is also in for its first seven seconds.

**What actually failed was the probe harness, and it failed by not reading.**
`iphey-verdict.mjs` spawns the engine with `stdio: ['ignore', 'pipe', 'pipe']`
and never reads either pipe. Isolated in both directions on the same script,
same settings, same 20s settle:

| child stdout/stderr | outcome |
|---|---|
| drained (`proc.stdout.resume()`) | `Trustworthy`, 7 runs of 7, evaluate answers in 106–405ms |
| left undrained | `timeout: Runtime.evaluate`, 2 of 2, past a 45s cap |

A 64KB pipe fills, the engine blocks in `write`, its single-threaded loop stops,
and CDP goes unanswered. Every reading taken through an undrained harness was a
reading of a wedged engine, not of iphey. Audited across every harness that
spawns a browser, `iphey-verdict.mjs` was the only one that left the engine's
pipes unread — `verdicts-lightpanda.mjs`, the seven-station regression harness,
drains both with `.on('data')`, so its numbers are not affected. Two more
harnesses gave *Chrome* an unread pipe (`dump-graphics.mjs`, `dump-fonts.mjs`);
Chrome writes little enough that nothing was observed, and they now spawn with
`stdio: 'ignore'` rather than a pipe nobody reads.

**And the engine hands the harness a loaded gun.** One iphey load writes 415,852
bytes to stderr at default verbosity. Broken down:

| bytes | share | what |
|---|---|---|
| 391,861 | 94% | **a single line**: `log.info(.http, "request complete", …)` at `Fetch.zig:230` printing a `data:application/wasm;base64,…` URL in full |
| 18,560 | 4% | one page `console.table` call, serialized row by row (iphey's devtools probe, 500 entries) |
| 5,431 | 1% | everything else — normal request and script lines |

That one 383KB line is six times the pipe capacity by itself, it lands at
+8051ms, and it is why the page freezes at the 294-node mark. Its content is
page-controlled and unbounded: a `data:` URL is whatever the page inlined.
`writeString` in `src/log.zig` is the single funnel every logged string passes
through in both formats, so that is where a cap belongs — not at one log site.

### What was changed, and what it measures at now

`writeString` in `src/log.zig` caps a logged string at `max_string_len` (2048)
and appends `...+N bytes`, so the reader can tell a value that ends there from
one that was cut. Truncated values are quoted in `logfmt` even where an
untruncated one would not be, because the marker contains a space.

Measured on the same iphey load, before and after:

| | before | after |
|---|---|---|
| stderr for one load | 415,852 bytes | **26,067 bytes** |
| longest single line | 391,861 bytes | **2,076 bytes** |
| undrained harness | `timeout: Runtime.evaluate`, 2/2 | **`Trustworthy`, 2/2** |
| verdict, drained | `Trustworthy`, 487 nodes | unchanged |

The cap is not a substitute for draining. 26KB is under one pipe's capacity for
this page, not for a page that logs thousands of short lines, and the harness
that does not read is still the harness that wedges. Both ends were fixed.

### The regression check the cap needed

A log cap cannot change what a detector concludes, but it is one line away from
every log site, so it was checked against the binary it was built from — both
harnesses run the same day, same machine, same site list:

| station | main `97104bfbb` | this branch |
|---|---|---|
| sannysoft | | identical |
| creepjs | `31% like headless:da88474c`, `0% headless`, `0% stealth` | identical |
| iphey | `Bot Check / Not detected / BOT` | identical |
| pixelscan | | identical |
| rebrowser | 5 rows, all 🟢 | same rows, all 🟢 — only the milliseconds each row prints differ (`2.9 ms` / `3 ms`), byte-identical once those are stripped |
| areyouheadless | | identical |
| deviceinfo | | identical |

browserscan re-read alongside it: 100%, `skeletons=0`, no warnings, 0 of 58 rows
flagged, no empty values — unchanged. And the canonical iphey probe, the one that
timed out 2 of 2 before, now answers on its first attempt: 487 nodes,
`Trustworthy`, zero `Temporary value`, all five cards present.

Read the engine's own log volume before trusting any harness reading: `wc -c` on
the captured stderr is the cheap version of this whole section.

## The twelve detectors, re-read because every before column had rotted

The iphey section above is the reason for this one. A before snapshot asserted a
stall on a page that reaches a verdict, and it survived two handoffs because
nothing re-read it. Every `results/detectors-*.json` predates the plans since,
so the whole sweep was re-run rather than trusted:
`results/rebaseline-2026-08-19-lightpanda.json` (engine `1.0.0-dev.281+91216a567`)
and `results/rebaseline-2026-08-19-chrome.json` (headed `Chrome/151.0.7922.138`),
same machine, same day, same 1920×1080 window.

| detector | engine nodes | Chrome nodes | Δ | reads as |
|---|---|---|---|---|
| sannysoft | 291 | 290 | +1 | every row `passed` in both |
| creepjs | 3598 | 4066 | −468 | both render a fingerprint; text differs widely |
| areyouheadless | 8 | 8 | 0 | `502 Bad Gateway` in both — still dead |
| fpscanner | 8 | 8 | 0 | `502 Bad Gateway` in both — still dead |
| rebrowser | 98 | 98 | 0 | same rows, all green in both |
| deviceinfo | 264 | 264 | 0 | **`You are human!` in both** |
| browserleaks-js | 1183 | 1180 | +3 | same page |
| browserleaks-tls | 5 | 7 | −2 | **same JA4**: `t13d1516h2_8daaf6152771_806a8c22fdea` |
| amiunique | 1571 | 1551 | +20 | same page |
| iphey | 487 | 487 | 0 | **`Trustworthy` in both** |
| pixelscan | 1783 | 1783 | 0 | same page |
| browserscan | 1871 | 2055 | −184 | 100%, zero skeletons (read separately) |

Against the newest prior sweep (`detectors-g21-lightpanda.json`, engine
`1.0.0-dev.250`, 31 commits back), six sites moved: browserleaks-js +179,
amiunique +11, creepjs +9, browserscan +1, iphey −3, pixelscan −45.

**iphey read 490 nodes at g21, before the plan that reported it had no verdict.**
The drained harness had it right the whole time; only the undrained one said
otherwise. That is the same fault the iphey section isolated, seen from the other
side, and it is the argument for re-reading a baseline rather than citing one.

### What the re-read found that the node counts hide

**`text-transform` is computed but never applied to text.** Isolated on
`about:blank` in both engines:

| | engine | Chrome |
|---|---|---|
| `innerText` of a `text-transform: uppercase` div | `my fingerprint` | `MY FINGERPRINT` |
| `innerText` of a `text-transform: capitalize` div | `my fingerprint` | `My Fingerprint` |
| `textContent` | `my fingerprint` | `my fingerprint` |
| `getComputedStyle(...).textTransform` | `uppercase` | `uppercase` |

The property parses and computes correctly; layout just does not honour it, and
`innerText` is defined in terms of layout. One cause explains three of the text
differences in the sweep — iphey's `Browser` against Chrome's `BROWSER`,
amiunique's `My Fingerprint` against `MY FINGERPRINT`, pixelscan's `Checkers`
against `CHECKERS`. Any detector that reads `innerText` off an
uppercase-styled element sees a different string from us than from Chrome. Not
fixed here; recorded.

**Unattributed, found alongside it.** iphey's headline is `LooksTrustworthy` in
our `innerText` and `Looks Trustworthy` in Chrome's — a missing space at an
element boundary, not a text-transform issue, and not chased.

**Two things this sweep settles.** `areyouheadless` and `fpscanner` are still
502s and measure nothing in any browser, so nine live detectors is the real
count. And the TLS fingerprint matches Chrome's JA4 exactly, which is the one
row in the table no amount of JavaScript work could have produced.

### text-transform applied: what the three sites read now

Re-swept against the same recorded Chrome column
(`results/text-transform-after-lightpanda.json`):

| site | before | after | Chrome |
|---|---|---|---|
| amiunique | `My Fingerprint My Extension Global Statistics Survey Blog Useful Links Language` | **`MY FINGERPRINT MY EXTENSION GLOBAL STATISTICS SURVEY BLOG USEFUL LINKS LANGUAGE`** | identical to after |
| pixelscan | `… Verify your browser fingerprint Checkers IP Address Check` | **`… Verify your browser fingerprint CHECKERS IP Address Check`** | identical to after |
| iphey cards | `Learn more Browser Chrome Location United States` | **`Learn more BROWSER Chrome LOCATION United States`** | identical to after |

Node counts held everywhere: sannysoft 291, rebrowser 98, deviceinfo 264,
browserleaks-js 1183, browserleaks-tls 5, amiunique 1571, iphey 487, pixelscan
1783, browserscan 1871 — unchanged. browserscan re-read alongside: 100%,
`skeletons=0`, no warnings, 0 of 58 rows flagged, no empty values.

creepjs moved 3598 → 3600. It has now read 3589 (g21), 3598 and 3600 across
three runs of its own, so two nodes is inside its own variance rather than an
attributable change; noted, not claimed either way.

**Still open, and not this plan's:** iphey's headline is `LooksTrustworthy` in
our `innerText` against Chrome's `Looks Trustworthy`. That is a missing space at
an element boundary, unaffected by casing, and it survived this fix exactly as
predicted when it was recorded above.

## LooksTrustworthy was two bugs, and the smaller framing was mine

The section above left iphey's headline open and called it "a missing space at an
element boundary". Read against Chrome rather than against a normalised diff,
that description was wrong in one respect and right in another.

The markup, identical in both engines:

```html
<h1> Your Digital Identity Looks <span class="hero-status-slot"> <span class="hero-status">Trustworthy</span> </span> </h1>
```

Raw `innerText`, measured on the element itself rather than through the sweep's
whitespace-normalised snippet:

| | before | Chrome |
|---|---|---|
| iphey headline | `Your Digital Identity LooksTrustworthy` | `Your Digital Identity Looks \nTrustworthy` |

**Chrome puts a line break there, not a space.** `hero-status-slot` computes to
`display: inline-flex` in Chrome, and `innerText` breaks for a non-inline
display. The earlier note read it as a space because the sweep comparison ran
`\s+ → " "` first, which turns Chrome's `\n` into exactly the space it was
looking for. That is the hazard of diffing normalised text: the normalisation
answers the question.

Isolated on `about:blank`, one case per row, Chrome 151 against the engine:

| markup | Chrome | before | after |
|---|---|---|---|
| `a <span> <span>b</span> </span>` | `a b` | **`ab`** | `a b` |
| `a <span> </span><span> </span>b` | `a b` | **`ab`** | `a b` |
| `a<span> <span>b</span> </span>` | `a b` | `a b` | `a b` |
| `a <span style="display:inline-block"> <span>b</span> </span>` | `a b` | **`ab`** | `a b` |
| `a <span style="display:inline-flex"> <span>b</span> </span>` | **`a \nb`** | `ab` | `a b` |

So there were two independent faults, and the row that already passed is what
separates them: with nothing pending after `a`, the whitespace-only node
correctly produced the space. The bug was that a space *already* pending got
cleared by the next whitespace-only node —
`state.pre_w = state.wrote_any and state.trim_left == false` in `writeText`,
which discards a pending space instead of leaving it pending. A run of
collapsible whitespace collapses to one space, so the node should take nothing
away. Fixed; four of the five rows now match Chrome exactly.

**What is still open, and is a bigger change than this plan.** `inline-flex`
should break the line. We cannot honour it yet because `StyleManager` carries
`display` only as a `display_none` boolean, not as a value — which is also why
the engine reported `display: inline` for that span on iphey while reading
`inline-flex` back correctly from an inline style in the table above. Teaching
the cascade to carry computed `display` is the prerequisite, and it is not
attempted here. iphey's headline therefore reads `Looks Trustworthy` against
Chrome's `Looks \nTrustworthy`: the words separate correctly now, and the
separator is a space where Chrome has a break.

Node counts across the sweep held (creepjs 3600 → 3602, inside the variance it
has shown across four runs of its own: 3589, 3598, 3600, 3602). iphey's
`verdictWords` went 4 → 5, matching Chrome's 5, because `Trustworthy` finally
separates as its own word. browserscan: 100%, `skeletons=0`, no warnings, 0 of 58
flagged.

## Where iphey's line break actually comes from (D1)

The section above guessed that `inline-flex` breaks the line. Measured across
seventeen `display` values on Chrome 151, it does not — and the correction
matters, because the rule that does hold is both simpler and deeper.

`a<span style="display:VALUE">M</span>b`, one row per value:

| breaks (`a\nM\nb`) | does not break (`aMb`) |
|---|---|
| `block`, `flex`, `grid`, `list-item`, `table`, `flow-root` | `inline`, `inline-block`, **`inline-flex`**, `inline-grid`, `inline-table`, `table-cell`, `table-row`, `contents`, `ruby` |

`display: none` drops the subtree (`ab`). So innerText breaks for exactly a
block-level outer display, which is what the spec says and what our tag-based
`innerTextDisplay` already approximates.

**The break in iphey's headline is blockification, not the container.** A flex or
grid container turns its child *elements* into block boxes, and Chrome reports
that through `getComputedStyle` verbatim:

| markup | Chrome innerText | inner span's computed display |
|---|---|---|
| `a<span style="display:inline-flex">M</span>b` | `aMb` | — (bare text, no element) |
| `a<span style="display:inline-flex"><span>M</span></span>b` | `a\nM\nb` | **`block`** |
| `a<span style="display:flex"><span>M</span></span>b` | `a\nM\nb` | **`block`** |
| `a<span style="display:inline-grid"><span>M</span></span>b` | `a\nM\nb` | **`block`** |
| `a<span style="display:inline-block"><span>M</span></span>b` | `aMb` | `inline` |
| `a<span><span>M</span></span>b` | `aMb` | `inline` |
| `a<span style="display:inline-flex"><span>M</span><span>N</span></span>b` | `a\nM\nN\nb` | `block` |
| `Looks <span style="display:inline-flex"> <span>Trustworthy</span> </span>` | **`Looks \nTrustworthy`** | **`block`** |

The last row is iphey's headline reproduced on `about:blank`. The bare-text row
is what rules the container out: `M` gets an anonymous flex item, which has no
node for innerText to walk, so there is no break. Only a real child element is
blockified, and only that produces the break.

Three things followed, in order, and all three are done now (D2–D4):

1. `StyleManager` carries the cascaded `display` **value** alongside the
   `display_none` boolean, both filled from the same declaration so the
   hidden-element path keeps its exact semantics.
2. `getComputedStyle().display` reads that cascade. It used to read only the
   inline `style=` attribute and otherwise fall back to a tag-based UA default
   (`getDefaultDisplay` in CSSStyleDeclaration.zig), which is why the engine
   reported `inline` for iphey's slot span while reading `inline-flex` back
   correctly from an inline style.
3. `resolvedDisplay` blockifies a child element of a flex/grid container, and
   `innerTextDisplay` consults the same value.

## What the computed-display plan closed (D5)

Everything below was measured the same day on the same machine, engine build
`1.0.0-dev.296+51515ac1a` against main `1.0.0-dev.292+a9cf2dd02`, Chrome 151.

**iphey's headline, read raw rather than normalised.** The site's own `<h1>`:

| | `innerText` |
|---|---|
| main | `"Your Digital Identity Looks Trustworthy"` |
| this plan | `"Your Digital Identity Looks \nTrustworthy"` |
| Chrome 151 | `"Your Digital Identity Looks \nTrustworthy"` |

Byte-identical to Chrome. Note that the sweep's `snippet` field collapses
whitespace and shows all three as the same string — the newline is only visible
in the raw value, which is the whole reason D1 misdiagnosed this once already.

**Four `innerText` probes, 62 cases, diff clean against Chrome.** `d4-cases`
(display keyword → break, both directions, plus blockification), `d4-space`
(whitespace at an atomic inline boundary), `d4-space2` (which parents blockify),
`d4-space3` (empty and whitespace-only boxes). Every one is byte-identical.

**Twelve detectors, no regression.** Node counts flat on eleven; creepjs went
3598 → 3600, inside the 3589–3602 band it has shown across five runs of its own.
`verdictWords` is unchanged on all twelve and matches Chrome on eleven —
deviceinfo's 25 vs 28 is the one standing gap, and it did not move.

**browserscan: 100%, `skeletons=0`**, no problems, no warnings, 0 of 58 rows
flagged (`BROWSERSCAN_SETTLE_MS=30000`).

One thing measured and deliberately left alone: `checkVisibility()` returns
`true` for a `display: contents` element where Chrome returns `false`. It reads
the same on main, so it is a standing gap in `isElementHidden`, not something
this plan introduced — and it is a visibility question, not a display one.

### The blockification map, measured

`blockify` in StyleManager.zig, from `d3-blockify` (sixteen child values under
each of seven parent types, plus the table- and ruby-internal values):

| child declares | inside flex / inline-flex / grid / inline-grid |
|---|---|
| `inline`, `inline-block`, `table-cell`, `table-row`, every `table-*-group`, `table-column*`, `table-caption`, `ruby-text`, `ruby-base` | `block` |
| `inline-flex` | `flex` |
| `inline-grid` | `grid` |
| `inline-table` | `table` |
| `ruby` | `block ruby` |
| `block`, `flex`, `grid`, `table`, `list-item`, `flow-root` | unchanged |
| `contents`, `none` | unchanged (they generate no box) |

No other parent blockifies: `block`, `inline-block` and `table` parents leave
every child's display exactly as declared, and only a direct child is an item —
a grandchild of a flex container reads `inline`.

### Two measurements that would have been wrong to guess

**`<p>`'s blank line is a margin, not a display.** `a<p style="display:inline">M</p>b`
reads `"a\n\nM\n\nb"` in Chrome — the two breaks survive an inline display. So
`innerTextDisplay` returns the `<p>` case before consulting the cascade at all.
Every other block-level tag does follow its display: `a<div style="display:inline">M</div>b`
reads `"aMb"`, and so does the `<li>` form.

**An atomic inline box does not collapse the whitespace around it.** A block
boundary trims the space on either side of it; a break that merely escaped an
inline-block / inline-flex / inline-grid / inline-table box does not:

| markup | Chrome |
|---|---|
| `a <span style="display:block">M</span> b` | `"a\nM\nb"` |
| `a <span><span style="display:block">M</span></span> b` | `"a\nM\nb"` |
| `a <span style="display:inline-flex"><span>M</span></span> b` | `"a \nM\n b"` |
| `a <span style="display:inline-block"></span> b` | `"a  b"` |
| `a <span style="display:inline-block"> x</span> b` | `"a x b"` |

The empty-box row is the decisive one: Chrome reads **two** spaces, so the box
is content in the outer run rather than a boundary. That is what `InnerTextState`'s
`breaks_inside_atomic` encodes, and it is why iphey reads `"Looks \nTrustworthy"`
with the space kept rather than `"Looks\nTrustworthy"`.

## display:contents generates no box (checkvisibility-contents plan)

The computed-display plan measured this and left it alone as out of its scope:
`checkVisibility()` read `true` for a `display: contents` element where Chrome
reads `false`. Measured on Chrome 151 (probe `v1-contents`), the element itself
has no box at all, while everything under it still renders:

| probe | `display` | `checkVisibility()` | `getClientRects().length` | host `innerText` |
|---|---|---|---|---|
| `<div style="display:contents">M</div>` | `contents` | **`false`** | 0 | `"M"` |
| the same set from a stylesheet rule | `contents` | `false` | 0 | `"M"` |
| nested inside another contents | `contents` | `false` | 0 | `"M"` |
| **its child** | `block` | **`true`** | 1 | `"M"` |
| `<div>M</div>` (control) | `block` | `true` | 1 | `"M"` |
| `<div style="display:none">M</div>` (control) | `none` | `false` | 0 | `""` |

The child row is the one that shapes the fix: the no-box verdict belongs to that
one element and must not reach its subtree. So it is checked ahead of `isHidden`'s
ancestor walk and deliberately kept out of the visibility cache, where a cached
`hidden = true` would be read back by every descendant's own walk.

It is also opt-in (`boxless_hidden`), not a change to `isElementHidden` itself.
Three callers must keep the old answer: the accessibility tree prunes on
`isHidden` and would drop the whole subtree, `innerText` walks through a contents
element by way of `hasDisplayNone`, and `getComputedStyle().display` has to go on
reporting `contents`.

All ten contents probes now read identically to Chrome. Twelve detectors: node
counts identical on all twelve, `verdictWords` unchanged on all twelve.
browserscan 100%, `skeletons=0`, 0 of 58 flagged.

Still open, and a different property: `innerText` includes text under
`visibility: hidden` where Chrome excludes it (`<div style="visibility:hidden">M</div>`
reads `"M"` here and `""` there). That is a visibility question, not a display
one, and it reads the same on main.

## innerText and `visibility` (W1)

The section above left this open: `innerText` includes text under
`visibility: hidden` where Chrome excludes it. Measured on Chrome 151 (probes
`w1-visibility` and `w1b-visibility`, 32 cases on about:blank). The rule is not
"skip the subtree" — `visibility` inherits and a descendant can turn it back on.

**Text is emitted only when its nearest element ancestor computes to `visible`.**

| markup | Chrome |
|---|---|
| `a<span style="visibility:hidden">M</span>b` | `"ab"` |
| `a<span style="visibility:collapse">M</span>b` | `"ab"` |
| `a<span style="visibility:hidden"><span>M</span></span>b` | `"ab"` |
| `a<span style="visibility:hidden"><span style="visibility:visible">M</span></span>b` | `"aMb"` |
| `a<span style="visibility:hidden"><span style="visibility:visible"><span>M</span></span></span>b` | `"aMb"` |
| …and the same nested once more back to hidden | `"ab"` |
| `a<span style="opacity:0">M</span>b` | `"aMb"` — opacity is not visibility |
| `el.innerText` where `el` itself is hidden | `""` |
| the same with a `visibility:visible` child | `"M"` |

**A hidden block box emits no line break, but a visible one does even when empty.**
This is the part that does not fall out of the engine's lazy `pending_breaks`
for free: today a hidden block still arms `requireBreaks`, and the next visible
text flushes it.

| markup | Chrome |
|---|---|
| `a<div></div>b` | `"a\nb"` — empty *visible* block still breaks |
| `a<div> </div>b` | `"a\nb"` |
| `a<div style="visibility:hidden">M</div>b` | `"ab"` — no break at all |
| `a<div style="visibility:hidden"></div>b` | `"ab"` |
| `a<p style="visibility:hidden">M</p>b` | `"ab"` — no blank line either |
| `a<div style="visibility:hidden"><br></div>b` | `"ab"` — a hidden `<br>` is silent |
| `a<span style="visibility:hidden"><div>M</div></span>b` | `"ab"` |
| `a<div>M</div><div style="visibility:hidden">N</div><div>P</div>b` | `"a\nM\nP\nb"` |
| `a<div style="visibility:hidden">M</div>N<div>P</div>b` | `"aN\nP\nb"` |
| `a<div style="visibility:hidden"><div style="visibility:visible">M</div></div>b` | `"a\nM\nb"` |
| `a<div style="visibility:hidden"><span style="visibility:visible">M</span></div>b` | `"aMb"` |

The last two rows together are the shape of it: the *outer* hidden block never
contributes a break, and whether one appears depends only on whether the visible
content inside is itself block-level.

**Whitespace: a hidden inline keeps the spaces on both sides; a hidden block
still trims them.** The inline row looks like the two-space reading the atomic
inline boxes gave, but the cause turned out to be different — see the W2
boundary probe below, where an *empty* hidden inline merges the two spaces and an
empty inline-block does not. It is the zero-width text run that separates them,
not the box.

| markup | Chrome |
|---|---|
| `a <span style="visibility:hidden">M</span> b` | `"a  b"` — **two** spaces |
| `a <span style="visibility:hidden">M</span>b` | `"a b"` |
| `a <span style="visibility:hidden">M</span> <span>N</span> b` | `"a  N b"` |
| `a <div style="visibility:hidden">M</div> b` | `"ab"` — block boundary still trims |
| `a <div style="display:none">M</div> b` | `"a b"` — display:none is absent, so the two collapsible spaces merge into one |

That last contrast is the control worth keeping: `display: none` and
`visibility: hidden` differ in the whitespace they leave behind, so the fix
cannot route one through the other.

### The boundary of the rule (W2)

W1's three tables are the rule; these are the edges that decide how it has to be
implemented. Measured on Chrome 151 the same way (probe `w2-boundary`, 22 cases).

| markup | Chrome |
|---|---|
| `a <span style="visibility:hidden">M</span> b` | `"a  b"` — two spaces |
| `a <span style="visibility:hidden"></span> b` | `"a b"` — **one**: an empty hidden inline merges them |
| `a <span style="visibility:hidden"> </span> b` | `"a b"` |
| `a <span style="display:inline-block"></span> b` | `"a  b"` — an empty *atomic* box still keeps both |
| `a <span style="visibility:hidden;display:contents">M</span> b` | `"a  b"` — no box at all, still two |

So what separates the two collapsible spaces is the hidden **text run**, which is
zero-width but still a run in the inline flow — not the element's box. That is
the opposite of the atomic inline boxes, where the box itself is the content, and
it is why `display: contents` (no box) still reads two spaces while an empty
hidden `<span>` (a box, no run) reads one.

| markup | Chrome |
|---|---|
| `a <span style="visibility:hidden"><div style="visibility:visible">M</div></span> b` | `"a\nM\nb"` — the visible block's boundary trims what the run would have kept |
| `a <span style="visibility:hidden;display:inline-block">M</span> b` | `"a  b"` |
| `a<table><tr><td>M</td><td style="visibility:hidden">N</td><td>P</td></tr></table>b` | `"a\nM\tP\nb"` — **one** tab |
| `a<table><tr><td>M</td></tr><tr style="visibility:hidden"><td>N</td></tr><tr><td>P</td></tr></table>b` | `"a\nM\nP\nb"` |
| `a<pre style="visibility:hidden">M  N</pre>b` | `"ab"` |
| `a<pre style="visibility:hidden"><span style="visibility:visible">M  N</span></pre>b` | `"aM  Nb"` |
| `.vh{visibility:hidden}` + `a<span class=vh style="visibility:visible">M</span>b` | `"aMb"` — the style attribute outranks the rule |
| `.vh{visibility:hidden!important}` + the same | `"ab"` — unless the rule is `!important` |

A hidden cell or row contributes no separator and does not count as one for its
next sibling, which is the table analogue of the missing line break.

### What it changed on the twelve stations (W3)

`innerText` was reading text no browser renders, and on one station by a factor
of eighteen. Before / after / Chrome 151, one sweep each (`detector-sweep.mjs`):

| site | textLength before | after | Chrome | verdictWords before → after (Chrome) |
|---|---|---|---|---|
| creepjs | 87514 | **4133** | 4742 | 2 → 2 (2) |
| deviceinfo | 6192 | **5859** | 5861 | 25 → **28** (28) |
| amiunique | 6439 | **6325** | 6360 | 1 → 1 (1) |

The other nine stations read identically before and after. Every station that
moved, moved toward Chrome; none moved away. deviceinfo's verdict-word count now
matches Chrome exactly, where before the hidden navigation text it was reading
put it three short. browserscan still scores 100% with no warnings and 0 loading
skeletons (`mainTotal` 845, `docTotal` 1871 — unchanged).

Ancillary, and followed up in the section below: replacing the text of a `<style>`
element already in the document did not re-cascade, where the same rule text in a
freshly created one did. The condition turned out to be narrower than that first
note said, and the note was wrong about there being no re-parse at all.

## `<style>` text mutations, and `!important` against the style attribute

Two cascade gaps, found while writing the `!important` case in the section above
and measured the same way (Chrome 151, probes `t1c`, `t2-matrix`, `t4-important`).

### Rewriting a mounted `<style>`'s text (T1/T2)

The first note above said mutating `textContent` never re-cascades. It does — the
condition is whether anything had read the cascade first, because the parse is
lazy and the cached copy was never invalidated. One isolation run, same mutation,
one line apart:

| | Chrome | before | after |
|---|---|---|---|
| mutate, then read | `visible` | `visible` | `visible` |
| read, mutate, read again | `visible` | **`hidden`** | `visible` |

Eight mutation shapes were stale that way: `textContent`, `innerHTML`,
`replaceChildren`, `appendChild` of more text, `firstChild.data`,
`firstChild.nodeValue`, removing the text node, and emptying the text.
Removing the whole element, `deleteRule` and remove-then-re-append always worked.
"Change the theme by rewriting a `<style>`" is an ordinary SPA move, and every
consumer of the cascade — `getComputedStyle`, `checkVisibility`, `innerText` —
was reading the pre-mutation rules for the life of the element.

One deliberate deviation: Chrome hands out a *new* `CSSStyleSheet` on a text
mutation and leaves the old object holding the old rules (`style.sheet` is not the
object it was). We re-parse in place, because `document.styleSheets` here is
insertion-ordered and re-registering would move the sheet past every sheet that
follows it in the document. `style.sheet.cssRules` reads the same either way.

### `!important` against the style attribute (T4)

CSS Cascade 4 §6.9 compares importance before specificity, and the style attribute
is specificity rather than a tier of its own, so an `!important` rule beats it and
an `!important` style attribute beats that back. The hidden-element check treated
the style attribute as unbeatable. Five of eleven rows read wrong:

| rule | style attribute | Chrome | before |
|---|---|---|---|
| `visibility:hidden!important` | `visibility:visible` | hidden, checkVisibility false | visible, true |
| `visibility:visible!important` | `visibility:hidden` | visible, true | hidden, false |
| `display:none!important` | `display:block` | none, false | none, **true** |
| `display:block!important` | `display:none` | block, true | none, false |
| `opacity:0!important` | `opacity:1` | checkVisibility false | true |

The third row is the one worth staring at: `getComputedStyle` said `none` while
`checkVisibility` said visible *and* `innerText` returned the text, because the
value path resolved importance and the boolean path did not. Two answers about one
element, from two functions a detector can call in the same breath.

Left alone deliberately: the computed *value* of `opacity` is not cascaded at all
(Chrome reads `0` for that last row where we read `1` — only the verdict is fixed),
`sheet.disabled` is still ignored, and `hasPointerEventsNone` still treats the
style attribute as unbeatable the way the hidden check used to.

### What it changed on the twelve stations (T3)

Eleven stations read within two characters of the previous sweep (page jitter).
amiunique dropped 39: its `innerText` was including a bottom navigation that
`.hidden-lg-and-up { display: none !important }` hides at this viewport width —
Chrome excludes it too, and did all along. Before the fix `getComputedStyle` on
that element already said `none` while `innerText` walked into it anyway, which is
the same self-contradiction the table above describes. browserscan is unchanged at
100% with no warnings and 0 skeletons.

Two more gaps surfaced and were left for their own plan: an SVG `<style>`'s rules
are not applied to the document at all (Chrome reads `hidden` for a span beside
`<svg><style>.tv{visibility:hidden}</style></svg>`, we read `visible`), and
`querySelector('style')` does not find an SVG-namespaced one, though
`getElementsByTagName('style')` does.

## SVG `<style>`: the cascade, and finding it with a selector (V1–V3)

The two gaps the section above left for their own plan. Both measured against
Chrome 151 on the same machine (probes `v1-svgstyle`, `v2-diag`, `v2-diag2`).

### The rules were invisible until something read the CSSOM view

`StyleManager` parses a `<style>`'s rules lazily, out of the element's text, and
only knew how to read an `HTMLStyleElement`. `CSSStyleSheet.getCssRules` already
handled both namespaces, so an SVG `<style>` did have a sheet, and it was in
`document.styleSheets` — its rules simply never reached the cascade. That made the
bug conditional on a CSSOM read, which is what the first V1 pass nearly misread:

| | Chrome | before | after |
|---|---|---|---|
| `<svg><style>.tv{visibility:hidden}</style></svg>` + `<span class=tv>` | `hidden` | **`visible`** | `hidden` |
| `<svg><style>rect{display:none}</style><rect>` | `none` | **`inline`** | `none` |
| same, after one `style.sheet.cssRules` read first | `hidden` | `hidden` | `hidden` |

The rule is not scoped to the `<svg>` subtree in any browser — it feeds the same
document cascade an HTML `<style>` does, which is why the HTML sibling above is the
first row.

### A type selector could not match SVG `style` or `script`

Selector parts keep a known tag name as an `Element.Tag` so matching is an enum
comparison. `getTag()` is only total over HTML, though: a foreign element whose
name has no dedicated SVG type answers `unknown`. Of the twenty-one SVG tag names
measured, `style` and `script` are the only two that are in `Element.Tag`, so they
were the only two the comparison could never match — every other name is absent
from the table and already took the tag-name arm. `getElementsByTagName`, which
compares names, found them all along.

| | `querySelectorAll` | `getElementsByTagName` |
|---|---|---|
| `style`, `script` (before) | **0** | 1 |
| `style`, `script` (after) | 1 | 1 |
| `rect`, `a`, `use`, `text`, `title`, `desc`, `mask`, `pattern`, `image`, `switch`, `defs`, `symbol`, `tspan`, `marker`, `view`, `filter`, `stop`, `svg` | 1 | 1 |
| `clipPath` | **0** | 1 |

`clipPath` is a different root cause and is left alone here: the selector's name is
lowercased for comparison while a foreign element keeps its name as written, so a
camel-cased foreign tag matches neither arm. Chrome matches `clipPath` and not
`clippath`, so the fix is a case-sensitive compare for non-HTML elements rather
than a wider lowercase.

### Corrected from the V1 notes

The V1 pass also reported that rewriting an SVG `<style>`'s text does not
re-cascade. It does — that reading came from a stale binary. Re-measured on the
plan's base commit, the SVG path matches the HTML control on all three mutation
shapes tried (`textContent`, `firstChild.data`, remove-then-append), before and
after the CSSOM view exists, and the row is kept as a regression in the test.

### What it changed on the twelve stations

Nothing measurable. Eleven stations read within one character of the previous
sweep, no verdict-word count moved, and browserscan is unchanged at 100% with no
warnings and 0 skeletons (`mainTotal` 845, `docTotal` 1871).

The twelfth needs a correction, because this section first claimed the opposite.
The sweep taken right after the fix read creepjs at 3870 nodes and 4172 characters
against 3598–3600 and ~4131 in the three sweeps before it, and that was written up
as the fix moving creepjs toward Chrome (which renders 4065 / 4742 there). It was
not: a later sweep of the very same commit read 3600 / 4129 again. **creepjs has an
outlier at 3870 that is not attributable to any change here** — one sample against
a stable baseline is not a finding, and this one was called from exactly that. The
node count of creepjs is only worth reading in a run of at least three.

## Camel-cased foreign tags and the type selector (C1–C3)

The `clipPath` row the section above left open, and it turned out not to be about
`clipPath`. Every camel-cased foreign tag was unreachable by selector, in every
spelling, along with every `createElementNS` name that keeps a capital.

### What the case rule actually is

The assumption going in was Selectors-4's "case-sensitively for foreign elements",
which would have made `clipPath` match and `clippath` not. Chrome 151 disagrees:
in an **HTML** document every spelling matches, foreign or not.

| document | selector | Chrome | before | after |
|---|---|---|---|---|
| HTML | `clipPath` on SVG `clipPath` | 1 | **0** | 1 |
| HTML | `clippath`, `CLIPPATH`, `ClipPath` on the same | 1 | **0** | 1 |
| HTML | `linearGradient` / `feBlend` / `textPath` / `foreignObject`, any case | 1 | **0** | 1 |
| HTML | `Foo` / `foo` / `FOO` on `createElementNS('urn:x', 'Foo')` | 1 | **0** | 1 |
| HTML | `mRow` / `mrow` / `MROW` on a MathML `mRow` | 1 | **0** | 1 |
| HTML | `rect` / `RECT` / `Rect` on SVG `rect` | 1 | 1 | 1 |
| XML | `Thing` vs `THING` on `<Thing/>` | 1 / **0** | 1 / 1 | 1 / 1 |
| XHTML | `p` vs `P` | 1 / **0** | 1 / 1 | 1 / 1 |

So the rule is per *document*, not per element: case-insensitive in HTML, sensitive
in XML. The engine does not distinguish, and did not before — the last two rows are
wrong here either way, and are left alone because everything this engine is for is
an HTML document. `getElementsByTagName` is the one that stays case-sensitive for
foreign elements in an HTML document too (`clipPath` 1, `clippath` 0, in both
browsers); the test pins that contrast so a future "just lowercase everything"
cannot quietly take it out.

The mechanism was that the element side went through `getTagNameLower`, which
lowercases for HTML and hands back a foreign element's name exactly as written,
against a selector name the parser had already lowercased. Neither the enum arm nor
the tag-name arm could match, so a camel-cased foreign tag had no route at all.

### What it changed on the twelve stations

Nothing: every station within 2 nodes and 6 characters of a sweep of the same
commit without the change, taken minutes apart, and no verdict-word count moved.
browserscan is unchanged at 100%, no warnings, 0 skeletons (`mainTotal` 845,
`docTotal` 1871).

## Type selectors in XML documents (X1–X3)

The section above closed the HTML half of the case rule and left the XML half
open, on the reading that "everything this engine is for is an HTML document".
X1 measures that half. The readings below are Chrome 151 against
`dev.315+7d866bb9d`, the commit the previous plan merged, so the `clipPath` fix
is already in — which is exactly why the XML side reads *more* wrong than it did
before: the case fold that HTML wanted now applies to every document.

Probes: `expr-x1.js` (selectors, `getElementsByTagName`, attribute names, four
document flavours), `expr-x1b.js` (tree dumps behind the surprises),
`expr-x1c.js` (`createDocument` / `new Document()` / `createHTMLDocument`).

### Type selectors: case-sensitive in every non-HTML document

| document | element | selector | Chrome | this engine |
|---|---|---|---|---|
| `text/xml` | `<Thing/>` + `<thing/>` | `Thing` / `thing` / `THING` | 1 / 1 / **0** | 2 / 2 / **2** |
| `text/xml` | `<s:clipPath/>` | `clipPath` / `clippath` / `CLIPPATH` | 1 / **0** / **0** | 1 / **1** / **1** |
| `application/xhtml+xml` | `<p>` | `p` / `P` | 1 / **0** | 1 / **1** |
| `application/xhtml+xml` | `<body>` | `body` / `BODY` | 1 / **0** | 1 / **1** |
| `application/xhtml+xml` | `<DIV/>` | `DIV` / `div` | 1 / **0** | **0** / 0 |
| `application/xhtml+xml` | `<P>a</P>` | `P` / `p` | 1 / **0** | **0** / 0 |
| `image/svg+xml` | `<clipPath/>` | `clipPath` / `clippath` | 1 / **0** | 1 / **1** |
| `image/svg+xml` | root `<svg>` | `svg` / `SVG` | 1 / **0** | 1 / **1** |
| `createDocument(null,'Root')` | `<Root>`, `<Kid>` | `Root` / `root` / `Kid` / `kid` | 1 / **0** / 1 / **0** | 1 / **1** / 1 / **1** |
| `new Document()` | `<Thing>` | `Thing` / `thing` | 1 / **0** | 1 / **1** |
| `createHTMLDocument` | `<div>`, SVG `<clipPath>` | any case of either | 1 | 1 |

The `<DIV/>` and `<P>` rows are the interesting ones: the engine matches them
under *no* spelling, where the rest of the table is only too permissive. The
selector parser lowercases a type selector's name and the fast enum arm keys off
that lowercase form, so an XML-parsed HTML-namespaced element that kept a capital
in its name has no route in at all — `.tag` compares an enum the element does not
carry, and `.tag_name` compares a lowercased selector against a name that is not
lowercase. Fixing the fold direction therefore needs the *original* spelling kept
alongside the lowercased one, the way `Selector.Attribute` already keeps
`original_name` next to `name`.

`createHTMLDocument` is the control: every spelling matches there in both
browsers, and has to keep matching.

### Adjacent readings taken at the same time

These are measured, not fixed by this plan. Recording them so the next plan that
touches XML documents does not have to re-measure.

| what | Chrome | this engine |
|---|---|---|
| `document.contentType` after `text/xml` / `application/xhtml+xml` / `image/svg+xml` | echoes the parse mime | always `application/xml` |
| `tagName` of `<p>` in an XHTML document | `p` | `P` (uppercased regardless of document) |
| `tagName` of `<s:clipPath/>` | `s:clipPath` | `clipPath` (prefix dropped) |
| `namespaceURI` of `<root>` with no `xmlns` | `null` | `http://www.w3.org/XML/1998/namespace` |
| `xmlns` attribute on a parsed XML root | present in `attributes` | dropped |
| `getElementsByTagName('P')` in an XHTML document | 0 | 1 |
| `[Foo]` on `<p Foo="1">` in an XHTML document | 1 | **0** (and `[foo]` 0) |
| `[Bar]` on SVG `<g Bar="2">` in an **HTML** document | 1 | **0** (only `[bar]` matches) |

The last two rows read like the tag-name story repeating, and this paragraph first
said so outright — case-insensitive in an HTML document whatever the namespace,
case-sensitive in XML. That was an inference from the neighbouring rule, not a
reading: an HTML-parsed `Bar="2"` is *stored* lowercased, so the row above cannot
tell a case-insensitive compare apart from two lowercase operands. The A1 section
below measures it properly, and the rule does come out that way — but it is that
section, not this one, that establishes it.

`getElementsByTagName` is a separate comparison in the collections code, not this
one.

### What the fix was (X2)

The parser now keeps both spellings of a type selector's name, `Selector.TagName`
alongside the `Attribute.original_name` that was already there, and only takes the
`Part.tag` enum shortcut when the selector was already lowercase -- which is the
only shape where the two spellings cannot be told apart. `tagNameMatches` then
compares the exact spelling first, because that answers both rules at once, and
falls back to the case-folded compare only when the element's owner document is an
HTML one.

Ordering it that way keeps the document lookup off the hot path: an all-lowercase
selector over an HTML tree stores a lowercase element name on one side and a
lowercase selector on the other, so the exact compare and the folded compare can
only ever agree, and a non-match returns before the lookup.

Every type-selector row in the table above now reads exactly as Chrome does,
including the two `createHTMLDocument` control rows and the `<DIV/>` / `<P>` rows
that used to match nothing at all. The adjacent rows are unchanged, as intended.

### What it changed on the twelve stations (X3)

Nothing. All twelve node counts are identical to a sweep of `dev.312+16ea92afa`
and no verdict-word count moved; four text lengths differ by 1 to 6 characters,
which is the usual counter/timing noise. creepjs read 3600 nodes both times, the
stable value -- not the 3870 outlier the previous plan's notes warned about.
browserscan is unchanged at 100% with no problems, no warnings, 0 skeletons
(`mainTotal` 845, `docTotal` 1871).

That is the expected shape: an HTML document takes the same code path it did
before, and every station is an HTML document.

## Attribute names and the document (A1–A3)

The plan above left the attribute half of the same question open on an inference.
A1 measures it. Chrome 151 against `dev.319+280343915`, probe `expr-a1.js`.

The probe is built to separate two readings that the earlier table could not: an
HTML-parsed attribute is stored lowercased, so `[Bar]` matching there proves
nothing about case folding. `setAttribute` only lowercases for HTML-namespaced
elements, so setting `Bar` on an SVG element is a stored capital in an HTML
document — and `viewBox` is one the HTML parser itself keeps, via its SVG
attribute-adjustment table.

| document | element | stored name | selector | Chrome | this engine |
|---|---|---|---|---|---|
| HTML | SVG `<g>`, `setAttribute('Bar')` | `Bar` | `[Bar]` / `[bar]` / `[BAR]` | 1 / 1 / 1 | 1 / **0** / **0** |
| HTML | `<div>`, `setAttribute('Foo')` | `foo` | `[Foo]` / `[foo]` / `[FOO]` | 1 / 1 / 1 | 1 / 1 / 1 |
| HTML | parsed `<svg viewBox=…>` | `viewBox` | `[viewBox]` / `[viewbox]` / `[VIEWBOX]` | 1 / 1 / 1 | 1 / **0** / **0** |
| HTML | parsed `<svg preserveAspectRatio=…>` | `preserveAspectRatio` | exact / lowercase | 1 / 1 | 1 / **0** |
| XHTML | `<p Foo="1">` | `Foo` | `[Foo]` / `[foo]` / `[FOO]` | 1 / 0 / 0 | **0** / 0 / 0 |
| `text/xml` | `<s:g Bar>` + `<s:rect bar>` | as written | `[Bar]` / `[bar]` / `[BAR]` | 1 / 1 / 0 | 1 / 1 / 0 |
| XML | `createElement` + `setAttribute('Foo')` | `Foo` | `[Foo]` / `[foo]` | 1 / 0 | 1 / 0 |
| HTML | `<div data-x="ABC">` | — | `="ABC"` / `="abc"` / `="abc" i` | 1 / 0 / 1 | 1 / 0 / 1 |

So the rule is the same shape as the tag-name one and it *is* a genuine fold, not
two lowercase operands: an HTML document matches an attribute name ASCII
case-insensitively whatever the element's namespace and whatever case the name is
stored in, and an XML document matches it exactly, HTML-namespaced elements
included. The value side (`i`) is unrelated and already correct.

`matchesAttribute` splits on `el._namespace` instead, so it is wrong in two
directions at once: a stored capital in an HTML document is reachable only by its
exact spelling, and in an XML document an HTML-namespaced element's attribute is
reachable by no spelling at all, because the selector's name was lowercased at
parse time and the stored one was not.

The `viewBox` row is the one with reach beyond XML documents: `svg[viewbox]`, the
spelling a stylesheet is most likely to carry, currently selects nothing in an
ordinary HTML page.

### A note for the fix

This one is not just a matter of passing `original_name` instead of `name`, the
way the type-selector fix was. The HTML-document branch needs a *case-insensitive
attribute lookup*: `getAttributeSafe` is an exact-name lookup, and the stored name
is not always lowercase (`viewBox`), so lowercasing the selector side alone cannot
find it.

### Two more readings the fix turned on (A2)

A1 left two questions that only matter once a name can be reached by a fold, and
they decide the shape of the lookup. Chrome 151, probes `expr-a2.js`,
`expr-a2b.js`, `expr-a2c.js`.

The first is whether reaching the name by a fold changes how the *value* is read.
It does not: on an HTML-document SVG `<g Bar="one two">`, every matcher spelled
`[bar…]` behaves as it would on an exactly-spelled name -- `="one two"` 1,
`="nope"` 0, `~="two"` 1, `^="one"` 1, `$="two"` 1, `*="e t"` 1, `="ONE TWO"` 0
and `="ONE TWO" i` 1. In a `text/xml` document the same selectors read 0 across
the board, the `i` flag included: that flag is about the value, so it cannot
rescue a name the document matches exactly. `[Bar="ONE TWO" i]` there is 1.

The second is what happens when one element carries both spellings, which only a
foreign element can. It is decided by *attribute order*, not by which spelling
the selector used:

| document | stored | `[bar="cap"]` | `[bar="low"]` | `[Bar="cap"]` | `[Bar="low"]` |
|---|---|---|---|---|---|
| HTML | `Bar=cap`, `bar=low` | 1 | 0 | 1 | 0 |
| HTML | `bar=low`, `Bar=cap` | 0 | 1 | 0 | 1 |
| XML | either order | 0 | 1 | 1 | 0 |

So in an HTML document both spellings resolve to whichever attribute comes first,
and the exactly-spelled one does not win by being exactly spelled. That rules out
"exact lookup first, case-insensitive lookup as a fallback" as an implementation:
it would answer `low` for the first row.

### What the fix was (A2)

`matchesAttribute` no longer looks the name up; it scans the element's attribute
list for the first entry whose name folds to the selector's. If that entry is
spelled exactly like the selector, it is the answer under both rules and the
document is never consulted -- which is the path an ordinary lowercase selector
over an HTML tree takes, and it keeps the owner-document walk off it. Otherwise
the document decides: an HTML one takes that entry, and an XML one falls back to
an exact lookup, since a later entry may still carry the exact spelling.

The owner-document test itself is now shared with `tagNameMatches` as
`inHtmlDocument`, the two rules being the same one.

Every row of the A1 table and of both A2 tables now reads exactly as Chrome does;
all four probes match this engine byte for byte. `svg[viewbox]` finds a parsed
`viewBox` on an ordinary page, and an XHTML `<p Foo="1">` is reachable as `[Foo]`.

### What it changed on the twelve stations (A3)

Nothing, and for the same reason as X3: every station is an HTML document, where a
lowercase selector against a lowercase stored name takes the exact-spelling branch
just as it did before. All twelve node counts match a sweep of `dev.319+280343915`
apart from creepjs, which read 3598 / 3600 / 3598 across three runs of the *fixed*
binary and so straddles its own baseline -- noise, not movement. Two text lengths
moved in the first run and three in the third, by 1 to 3 characters; rebrowser and
deviceinfo differ by that much between runs of one binary too, which is what makes
them noise. No verdict-word count moved. browserscan is
unchanged at 100% with no problems, no warnings, 0 skeletons (`mainTotal` 845,
`docTotal` 1871).

## The rest of the XML-document deviations (G1–G6)

The two plans above fixed the selector half of the XML-document story. The
"adjacent readings" table listed five more that were measured but left alone. G1
re-measures them against `dev.323+53eee4b0a` -- the merge of the attribute-name
fix -- because those readings were taken several commits ago and because the
table's rows were written narrowly enough to hide three further deviations.
Chrome 151, probe `expr-g1.js`, readings in `g1.cr.txt` / `g1.lp.txt`.

### Still there, as recorded

| what | Chrome | this engine |
|---|---|---|
| `contentType` after `text/xml` / `application/xhtml+xml` / `image/svg+xml` | echoes the parse mime | always `application/xml` |
| `tagName` of `<p>` in an XHTML document | `p` | `P` |
| `tagName` of `<s:clipPath/>` | `s:clipPath` (`prefix` `s`) | `clipPath` (`prefix` null) |
| `getElementsByTagName('P')` in an XHTML document holding only `<p>` | 0 | 1 |
| the `xmlns` / `xmlns:s` attribute on a parsed XML root | in `attributes` | dropped |

`contentType` is right for `text/html`, for `createHTMLDocument` and for
`createDocument`; only the parsed-XML mimes are wrong. `localName` and
`namespaceURI` of a prefixed element are both right -- it is `tagName` and
`nodeName` that drop the prefix. `createDocument`'s `application/xml` is Chrome's
answer too.

### Three the table did not say

The `namespaceURI` row said `<root>` with no `xmlns` reads
`http://www.w3.org/XML/1998/namespace` where Chrome reads `null`. It does, but the
row only covered the *undeclared* case, and the declared one is wrong in the
opposite direction:

| what | Chrome | this engine |
|---|---|---|
| `namespaceURI` of `<root>` with no `xmlns` | `null` | `http://www.w3.org/XML/1998/namespace` |
| `namespaceURI` of `<root xmlns="urn:x">` | `urn:x` | **`null`** |
| `namespaceURI` of a child of `<root xmlns="urn:x">` | `urn:x` | **`null`** |

So a declared default namespace is not merely mis-defaulted, it is discarded, and
an undeclared one is filled in with a namespace that is never a default. The two
readings are inversions of each other, which suggests one place gets it wrong
rather than two.

That inversion is what the two remaining new rows fall out of:

| what | Chrome | this engine |
|---|---|---|
| `getElementsByTagNameNS(null, 'Thing')` in a `text/xml` document | 1 | **0** |
| `getElementsByTagName('DIV')` in an XHTML document holding `<DIV/>` | 1 | **0** (and `'div'` 0) |

The first follows from the namespace inversion: a bare XML element does not answer
to the null namespace because we do not put it there. The second is its own bug in
the collections comparison -- the argument is lowercased for an HTML-namespaced
element and compared against a stored `DIV`, so *neither* spelling finds it and
the element is unreachable by `getElementsByTagName` at all.

`getElementsByTagName` in an HTML document is unaffected throughout: `div` / `DIV`
both 1, `clipPath` 1 with `clippath` and `CLIPPATH` 0, `*` 7 -- identical to
Chrome, which is the behaviour `element/svg/type_selector_case.html` already pins.
`getElementsByTagNameNS` agrees with Chrome everywhere except the null-namespace
row above.

### What this implies about the order

The five are not independent. `getElementsByTagName('s:clipPath')` cannot be right
until `tagName` carries the prefix, and `getElementsByTagNameNS(null, …)` cannot be
right until a bare XML element sits in the null namespace. So the namespace and
`tagName` work comes before the collections comparison, not after it.

### What G2–G5 changed, and what is left

The order G1 argued for is the order they were done in: `contentType` first
because it stands alone, then the namespace and `tagName` work, then the
collections comparison that depends on both.

| | what it fixed | probe now identical to Chrome 151 |
|---|---|---|
| G3 | `contentType` echoes the mime that was parsed | `expr-g1.js` |
| G5 | a declared `xmlns` reads back, an undeclared element is in no namespace, and the declaration stays in `attributes` -- declaration first, whatever its source position | `expr-xmlns-p67.js`, 11 of 11 rows |
| G4 | `tagName` / `nodeName` fold case only in an HTML document, and keep the prefix (`s:clipPath`, `prefix` `s`, `localName` `clipPath`) | `expr-g4-p67.js`, every name row |
| G2 | `getElementsByTagName` compares the qualified name and folds only in an HTML document | `expr-g2-p67.js`, 30 of 30 rows |

The `getElementsByTagName('DIV')`-is-unreachable row and the
`getElementsByTagNameNS(null, 'Thing')` row that G1 found beyond the table both
fall out of G2 and G5 respectively, as predicted.

Two deviations were measured on the way and deliberately left:

| what | Chrome | this engine |
|---|---|---|
| `new XMLSerializer().serializeToString()` of a prefixed or XHTML element | `<s:clipPath xmlns:s="…"/>`, `<p xmlns="…">x</p>` | `<clipPath></clipPath>`, `<p>x</p>` |
| `href.baseVal` of an element given `setAttribute('xlink:href', …)` | `""` -- the attribute is in no namespace, so it does not reflect | the value, indistinguishable from the parsed one |

The first is the XML serializer, which emits no namespace declarations at all
and is its own piece of work rather than a name bug. The second is the residual
half of the `xlink:href` fix: G4's prefix join stops the parser filing
`xlink:href` under `href`, which is what Chrome reads, and SVG's `href` now
falls back to the legacy spelling so a parsed `<use xlink:href>` still
reflects. Telling that apart from a literal `setAttribute` of the same string
needs a namespace on the attribute, which this engine does not have anywhere
(`Attribute.getNamespaceURI` is a flat null). Chrome 151 readings for both:
`expr-xlink-p67.js`, `expr-g4-p67.js`.

### Regression sweep

`detectors-g2456-lightpanda.json`, all twelve detectors, against
`detectors-g21-lightpanda.json`. Every site still navigates and completes; node
counts move within their usual run-to-run range. One row moved a long way, in
the right direction:

| | G21 | now | Chrome |
|---|---|---|---|
| CreepJS `textLength` | 87144 | 4130 | 4698 |
| CreepJS nodes | 3589 | 3602 | 3756 |
| CreepJS verdict words | 2 | 2 | 2 |

Every historical lightpanda sweep sat between 41457 and 87879 here while Chrome
sat at 4698, so the page was rendering an order of magnitude more text than
Chrome does; it now sits 12% under Chrome's figure with the node count and
verdict unchanged. Reproduced across two runs.

`browserscan-g2456-lightpanda.json` against
`browserscan-webgl-exception-after-lightpanda.json`: score 100% both, zero
warnings both, 845 main and 1871 document nodes both. The only rows that differ
are the clock and the seven-day IP count.

## The probes the sections above cite

Every `expr-*.js` name in this file used to mean a scratch file in a tmp
directory, which is to say that a reading could be cited but not re-checked.
They are in `probes/` now, and each runs against either engine through
`run-expr.mjs`:

```
node tools/fingerprint/run-expr.mjs chrome     tools/fingerprint/probes/expr-g4-p67.js
node tools/fingerprint/run-expr.mjs lightpanda tools/fingerprint/probes/expr-g4-p67.js
```

`LP_BIN`, `CHROME` and `PORT` override the binaries and the CDP port, the last
so two runs can go at once.

`results/probes/<name>.{chrome,lightpanda}.json` holds both engines' output for
each, taken on `dev.337+a4f812c47`. Thirteen of the eighteen are byte-identical
between the two, and every row that differs in the other five is a deviation
this file records: the XML serializer (`expr-g4-p67`, `expr-g5-p67`, `expr-g5`,
and `outerHTML` in `expr-g5b`) and the missing namespace on an attribute
(`expr-g5b`, `expr-xlink-p67`).

### What running them found

Three things, none of which reading the code had turned up.

**A probe that had never been run against this engine.** `expr-xlink-p67`
appended its fixture to `document.body`, and this engine's `about:blank` has
neither a `body` nor a `documentElement`. Nothing it measures needs to be
connected, so the fixture stays detached and it now runs on both. Chrome's
readings are unchanged by that edit, which matters because
`element/svg/animated_string.html` asserts them.

**A real ordering bug.** `expr-g5b`'s `both` row -- an element carrying a
default *and* a prefixed declaration -- read back reversed. So did any element
with two prefixed ones. Chrome keeps declarations in the order they were
written; xml5ever's tokenizer hoists each to the front of the tag's attributes
as it finishes it, so they arrive reversed and the capture handed them on that
way. `expr-order.js` is the probe that pins it, and all five of its rows are
identical now.

**A missing method.** `attributes.getNamedItemNS` does not exist here at all --
not a null return, no method. That read is wrapped now, the way `probe.js`
wraps its reads, so "the method is missing" is recorded as a reading instead of
losing the other rows in the file.

### One more deviation, found by running them

`expr-g5-p67` compares malformed-XML handling, and the two engines part on more
than the serializer:

| what | Chrome | this engine |
|---|---|---|
| `parseFromString('<a', 'text/xml')` | keeps `<a>` as the document element **and appends an XHTML `<parsererror>` block inside it** describing the error | keeps `<a>`, appends nothing |

The document element agrees -- `a`, null namespace, no attributes in both -- so
this is not the namespace work regressing; we simply do not report a recoverable
parse error into the tree. The empty-input case does produce a `<parsererror>`
document (`DOMParser.zig` synthesises one, and `domparser.html`'s `basic` block
pins its serialization against Chrome's for the same markup), so the gap is
specifically the malformed-but-recoverable path. Left as measured, not fixed.

## The `probe-*` batch the sections above cite

The same problem, one directory over. The `probe-win*.js`, `probe-css*.js` and
`probe-perm*.js` names the sections above cite -- and the `win*-chrome.json`
readings and `win*-findings.md` notes they quote -- were a scratch directory
that had wandered into an unrelated repository's working tree. Nineteen probes
are in `probes/` now; the recordings they are quoted against, and the notes
written from them, are in `results/probes/`.

Which runner depends on what the probe waits for:

```
node tools/fingerprint/run-probe.mjs chrome     tools/fingerprint/probes/probe-win29.js http://127.0.0.1:8752/
node tools/fingerprint/run-probe.mjs lightpanda tools/fingerprint/probes/probe-win29.js http://127.0.0.1:8752/
node tools/fingerprint/run-page-probe.mjs                tools/fingerprint/probes/probe-win29.js
```

The url is not optional for this engine. `about:blank` is not a secure context,
and -- the part that costs an afternoon if you do not know it -- **this engine
does not run scheduled tasks while an `awaitPromise` evaluate is outstanding**,
so any probe that awaits a `setTimeout` hangs until the CDP client's 30-second
timeout. Nine of these nineteen do exactly that. `run-expr.mjs`, which drives
the `expr-*.js` files above against `about:blank`, therefore cannot carry this
batch at all; a bare
`await new Promise((r) => setTimeout(() => r('fired'), 50))` never resolves
under it and returns `{"timer": "fired"}` the moment the same expression is
loaded as a page. `run-page-probe.mjs` is that page path, and it has its own
ceiling: `lightpanda fetch --dump` decides the load is finished somewhere
between two and six seconds no matter what keeps a timer alive, so a probe with
a longer wait budget -- `probe-win11b` spends up to 13.7 seconds on guards --
has to go through `run-probe.mjs` against a served page.

`results/probes/` now holds two kinds of file, and the difference matters:

* `probe-*.{chrome,lightpanda}.json` -- this run. `dev.340+3d96734f2` and
  Chrome 151.0.7922.138 `--headless=new`, both against the same
  `http://127.0.0.1:8752/`, so the pair is comparable leaf by leaf.
* `win*-chrome.json`, `perm1-chrome.json`, `webrtc-*-chrome.json` -- the
  readings the code comments cite by name, taken earlier on a *headed* Chrome
  150. Those are the ground truth the Zig comments quote; they are kept as
  recorded, not regenerated.

Four probes are byte-identical between the two engines: `probe-perm1`,
`probe-perm2`, `probe-win43` and `probe-win52`. Across the other fifteen, 84
leaves differ -- three of which only carry the host the page was served from or
a frame timestamp, leaving 81 real ones.

### What running them found

**Three recorded readings the engine had outgrown.** `css11-lp.json`,
`win29-lp.json` and `win57-lp.json` were stale, and re-running the probes is
what said so. `probe-css11`'s seven constructor `TypeError` rows went from 0 of
7 matching Chrome to 7 of 7 -- the messages are Chrome's exact
`Failed to construct 'CSSAnimation': Illegal constructor` wording now, where
the recording still had the generic `Illegal Constructor`. `probe-win29` went
from 5% of its shared leaves matching Chrome to 96%: the recording is a wall of
`ReferenceError: DOMError is not defined`, `Highlight`, `MathMLElement`,
`Sanitizer`, `XSLTProcessor`, `BlobEvent`, `ClipboardEvent` -- all implemented
since. `probe-win57` went from 93% to 98%, with `ImageCapture` and
`MediaMetadata` arriving in between. Nothing regressed; the files were simply
older than the engine.

**A headless Chrome does not reproduce a headed one, on five of them.**
`probe-win11b` (`perm:midi`), `probe-win29`
(`reportingObserver.takeRecords`), `probe-win38`
(`adapterFeaturesOrder`), `probe-win57` and `probe-win63` (`origin`,
`filesystem.request`, `ElementInternals.protoOwn`) read differently under
Chrome 151 `--headless=new` than under the recorded headed Chrome 150. The
`adapterFeaturesOrder` rows are the unstable-order case this file already
records for WebGPU, and `origin` / `filesystem.request` only carry the host the
page was served from -- but the split is why the headed recordings stay.

**Where we still differ, by cluster.** `probe-css7` was the worst at 32 of 209
leaves -- CSS Typed OM's `computedGet*` answers and most of its parse-error
messages -- and is now **0 of 208**, both engines rerun against the same host on
Chrome 151 (`results/probes/probe-css7.{chrome,lightpanda}.json`). Three things
were behind it. The bridge had no way to put a message on an exception at all,
so 25 rejections threw the right error type with nothing after the colon; there
is a `js.Context.fail` now and every sentence is quoted from a measurement,
because Blink's own wording is not guessable (`Must specify an number unit`
beside `Must specify a number unit`, `Invalid propertyName` for `get` beside
`Invalid property name` for `delete`). `computedStyleMap().get()` answered
`undefined` for six properties whose initial value the computed view did not
carry -- and `border-width` cannot share that initial value with
`getComputedStyle`, which reports the used `0px` where the Typed OM reports the
computed `3px`. And `CSSStyleValue.parse` accepted any identifier for any
property, where Chrome runs its real per-property parser; `dump-css-keywords.mjs`
now measures that parser one (property, identifier) pair at a time into
`src/browser/webapi/css/chrome_keywords.zig`.

One `probe-css7`-adjacent gap stays open on purpose, recorded in
`src/browser/tests/css/typed_om.html`: `parse` still accepts non-identifier
values Chrome rejects (`parse('width', 'abc def')`), which would need the
per-property grammars this engine does not have. Separately, and larger: an
invalid inline value sticks here (`el.style.width = 'notalength'` reads back
`notalength`) where Chrome drops it.

**Property-name case was the other one, and it is closed** (`probe-css12`,
39 readings, both engines against the same host on Chrome 151). It had been
written down as `CSSStyleDeclaration.isKnownPropertyName` being
case-sensitive; measuring it says otherwise. The CSSOM half was already
case-insensitive -- `getPropertyValue` / `setProperty` / `removeProperty` /
`item` / `getComputedStyle().getPropertyValue` all normalise on entry -- and
all 24 differing readings were in the Typed OM, which looked every name up as
written: `attributeStyleMap.get('WIDTH')` threw `Invalid propertyName: WIDTH`
where Chrome answers `CSSUnitValue|10px`. Ten members were affected
(get / has / getAll / set / delete / append on both maps, plus
`CSSStyleValue.parse` and `parseAll`), and each now normalises on entry.

The gate was not the whole fix, which is why the note above was cheap to write
and wrong to act on directly: `dispatch`, `StylePropertyMap.validateFor` and
`append`'s custom-property branch all compare property names too, so
normalising only `isKnownProperty` would have turned
`computedStyleMap().get('DISPLAY')` from a throw into a bare `CSSStyleValue`
where Chrome answers a `CSSKeywordValue` -- a silently wrong value in place of
a loud wrong one. Two things came out of the same measurement: a custom
property name stays case-sensitive (`--Case` and `--case` are two properties,
on both engines), and `parseAll`'s messages name `parseAll` rather than
borrowing the wording of the `parse` the two share.

The one reading that still differed afterwards was not about case: deleting a
property that is not there reserialised the style attribute here (`--Case:
1px;`, trailing semicolon) where Chrome leaves the authored text alone. That is
closed too, below, and `probe-css12` is now **0 of 39**.

**The declaration side is closed to the four re-casing rules** (`probe-css13`,
42 readings, headed Chrome 151 against this engine on the same host).
It started at 27 of 42 and is now **5**, every one of them a shape deliberately
left out of scope. Two separate findings, neither guessable:

*What rewrites the attribute text.* The style attribute is rewritten only when
the declaration block actually changed. Removing a property that was never
there, removing a custom property under the wrong case, setting a property to
the value it already holds, setting an absent property to `""` -- Chrome treats
all of them as no-ops and the authored text survives byte for byte, down to the
semicolon it was written without. This engine resynced on every one, and since
its own serialisation always ends in `; `, the tell was an attribute that grew a
semicolon no author typed just from being *read at* by a script.

*What rewrites the value's case.* Chrome re-cases exactly four things -- a
keyword the property takes, a CSS-wide keyword, a dimension's unit and a
function name -- and leaves the rest as authored. It is four rules and not one:
a `<custom-ident>` (`font-family: MyOwnFont`, `grid-area: MyArea`), a string, a
custom property's value and **anything containing `var()` / `attr()` / `env()`**
all keep their capitals, the last of those freezing the whole value with it
(`width: CALC(1PX + VAR(--a))` reads back byte for byte, because its content is
substituted later). And the four take the *canonical spelling*, not lowercase:
`TranslateX(1PX)` answers `translateX(1px)`.

So the spellings are measured rather than derived, by
`dump-css-value-case.mjs` -> `src/browser/webapi/css/chrome_value_case.zig`:
each candidate unit and function name is written to a real declaration in upper
case and read back. That is how `Q` turned out to serialise as `q`, which the
spec's own spelling of the unit would have got wrong. The same run answers a
question `chrome_keywords.zig` structurally cannot: a property that accepts an
arbitrary identifier still *has* keywords, and since Chrome accepts both
`MyOwnFont` and `sans-serif` for `font-family`, acceptance is no signal there --
re-casing is. 218 such keywords over 29 properties.

The five readings that still differ are all cases where Chrome rewrites the
value past a case change, which needs a colour parser and a number normaliser
this engine does not have: `#AABBCC` -> `rgb(170, 187, 204)`, `1E2px` ->
`100px`, `url(Foo/Bar.PNG)` -> `url("Foo/Bar.PNG")` (the name is re-cased, the
quoting is not added), a quoted font family losing its quotes -- plus
`setProperty('height', 'notalength')` sticking here, which is the
invalid-inline-value difference recorded above.

`probe-win63` has 10 of 548 -- `DOMMatrix` /`WebKitCSSMatrix` /
`SpeechRecognition` prototype sets and the `DOMMatrix` parse-error text.
`probe-win29` has 8 of 263, including `XSLTProcessor` producing no document and
`Path2D` not reaching the canvas. `probe-win55` has 7 of 31, all of them
maplike iterator identity (`iteratorIsValues`) on the WebXR collections.
`probe-win30`'s `bipe.frozen` and `probe-win57`'s `MediaMetadataArtworkFrozen`
are the same shape of miss: an array Chrome freezes and we do not.

## The commercial guards, and the regression that came with them (2026-08-20)

Everything above this line measures a *detector*: a page that reads a
fingerprint and writes down what it thinks. None of them can refuse to serve
you. The question a crawler actually has is the other one — does Cloudflare open
the door — and this harness had never asked it. `grep -i cloudflare` over
`tools/fingerprint/` returned nothing before this section.

`antibot-sweep.mjs` asks it. Fifteen stations in `sites.mjs`'s new `ANTIBOT`
list, every one recon'd with a bare curl first so `guards` records what it does
to a naive client; both engines driven over the same route minutes apart, because
the address is half of any guard's decision. The reading is the document's HTTP
status off `Network.responseReceived` plus the guard's marks in the DOM, kept
separate: a challenge that clears leaves a 200 behind and looks like a plain pass
on status alone.

The full table and the caveats that go with each row are
`results/antibot-2026-08-20-vs-chrome.md`. The short version:

| | Chrome (headed 151) | `dev.340+3d96734f2` | re-run, `dev.664+8fc2ac1d0` |
|---|---|---|---|
| Cloudflare **managed challenge** (3 stations) | scrapingcourse solved, 403→200 | **all three stuck on the interstitial, 403, `Just a moment...`**, 16n | still 0/3, 403 — but **46n, the same DOM Chrome renders** |
| Cloudflare **passive scoring**, production sites | indeed 1216n, discord 1196n, nowsecure 51n | **indeed 1211n, discord 1531n, nowsecure 51n — passed** | indeed 1208n, discord 1531n, nowsecure 51n — passed |
| claude.ai | 1086n sign-in page | empty document, 121n | **pass, 1066n** |
| chatgpt.com | 722n | 40n `Application Error!` | **pass, 491n** — renders, still short of Chrome's 725n |
| pixiv | 311n | wedges the engine, 73s then no answer | **pass, 311n — Chrome's 311 exactly** |
| DataDome (4 stations) | 0/4 in this run, 3/4 in the run before | not attributable — see below | 2/4 (datadome.co, hermes), Chrome 0/4 again — still not attributable |

The re-run is the second table in `results/antibot-2026-08-20-vs-chrome.md`: same
route, same egress, eight hours later, with the two crashes fixed. It reads
**10/15 against headed Chrome's 9/15**, and that is not a claim about beating
Chrome — the whole lead is DataDome's policy toward each client on a residential
IP. The managed challenge is still 0/3, and that is the row that measures us.

### The Cloudflare challenge is refused by us, not by Cloudflare

The engine's own log names it on the first station traced:

```
http : script blocked by csp
url = …/cdn-cgi/challenge-platform/h/g/orchestrate/chl_page/v1?ray=…
```

The interstitial sends `script-src 'nonce-…' 'unsafe-eval'
https://challenges.cloudflare.com` — no `'self'`, no `'strict-dynamic'` — and
injects its loader with `a.nonce = '…'` set on the element. The nonce is the only
source expression that admits that same-origin URL. `Csp.zig` treats a
`'nonce-…'` source as inline-only, matches nothing, and refuses the script; the
challenge never runs, nothing is posted back, and the interstitial never clears.
The whole station is four wire events: the document, its 403, the favicon, its
200.

**So this is not a fingerprint reading.** Cloudflare had not run a line of its
detection code when we declined to load it, and what its verdict on this engine
would be is unmeasured. The same rule blocks claude.ai's main bundle, which is
why that page comes back empty.

That falsifies a claim this file has carried since F4: "every one of those
simplifications is in the more-permissive direction, so none of them can break a
page a real browser would run." Two of them were deliberately in the stricter
direction, and those are the two that broke a page — one of them the page
standing between this engine and every Cloudflare-protected site that challenges.

The encouraging half of the same table is that Cloudflare's *passive* layer is
being passed on production sites: indeed.com answers a bare curl with `403` +
`cf-mitigated: challenge` and answers this engine with the site, within 5 nodes
of Chrome's rendering. That is the P3–P6 transport and navigator work doing what
it was for.

### The regression, run at the same time

Same binary, the twelve detectors and the probe collectors, against a headed
`Chrome/151.0.7922.138` taken the same day
(`results/regression-2026-08-20-{lightpanda,chrome}.json`,
`results/regression-2026-08-20-vs-chrome.md`).

**Nothing moved.** Every one of the twelve node counts is identical to the last
recorded sweep, across the fifty-nine commits since `dev.281`: sannysoft 291,
creepjs 3600, rebrowser 98, deviceinfo 264, browserleaks-js 1183,
browserleaks-tls 5, amiunique 1571, iphey 487, pixelscan 1783, browserscan 1871,
the two dead `arh` endpoints 8. iphey still reads `Looks Trustworthy` with its
space, sannysoft still has **0 FAIL rows**, and the probe surface is at its best
recorded figure: **74/90 keys identical to Chrome**, up from the 59/90 the P7
table ends on.

The sixteen that differ are all in classes this file already records — the two
deliberately fixed values (`hardwareConcurrency`, `deviceMemory`), the window box
(`screen.avail*`, `inner/outerWidth`), `userAgentData.highEntropy`'s empty
`platformVersion`, the canvas hash and font widths, the two `ownPropertyNames`
counts, the three header-layer gaps, and CreepJS's own ids. No new deviation
class appeared.

### Where the sweep was wrong about itself, twice

Both worth reading before trusting a number out of it.

**A wedged station used to take every station after it.** pixiv times out, and
the first run then reported six DataDome and unattributed stations as
`Page.navigate` timeouts that were never attempted — six clean-looking refusals,
manufactured. `--fresh` gives each station its own engine process, and every
number above was taken with it. Same class of fault as the undrained-pipe one in
the detector-sweep section, and it produced a plausible wrong answer on the first
try again.

**`_cf_chl_opt` and the challenge-platform script are not evidence of a block.**
The first verdict rule counted them and scored two served pages as challenges:
headed Chrome reads pixiv's real page with both marks set, and chatgpt serves the
script to this engine while serving Chrome a page without it. Cloudflare's JS
detections ride along on ordinary pages. The rule now turns on the interstitial's
own title and DOM, or a document that never stops being a 4xx.

### The DataDome column is not a result yet

Four stations, and the *control* moved between two runs twenty-five minutes
apart on the same route: the first sweep's headed Chrome passed datadome.co,
leboncoin and hermes and was challenged only at g2; the `--fresh` re-run's Chrome
was challenged at all four. This engine's column reads better than Chrome's in
the re-run — it passes datadome.co and hermes — and that means nothing, because a
column beside an unstable control cannot be read as a verdict about the client.
Cold profile per station and twenty-five more minutes of requests from one
address are both in the difference and neither was isolated. Alternating engine
order across repeated runs is what would make it say something.

## Honouring the nonce, and the door behind that door

The section above ends on a bug rather than a verdict: Cloudflare's challenge
never ran here because `Csp.zig` treated a `'nonce-…'` source as inline-only and
refused the interstitial's own loader. That is fixed, and the fix says something
about the fingerprint work that the sweep alone could not.

Two things were wrong, one of which would have hidden the other:

1. **A nonce source never matched a URL.** Per spec it matches the *element*
   carrying that nonce, whatever its URL — that is the whole point of a nonce,
   and it is not an inline-only rule. `allowsScript` takes the element's nonce
   now, and a policy naming a matching one is satisfied without consulting the
   URL at all.
2. **The parser lower-cased every source expression it read.** A nonce is
   base64 and is compared exactly, so `'nonce-v4r3E9xWYvR93f3o09vl4E'` was
   already unusable before the matching was missing. Sources keep their case
   now; the keyword, scheme and host comparisons fold case themselves.

`'strict-dynamic'` is still not honoured and `'sha256-…'` still matches no URL —
a hash is over a body nothing here reads. A nonce is much narrower than
strict-dynamic: it admits the one element the page put a secret on, not
everything that element goes on to insert, so rebrowser's `bypassCsp` row cannot
regress through it. `csp_nonce.html` pins that directly — same file, same
policy, the un-nonced and wrongly-nonced insertions both still fire `error`.

### What it bought, measured

Full table in `results/antibot-nonce-fix.md`. The challenge conversation now
happens end to end:

```
GET  /cloudflare-challenge                                    403
GET  /cdn-cgi/challenge-platform/h/g/orchestrate/chl_page/v1  200   <- was blocked
GET  challenges.cloudflare.com/turnstile/v0/g/…/api.js        200
POST /cdn-cgi/challenge-platform/h/g/fo/…                     200   <- the result, submitted
```

**This engine has now been evaluated by Cloudflare for the first time.** The
interstitial still does not clear, and what stops it is again not a verdict:

```
Turnstile Widget seem to have hung:  etjo7
[Cloudflare Turnstile] Cannot find Widget cf-chl-widget-etjo7, …
```

Turnstile builds its hidden `cf-turnstile-response` input and never gets its
widget container or iframe into the document — `querySelectorAll('iframe')` is
empty at 20s, with `window.turnstile` an object and `getElementById` working on
what does exist — so its own lookup fails, it declares itself hung, and the page
reloads and starts over every ~20s. A 75s settle reads exactly what 25s reads,
so it is not slowness. There is one `worker fetch error … blob:… err = Abort` in
the same window and one `initialFrameNavigation` for a frame that does not
survive.

So the answer to "does the fingerprint survive Cloudflare" is still **unmeasured**
— but the blocker has moved from a policy check we got wrong to a named,
reproducible DOM gap, which is what the first one needed too before anyone could
fix it.

### Two side effects, and one of them is worse

- **chatgpt.com renders its real page**, 491 nodes against 40. Not attributed:
  the pre-fix trace logged no CSP block on that host, and Chrome's own readings
  moved 514 → 722 between runs, so this is an improvement whose cause was not
  isolated.
- **claude.ai went from blank to wedged.** Its main bundle was the blocked
  script; it loads now, the app runs, and the engine stops answering
  `Runtime.evaluate` after 86s. Same shape as pixiv, which wedges regardless of
  this change, so the count of unattributed engine hangs went from one to two.
  *(Both were crashes, both are fixed — the next section, and the re-run row in
  the table above: claude.ai passes at 1066 nodes.)*
- **indeed, discord and nowsecure are byte-for-byte unchanged**, which is the
  over-permissiveness check.

## The two "wedges" were crashes

pixiv and claude.ai were recorded above as stations that wedge the engine —
`Runtime.evaluate` stops answering and never comes back. Both were aborting, and
they are two different bugs. Full write-up in `results/engine-wedge.md`.

**A dead engine and a stuck one are the same reading from a CDP client.** That is
the whole reason this sat mis-called across three runs, including a `--fresh`
re-run added specifically to rule out interference. Polling the process itself
alongside the page settles it in two samples:

```
  5s http=200          eval(1+1)=TIMEOUT  cpu=gone
 10s http=fetch failed eval(1+1)=TIMEOUT  cpu=gone
```

`antibot-sweep.mjs` records the child's exit code and signal per station now, and
prints `CRASHED SIGABRT` where it used to print only the client-side timeout. The
signal was available on the first sweep; nobody was reading it.

### pixiv — fixed

```
reason: index out of bounds: index 0, len 0
src/browser/frame/observers.zig:306 in deliverIntersections
```

`deliverIntersections` iterates backwards, which handles an observer
disconnecting *itself* mid-delivery, and its comment says as much. A callback can
disconnect *other* observers too: two of them dropping both takes the list from 2
to 0 while the loop still has `i = 0` to go. `deliverResizes`, twenty lines
above, already carried the length re-check that fixes it — the sibling having the
guard and this one not is the entire bug.

`intersection_observer/disconnect_all_during_callback.html` reproduces it locally
and aborts the test binary with the same reason and line as pixiv did.

| | before | after |
|---|---|---|
| pixiv | `SIGABRT` mid-load | **pass, 311 nodes — the same 311 Chrome reads** |
| suite | — | 1264/1264 |

### claude.ai — fixed, and the first two attributions were wrong

Survives that fix, and crashes elsewhere:

```
src/browser/webapi/PerformanceObserver.zig:195 in hasRecords
    return self._entries.items.len > 0;
src/browser/js/Scheduler.zig:132 in runQueue
```

`Performance.scheduleDelivery` queued a task that walked `perf._observers.items`
as a **slice snapshot**. A delivery callback that constructs a
`PerformanceObserver` and calls `observe()` appends to that same list; past the
capacity the arena reserved, the append moves the buffer and releases the old
one, and the pass keeps reading the released copy. The next pointer it reads is
Zig's `0xaa` fill and `hasRecords` dereferences it. claude.ai's login page
registers observers from inside a delivery callback.

The crash address said this from the start and two write-ups read it as a
lifetime bug anyway: `0xaaaaaaaaaaaaaac2` is `0xaaaaaaaaaaaaaaaa + 0x18`, and
`0x18` is where `_entries.items.len` sits in `PerformanceObserver` — so the
poison *was* the observer pointer, read out of a dead buffer, with the
`Performance` and its `len` both alive.

Re-reading `_observers.items[i]` each iteration is the fix, and the fork already
had it: upstream `a4b258305` (PR #3213), in via the 295-commit merge. Isolation,
three station runs a column: `9d117e371` `SIGABRT` 3/3 → same commit plus that
one loop change, pass 3/3 → `main` pass 4/4.
`performance_observer/register_during_delivery.html` pins it — against the
snapshot loop it aborts the test binary with the production crash verbatim.

## The window global surface, against a headed baseline (2026-08-20)

A headless reading had put this engine 247 globals *ahead* of Chrome, which
would be the worst kind of miss -- a name no browser has is a positive signal,
where a missing name is only an absence. The number came with a caveat
attached: the baseline was headless, and this file already records five probes
where a headless Chrome 151 does not reproduce the headed one. So it was
re-measured against both.

`probe-globals.js` dumps `Object.getOwnPropertyNames(window)` and nothing else
-- values, descriptors and prototype shapes are what the `probe-win*` batches
are for; this one only answers which globals exist. Same probe, same host
(`http://127.0.0.1`), three runs: this engine, Chrome 151 headless, Chrome 151
headed.

**The headless baseline was not the problem.** Headless and headed Chrome
answer the *same 1237 names, byte for byte* -- 0 headless-only, 0 headed-only.
Whatever produced 247 was not counting this. Every way of counting a "global"
that both engines can answer puts it in single or low double digits: window own
names 13, `for...in` 3, the union along the whole prototype chain 10. The
engine has 1167 own names to Chrome's 1237.

**What we have that headed Chrome does not, all 13, each confirmed by a
`typeof` on both engines:**

* `setImmediate` / `clearImmediate` -- no browser has these. A page reading
  `typeof setImmediate` gets `"function"` here and `"undefined"` in Chrome,
  which is the Node-shaped tell this whole exercise exists to remove.
* `addEventListener` / `removeEventListener` / `dispatchEvent` as window **own**
  properties. Chrome has them once, on `EventTarget.prototype`; we have them in
  both places (`hasOwnProperty(window, 'addEventListener')` is true here, false
  in Chrome). Same root as the prototype-chain shape below.
* `Css` -- an interface object beside the real `CSS` namespace, which Chrome has
  as an object with no `Css` anywhere. Exposing an interface Chrome lacks is why
  `CSSStyleProperties` was deleted in G16.
* `SVGGenericElement` -- this engine's catch-all for unrecognised SVG tags,
  named as a global.
* `CrossOriginWindow`, `ReadableStreamAsyncIterator`,
  `WEBGL_debug_renderer_info`, `WEBGL_lose_context` -- internals and WebGL
  extension objects Chrome keeps unnamed.
* `ModelContext` / `ModelContextClient` -- this fork's WebMCP surface, kept
  deliberately (G14 records the same call for `navigator.modelContext`).

Five of those thirteen are already being removed on `prd/window-surface-extras`
(`8a7202dbe`): `Css` becomes `[LegacyNoInterfaceObject]`, `setImmediate` /
`clearImmediate` come off the window surface while their implementations stay
for internal callers, and `Snapshot`'s `[Global]` flattening stops copying
`EventTarget`'s three members onto the global. That branch reached the same
13-and-83 split independently from its own headed run, which is the reason to
trust either reading. The counts above are as of `bbf32fc9d`, before it lands.

**The other direction is the larger one: 83 globals headed Chrome has and we do
not** (`CSSFunctionRule`, `CloseWatcher`, `Temporal`, `Observable`,
`PressureObserver`, the SharedStorage family, `LanguageModel` / `Summarizer` /
`Translator`, the fenced-frame family, ...). The full lists are in
`results/probes/probe-globals.{chrome,chrome-headless,lightpanda}.json`.

**And the prototype chain still differs**, which G19 measured and G17 owns:
`Object.getPrototypeOf(window) === Window.prototype` is `true` in Chrome and
`false` here. Chrome's chain is `Window(1237 own) <- Window.prototype(3) <-
EventTarget(0) <- EventTarget.prototype(5) <- Object.prototype(12)`; ours is
`Window(1167) <- Window(1) <- Window(239) <- EventTarget(4) <-
Object.prototype(12)`. That extra intermediate is where the three duplicated
`EventTarget` members come from.
