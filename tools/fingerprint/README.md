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
```

Node >= 22 only, no npm dependencies (global `WebSocket` and `fetch`).

## What each piece does

| file | role |
|---|---|
| `cdp.mjs` | ~100-line raw CDP client. Both engines go through it, so a difference in the snapshot comes from the engine, not from a driver. |
| `probe.js` | One async expression collecting ~90 fingerprint surface values. Every read is wrapped, so "this property throws" is recorded as data instead of aborting the run. |
| `header-echo.mjs` | Raw-TCP HTTP server that records the byte-exact request head. `node:http` reorders headers, and header order is itself part of the fingerprint. Serves a page pulling one of every fetch destination (document, style, script, image, iframe, fetch, xhr). |
| `sites.mjs` | URLs + in-page extractors for bot.sannysoft.com and CreepJS. |
| `subresource-check.mjs` | Answers "did the request happen at all", per fetch destination. Exits non-zero on a miss. Takes engine flags after `--`. |
| `collect-*.mjs` | Spawn the engine, run the four steps, write one JSON snapshot. |
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

**On a resumed connection the JA4 is now byte-for-byte Chrome's** —
`t13d1517h2_8daaf6152771_a87ad97598a9`, all three components. On a fresh
connection it is `t13d1516h2_8daaf6152771_806a8c22fdea`; the whole difference
is `pre_shared_key`, which only a resumed handshake carries, and which is a
connection-lifecycle question rather than a masking one (see below).


| | before | after | Chrome 150 |
|---|---|---|---|
| JA4, resumed connection | `t13d1711h2_5b57614c22b0_95ca0cbbc74b` | **`t13d1517h2_8daaf6152771_a87ad97598a9`** | `t13d1517h2_8daaf6152771_a87ad97598a9` |
| JA4, fresh connection | same | `t13d1516h2_8daaf6152771_806a8c22fdea` | — |
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
2. **`pre_shared_key` (41) is usually absent**, which is the whole difference
   between `t13d1516h2` and Chrome's `t13d1517h2`. Chrome resumed all four
   sampled connections; this build resumed one in eight, and when it does the
   JA4 prefix is `t13d1517h2` exactly. libcurl's session cache is configured
   correctly (`SSL_SESS_CACHE_CLIENT` plus a new-session callback, on a multi
   handle shared across the process), so this is a connection-lifecycle
   question rather than a masking gap — see the note below.

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

### Why `pre_shared_key` is usually missing (P9)

Traced to a single chain, every step of it read out of libcurl's own verbose
log (flip `ENABLE_DEBUG` in `src/network/http.zig`):

1. `tls.peet.ws/api/all` sends `GOAWAY` after every response, so the HTTP/2
   connection cannot be reused and the next request must open a new one.
2. On that new connection libcurl reuses the cached TLS session — the log says
   `SSL reusing session with ALPN 'h2'`, so session caching works.
3. The resumed handshake then fails most of the time:
   `TLS connect error: error:00000000:invalid library (0)` followed by
   `BoringSSL SSL_connect: SSL_ERROR_SYSCALL`. An empty error queue plus
   `SSL_ERROR_SYSCALL` means the peer closed the connection mid-handshake.
4. libcurl surfaces that to the caller as `SslConnectError` rather than
   retrying without the session, so the page sees `TypeError: fetch error`.
5. The failure evicts the session, so the next attempt does a full handshake
   and succeeds — which is why the failures alternate.

What this corrects about the earlier reading of the same symptom:

- **It is not "every other fetch to any HTTPS origin".** Of eleven origins
  tested across six CDNs, `/api/all` is the only one that fails, because it is
  the only one that forces a reconnect. Everywhere else the h2 connection is
  reused and no second handshake happens at all.
- **Sessions are not "never reused".** They are cached and reuse is attempted.
  `pre_shared_key` is rare for the opposite reason: connection reuse works, so
  there usually is no second handshake for a PSK to appear on.

Two things were ruled out by measurement rather than argued:

- **The ALPS/ECH info callback is not the cause.** With it disabled the resumed
  handshake still failed three times out of four.
- **The server is not simply flaky.** Chrome, over the same network path on the
  same machine, fetched `/api/all` twelve times with zero failures and
  `pre_shared_key` present on all twelve.

So a resumed ClientHello from this build is rejected where Chrome's is
accepted, and that is as far as the evidence goes. Going further needs a packet
capture, and this machine routes through a local tunnel — libcurl reports the
peer as `198.18.2.217` and the local address as `198.18.0.1`, both inside the
`198.18.0.0/15` fake-IP range — so the capture has to be taken somewhere that
tunnel is not in the path.

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

P6 moves nothing in the first four rows, which is the expected result: the
transport layer is invisible to a script, so a change there should leave the JS
surface untouched. It is listed to show it caused no regression.

The remaining 31 probe keys are enumerated in `after-p6-vs-chrome.md`; the
per-layer sections above say which are deliberate (`hardwareConcurrency`,
`deviceMemory`), which are missing APIs (`RTCPeerConnection`, `AudioContext`,
`speechSynthesis`), and which are known gaps with a measured cost.
