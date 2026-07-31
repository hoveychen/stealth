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
| `collect-*.mjs` | Spawn the engine, run the four steps, write one JSON snapshot. |
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

Two engine-level gaps also show up in the capture and are not header bugs:
stylesheets and images are **never requested at all** (no `/asset.css`,
`/asset.png`, `/favicon.ico` hit the server), and a client that never fetches
CSS or images is trivially separable from a browser server-side.

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
