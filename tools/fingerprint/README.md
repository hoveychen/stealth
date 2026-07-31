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
