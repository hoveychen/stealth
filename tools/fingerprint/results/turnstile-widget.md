# The Turnstile widget, narrowed to two of our own bugs, 2026-08-20

The Cloudflare interstitial is the one row that has reproduced across every
sweep: 0/3, 403, and since the nonce fix the interstitial's own DOM is no longer
the difference (`antibot-2026-08-20-vs-chrome.md`, the re-run table — all three
challenge stations now render the 46 nodes headed Chrome renders). What is left
is that Turnstile never finishes, and the reading behind that was
`querySelectorAll('iframe')` empty at 20s.

## What the local page measures

`turnstile-probe.mjs` serves the widget from a local page with Cloudflare's
published test sitekey (`1x00000000000000000000AA`, accepted on any hostname), so
the same question costs three seconds instead of thirty and Chrome answers it on
the same page. What differs is one field and one request.

| at | Chrome: container innerHTML / token | this engine |
|---|---|---|
| 1000ms | 95 chars / 0 | 95 chars / 0 |
| 3000ms | **125 chars / 21** | 95 chars / 0 |
| 6000ms | 125 / 21 | 95 / 0 |
| 12000ms | 125 / 21 | 95 / 0 |

At one second the two engines are byte-identical. Chrome then fills
`cf-turnstile-response` with a 21-character token; we never did.

```
both:      GET  http://127.0.0.1:<port>/
both:      GET  https://challenges.cloudflare.com/turnstile/v0/api.js
both:      GET  https://challenges.cloudflare.com/turnstile/v0/g/aae2b9a1c261/api.js
Chrome:    GET  https://challenges.cloudflare.com/cdn-cgi/challenge-platform/h/g/
                turnstile/f/av0/rch/17hgh/1x00000000000000000000AA/auto/fbE/new/normal?lang
this one:  — nothing
```

Two readings from that run pointed the wrong way and are worth naming, because
both are artefacts of the probe rather than facts about the widget.
`querySelectorAll('iframe')` came back empty on **both** engines, which read as
"the iframe is a red herring"; and the engine log looked silent, which read as
"a guard fails without throwing". The first is the closed shadow root below. The
second was the probe: it subscribed to `Runtime.consoleAPICalled` and
`Log.entryAdded` but not `Runtime.exceptionThrown`, so an uncaught throw would
not have shown up at all. (It now does — and there is no throw either way.)

## It was the iframe after all — two of our own bugs

None of the three guesses that run produced survived. There is no `blob:` Worker
anywhere near this: the inner script contains the strings `Worker` and `Blob`
zero times, and a `--log_level debug` run logs no worker, no blob, no CSP line.
The 30 characters Chrome's container gains are not widget markup either — they
are one attribute, ` value="XXXX.DUMMY.TOKEN.XXXX"`, so the two DOMs are
byte-identical apart from the token.

The iframe was never absent. The widget does
`dt.attachShadow({mode:"closed"})` and appends the iframe *there*, which is why
`querySelectorAll('iframe')` reads empty in headless Chrome too. Patching
`Element.prototype.attachShadow` to force every root open (`--open-shadow`)
makes both engines answerable, and then our side says it plainly: the iframe is
built, it is connected, its `src` **attribute** is the right `new/normal` URL —
but `iframe.src` reads back empty and no request is ever made.

A seven-case insertion matrix pinned it to two independent defects. Chrome
fires all seven; we fired four.

| how the frame gets its src | Chrome | before | after |
|---|---|---|---|
| append, then `setAttribute('src')` | ✓ | **✗** | ✓ |
| `setAttribute('src')`, then append | ✓ | ✓ | ✓ |
| `.src =`, either order | ✓ | ✓ | ✓ |
| shadow root, `setAttribute`, then connect host | ✓ | **✗** | ✓ |
| shadow root, `.src =`, then connect host | ✓ | **✗** | ✓ |
| connected host, then append into its shadow root | ✓ | ✓ | ✓ |

1. **`setAttribute('src')` was not a navigation trigger**, and did not resync
   `IFrame._src`, so `.src` read back empty as well. `Build.attributeChange`
   handled `srcdoc` and not `src`.
2. **The walk that starts loads for a newly connected subtree never entered
   shadow trees.** An iframe appended to a *detached* shadow root stayed
   unloaded when its host was connected — the widget's exact shape.

The widget uses `setAttribute` *and* the detached-shadow-root shape, so it hit
both. With both fixed it issues `new/normal` and fills `cf-turnstile-response`
with a 21-character token at the same 3s mark Chrome does. Regression tests:
`frames/src_attribute.html`, `frames/shadow_root_iframe.html`.

## On the real interstitial: one step forward, door still shut

The local page uses Cloudflare's always-pass test key, so a token there proves
the plumbing and nothing about the verdict. Against the three real managed-
challenge stations the honest reading is that **the pass rate did not move**:

| | site document | widget document | verdict |
|---|---|---|---|
| before (`antibot-lightpanda.json`) | 403 | *never loaded* | cf-challenge |
| after | 403, 403, 403 | 200, 200, 200 | cf-challenge |
| headless Chrome, same window | 403 | 200 | cf-challenge |

Read the sweep's `doc=403->200` line carefully: that 200 is the *widget iframe*,
not the site. The site answers 403 every time, and the interstitial now runs its
reload loop instead of hanging, which is why there are three attempts where
there used to be one.

So the fix is necessary and it closes a real gap — we now do on this page exactly
what headless Chrome does — but it is not what stands between us and these three
stations, because **headless Chrome fails them identically**. The "Chrome 1/3"
figure this plan started from was *headed* Chrome; whatever headed Chrome has
that headless lacks is the next question, and it is not the Turnstile widget.

Snapshots: `results/turnstile-chrome.json`, `results/turnstile-lightpanda.json`,
the forced-open pair `results/turnstile-{chrome,lightpanda}-shadow.json`, and the
station run `results/turnstile-t4-{lightpanda,chrome}.json`. Re-run with

```
node tools/fingerprint/turnstile-probe.mjs chrome     --settle 12000 --out results/turnstile-chrome.json
LP_BIN=$PWD/zig-out/bin/lightpanda \
node tools/fingerprint/turnstile-probe.mjs lightpanda --settle 12000 --out results/turnstile-lightpanda.json
```

`--open-shadow` forces every shadow root open, `--log-level debug` turns up the
engine log, and `--render explicit` swaps the implicit `.cf-turnstile` scan for a
direct `turnstile.render()`.
