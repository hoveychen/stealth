# The Turnstile widget, narrowed to one request, 2026-08-21

The Cloudflare interstitial is the one row that has reproduced across every
sweep: 0/3, 403, and since the nonce fix the interstitial's own DOM is no longer
the difference (`antibot-2026-08-20-vs-chrome.md`, the re-run table — all three
challenge stations now render the 46 nodes headed Chrome renders). What is left
is that Turnstile never finishes, and the reading behind that was
`querySelectorAll('iframe')` empty at 20s.

## The iframe was a red herring

`turnstile-probe.mjs` serves the widget from a local page with Cloudflare's
published test sitekey (`1x00000000000000000000AA`, accepted on any hostname), so
the same question costs three seconds instead of thirty and Chrome answers it on
the same page. **Headless Chrome has no iframe either.** Both engines end with
`iframes: []`, one child in the container, and a `cf-chl-widget-<id>_response`
hidden input. So an absent iframe says nothing.

What differs is one field and one request.

| at | Chrome: container innerHTML / token | this engine |
|---|---|---|
| 1000ms | 95 chars / 0 | 95 chars / 0 |
| 3000ms | **125 chars / 21** | 95 chars / 0 |
| 6000ms | 125 / 21 | 95 / 0 |
| 12000ms | 125 / 21 | 95 / 0 |

At one second the two engines are byte-identical. Chrome then fills
`cf-turnstile-response` with a 21-character token; we never do.

## The request that never happens

```
both:      GET  http://127.0.0.1:<port>/
both:      GET  https://challenges.cloudflare.com/turnstile/v0/api.js
both:      GET  https://challenges.cloudflare.com/turnstile/v0/g/aae2b9a1c261/api.js
Chrome:    GET  https://challenges.cloudflare.com/cdn-cgi/challenge-platform/h/g/
                turnstile/f/av0/rch/17hgh/1x00000000000000000000AA/auto/fbE/new/normal?lang
this one:  — nothing
```

The loader and the inner implementation both fetch and both run. The widget's
`new/normal` call — the one that would come back with something to put in the
token — is never issued, and **nothing is logged**: no console output at all (17
INFO lines in the engine log, no warning, no error, no `worker`, no `blob`, no
CSP entry). On the real interstitial the same silence ends in Turnstile's own
`Cannot find Widget cf-chl-widget-…` after its 20s timer; here there is not even
that, because this page has no reload loop to restart it.

So the gap is inside the inner `g/aae2b9a1c261/api.js`, between it starting and
it deciding to ask for a challenge, and it fails without throwing.

## Where to go next

Unproven, in the order they are cheap to test:

1. **The call is not a plain `fetch`.** The real interstitial logged one
   `worker fetch error … blob:… err = Abort` in the same window (README). If the
   inner script bootstraps through a `blob:` Worker, our abort is the whole
   story — and this local page would need `--log_level debug` to show it, which
   this run did not use.
2. **A silent guard fails.** No throw and no log fits a feature test whose
   negative branch is "do nothing": something in `navigator`, a `crypto`
   surface, `performance` timing, an `Error.stack` shape, a `MessageChannel`.
   The 30 characters the container gains in Chrome are worth dumping verbatim
   first — they are the widget's own markup and may name the mode it chose.
3. **`--render explicit`** (the probe takes it) says whether the automatic
   `.cf-turnstile` scan is involved at all: explicit mode calls
   `turnstile.render()` directly and reports its return value.

Snapshots: `results/turnstile-chrome.json`, `results/turnstile-lightpanda.json`.
Re-run either with

```
node tools/fingerprint/turnstile-probe.mjs chrome     --settle 12000 --out results/turnstile-chrome.json
LP_BIN=$PWD/zig-out/bin/lightpanda \
node tools/fingerprint/turnstile-probe.mjs lightpanda --settle 12000 --out results/turnstile-lightpanda.json
```
