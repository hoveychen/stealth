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
| `detector-sweep.mjs` | Walks every detector in `sites.mjs` and records how far each page got — nodes, text length, verdict words, and whether the navigation happened at all. Answers "does the detector finish", which the collectors do not. |
| `subresource-check.mjs` | Answers "did the request happen at all", per fetch destination. Exits non-zero on a miss. Takes engine flags after `--`. |
| `collect-*.mjs` | Spawn the engine, run the four steps, write one JSON snapshot. |
| `dump-voices.mjs` | Regenerates `src/browser/webapi/speech/voices.zig` from the real Chrome's `speechSynthesis.getVoices()`. The list arrives asynchronously, so it polls until it stops growing and refuses to write an empty table. |
| `dump-graphics.mjs` | Dumps Chrome's *whole* graphics API surface — every GLenum, every method's arity, every `getParameter` answer, every character's advance width. `probe.js` asks "what does a fingerprinting script see"; this asks "what exactly should we report". The Zig code under `src/browser/webapi/canvas/` is transcribed from its output. |
| `diff.mjs` | Renders a candidate/reference markdown comparison. |

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

Three gaps remain at this layer, all measured rather than assumed:

1. **Header order still differs.** Chrome sends
   `host connection sec-ch-ua sec-ch-ua-mobile sec-ch-ua-platform upgrade-insecure-requests user-agent accept sec-fetch-site sec-fetch-mode sec-fetch-user sec-fetch-dest accept-encoding accept-language`;
   we send
   `host accept-encoding sec-ch-ua sec-ch-ua-mobile sec-ch-ua-platform user-agent accept-language accept sec-fetch-dest sec-fetch-mode sec-fetch-site upgrade-insecure-requests sec-fetch-user`.
   libcurl emits `Host` and `Accept-Encoding` from its own slots and appends the
   caller's slist after them, so the interleaving Chrome produces isn't
   reachable by ordering the slist alone. Closing this means either taking over
   curl's internal headers (supply `Host:` explicitly, blank out curl's
   defaults) or moving off libcurl for page requests.
2. **`Connection: keep-alive` is deliberately absent.** Chrome sends it on
   HTTP/1.1 only — the header is illegal in HTTP/2. Headers are built before
   the protocol version is known, so emitting it unconditionally would put an
   illegal header on every h2 request. Needs a version-aware hook.
3. **`Accept-Encoding` omits `zstd`.** Chrome sends `gzip, deflate, br, zstd`.
   The first three are now in Chrome's order, but advertising `zstd` when the
   bundled libcurl may not have it means a response we cannot decode.

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
`stealth-detector-probes/win-batch/`: `win20` for the shapes, `win22` and
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

Ground truth is in `stealth-detector-probes/win-batch/`: `win28` for the shapes
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
  interface's, which the vendored v8 C bindings do not currently expose
  (`SetPrototypeProviderTemplate` is not bound). The same four differences
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
