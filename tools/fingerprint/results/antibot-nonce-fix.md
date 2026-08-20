# What honouring the nonce changed, 2026-08-20

Engine `1.0.0-dev.343+62df3f9fc` (the nonce fix) against the same nine
Cloudflare stations, same route, same day as
`antibot-2026-08-20-vs-chrome.md`. Snapshots:
`antibot-nonce-cf-lightpanda.json`, and the traced single stations
`antibot-nonce-scrapingcourse.json` (25s) and `antibot-nonce-75s.json` (75s).

| station | before the fix | after the fix | headed Chrome |
|---|---|---|---|
| cf-scrapingcourse | 403, **16n**, script blocked | 403, **46n**, challenge runs and POSTs | pass, 34n |
| cf-nopecha | 403, 16n | 403, 46n | still on the interstitial at 25s |
| cf-zeroclover | 403, 16n | 403, 46n | 502 from the origin behind it |
| cf-chatgpt | 40n `Application Error!` | **491n, the real page** | 722n |
| cf-claude | empty document, 121n | **the app runs, and the engine wedges** | 1086n |
| cf-indeed | pass, 1211n | pass, 1211n | 1216n |
| cf-discord | pass, 1531n | pass, 1531n | 1196n |
| cf-nowsecure | pass, 51n | pass, 51n | 51n |
| cf-pixiv | wedges the engine | wedges the engine | pass, 311n |

## The challenge now runs, and Cloudflare now sees us

The whole conversation happens, where before there were four wire events:

```
GET  /cloudflare-challenge                                   403
GET  /cdn-cgi/challenge-platform/h/g/orchestrate/chl_page/v1  200   <- was blocked
GET  challenges.cloudflare.com/turnstile/v0/g/…/api.js        200
POST /cdn-cgi/challenge-platform/h/g/fo/2768214011:…          200   <- the result, submitted
```

So the fix did what it was for: Cloudflare's challenge code loads, runs,
collects, and posts back. **That is the first time this engine has been
evaluated by it at all.**

## And the verdict is still not what stops us

The interstitial does not clear, and the reason is in Cloudflare's own console
output rather than in its verdict:

```
Turnstile Widget seem to have hung:  etjo7
[Cloudflare Turnstile] Cannot find Widget cf-chl-widget-etjo7, consider using
turnstile.remove() to clean up a widget.
```

After that the page reloads and starts over, every ~20s, indefinitely. A 75s
settle reads exactly what a 25s settle reads — 46 nodes, `Just a moment...` —
so this is not slowness.

Dumping the interstitial's DOM at 20s says what is missing:

| | |
|---|---|
| `window.turnstile` | `object` |
| ids present | `cf-chl-widget-95gxv_response` (its hidden `cf-turnstile-response` input) |
| the widget container | **absent** |
| `document.querySelectorAll('iframe')` | **empty** |
| `getElementById` round-trip on what does exist | works |

Turnstile creates its response field and then never gets its widget container
and iframe into the document, so its own later lookup for
`cf-chl-widget-<id>` fails and it declares itself hung. The engine logs one
`worker fetch error … blob:… err = Abort` in the same window, and a
`frame : navigate … reason = initialFrameNavigation type = frame`, so a frame is
being created and something about it does not survive.

**So what Cloudflare thinks of this engine's fingerprint is still unmeasured.**
The blocker moved from "we refuse to load its script" to "its widget cannot
build itself here", and the second one has a name and a reproduction now, which
the first one also needed before it could be fixed. Nothing in the readings
above is Cloudflare declining us.

## Two other stations moved, one of them the wrong way

**chatgpt.com renders the real page**, 491 nodes against 40. Not attributed: the
trace taken before the fix logged no CSP block on that host, so the cause may be
the nonce fix reaching a script that trace did not capture, or the site serving
something different — Chrome itself read 514 nodes on one run and 722 on
another. Improved, cause not isolated.

**claude.ai got worse in a more interesting way.** Its main bundle
(`assets-proxy.anthropic.com/…/index-*.js`) was the CSP-blocked script that left
the page empty; it loads now, the application runs, and the engine stops
answering `Runtime.evaluate` after 86s. So the page went from blank-and-quick to
real-and-wedged. That is the same shape as pixiv, which wedges before and after
this fix and is unrelated to CSP, so there is now a second instance of one
unattributed engine hang rather than one.

**indeed, discord and nowsecure are unchanged**, which is the check that
matters against over-permissiveness: honouring a nonce did not turn into
ignoring the policy. The `WebApi: CSP script-src` test — the rebrowser shape,
where an un-nonced cross-origin insertion must fire `error` — still passes, and
`csp_nonce.html` pins the three refusal cases (no nonce, wrong nonce,
case-folded nonce) alongside the one acceptance.
