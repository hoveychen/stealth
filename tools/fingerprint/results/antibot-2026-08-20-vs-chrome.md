# The commercial guards, 2026-08-20

`antibot-sweep.mjs`, fifteen stations, both engines `--fresh` (one process per
station). Engine `1.0.0-dev.340+3d96734f2` against headed
`Chrome/151.0.7922.138`, same machine, same route, eight minutes apart —
egress `108.211.179.124` (AT&T residential, US, Cloudflare colo SJC).

Snapshots: `antibot-lightpanda.json`, `antibot-chrome-headed.json`.
Traces: `antibot-trace-lightpanda.json` (cf-scrapingcourse),
`antibot-trace-cf-claude.json`, `antibot-trace-cf-chatgpt.json`.

`verdict / nodes [document status]`. A status pair like `403→200` is the
interstitial followed by the page it let through.

| station | vendor | Chrome (headed) | this engine |
|---|---|---|---|
| cf-scrapingcourse | cloudflare | **pass** / 34n [403→200] | **cf-challenge** / 16n [403] |
| cf-nopecha | cloudflare | cf-challenge / 46n [403→200] | cf-challenge / 16n [403] |
| cf-zeroclover | cloudflare | cf-blocked / 66n [403→502] | cf-challenge / 16n [403] |
| cf-chatgpt | cloudflare | pass / 722n [200] | pass / **40n** [200] |
| cf-claude | cloudflare | pass / 1086n [200] | **empty-document** / 121n [200] |
| cf-indeed | cloudflare | pass / 1216n [200] | **pass** / 1211n [200] |
| cf-nowsecure | cloudflare | pass / 51n [200] | **pass** / 51n [200] |
| cf-discord | cloudflare | pass / 1196n [200] | **pass** / 1531n [200] |
| cf-pixiv | cloudflare | pass / 311n [200] | **error** — `Runtime.evaluate` timeout at 73s |
| dd-datadome | datadome | datadome-challenge / 9n [403→200] | pass / 2044n [200] |
| dd-g2 | datadome | datadome-challenge / 11n [403→200] | datadome-challenge / 11n [403→200] |
| dd-leboncoin | datadome | datadome-challenge / 9n [403→200] | datadome-challenge / 1438n [200] |
| dd-hermes | datadome | datadome-challenge / 10n [403→200] | pass / 2042n [200] |
| x-sony | unattributed | pass / 1355n [200] | pass / 1535n [200] |
| x-zillow | unattributed | pass / 1607n [200] | pass / 1868n [200] |
| | | **9/15** | **8/15** |

**The pass counts are not the finding and should not be quoted as one.** Two of
the fifteen stations measure nothing about either engine, and four measure
something that moved between two runs of the same real Chrome. What the table is
for is the six rows that reproduced.

## What reproduced

**A Cloudflare managed challenge is not passed, and the reason is ours.** All
three stations that serve one — scrapingcourse, nopecha, zeroclover — leave this
engine on the interstitial, 403, sixteen nodes, `Just a moment...`, in both the
first sweep and the `--fresh` re-run. The engine's own log names the cause on the
scrapingcourse trace:

```
http : script blocked by csp
url = https://www.scrapingcourse.com/cdn-cgi/challenge-platform/h/g/orchestrate/chl_page/v1?ray=…
```

Cloudflare's interstitial sends
`script-src 'nonce-v4r3E9xWYvR93f3o09vl4E' 'unsafe-eval' https://challenges.cloudflare.com`
— no `'self'`, no `'strict-dynamic'` — and injects its own loader with the nonce
set on the element:

```js
var a = document.createElement('script');
a.nonce = 'v4r3E9xWYvR93f3o09vl4E';
a.src = '/cdn-cgi/challenge-platform/h/g/orchestrate/chl_page/v1?ray=…';
```

The nonce is the only source expression that admits that URL. `Csp.zig` treats a
`'nonce-…'` source as inline-only (the comment at its head says so: "never match
a URL … they apply to inline scripts"), so the same-origin loader matches nothing
and is refused. The challenge script never runs, so nothing is ever posted back,
so the interstitial never clears — the four wire events on that station are the
document, its 403, the favicon and its 200, and nothing else.

**This is not a fingerprint verdict.** Cloudflare had not yet run a line of its
own detection code when we refused to load it. Whether the fingerprint would
survive the challenge is unmeasured, and cannot be measured until the nonce is
honoured.

**The same bug costs a real app its page.** claude.ai serves 200 and this engine
renders an empty document (121 nodes, no text) because
`assets-proxy.anthropic.com/claude-ai/v2/assets/v1/index-CVGzhryG.js` — the main
bundle — is blocked by the same rule. Chrome renders the 1086-node sign-in page.
So the F4 note that "every one of those simplifications is in the
more-permissive direction, so none of them can break a page a real browser would
run" is falsified, twice, and by the stricter-direction choices rather than the
permissive ones.

**Cloudflare without a challenge is passed.** indeed (1211 against Chrome's
1216), discord (1531 against 1196) and nowsecure (51 against 51) all serve this
engine their real page. indeed is the one worth naming: it answers a bare curl
with `403` + `cf-mitigated: challenge` and answers this engine with the site, so
Cloudflare's passive scoring — the part that reads the TLS hello, the header set
and the JS surface — is being passed on a production site. That is the
transport-and-navigator work from P3–P6 doing exactly what it was for.

**pixiv wedges the engine.** 73s, then `Runtime.evaluate` times out and the page
never answers again; reproduced in both sweeps, and in `--fresh` mode where it is
the only station in its process, so it is not the cascade the first run mistook
it for. Chrome reads pixiv's real page in 15s. Unattributed.

**chatgpt.com is a different failure from claude.ai.** No CSP block; the app
logs `[GSI_LOGGER]: FedCM get() rejects with Error: W` and posts its own
`client-fatal-error`, then renders a 40-node `Application Error!` page. Chrome
gets 722 nodes. A missing federated-credential surface, not a guard verdict.

## What did not reproduce, and is therefore not attributed

**The four DataDome stations say nothing about the engine yet.** The control
moved between two runs on the same route twenty-five minutes apart: the first
sweep's Chrome passed datadome.co, leboncoin and hermes and was challenged only
at g2; the `--fresh` re-run's Chrome was challenged at all four. The engine's
column moved less (it passes datadome.co and hermes in the re-run) which reads
flattering and means nothing — when the control is unstable, a column beside it
cannot be read as a verdict about the client. What differs between the two runs
is a cold profile per station and twenty-five more minutes of requests from one
address, and neither was isolated. Repeated runs, alternating engine order,
would be the way to make this column say something.

**cf-zeroclover's origin is down.** Chrome solves the challenge and gets a 502
from the site behind it, so `pass` is unreachable there for anybody. It stays on
the list, the way the two dead `arh.antoinevastel.com` endpoints stay on the
detector list, so a future run notices if it comes back.

**cf-nopecha is an interactive challenge.** Headed Chrome is still on
`Just a moment...` after 25s, having got a 200 for something. It is a captcha
demo; nothing here auto-solves it, and the engine failing it is not a datapoint
separate from the CSP one above.

## Two harness faults this sweep found in itself

**A wedged station used to take every station after it.** The first run had
pixiv time out and then reported six DataDome and unattributed stations as
`Page.navigate` timeouts that were never attempted — six clean-looking refusals,
entirely manufactured. `--fresh` gives each station its own process and is what
the numbers above were taken with. This is the same class of fault the
detector-sweep header describes from the other direction, and it produced a
plausible wrong answer on the first try again.

**`_cf_chl_opt` and the challenge-platform script are not evidence of a block.**
The first verdict rule counted them, and scored two served pages as challenges:
headed Chrome reads pixiv's real page with both marks set, and chatgpt serves the
script to this engine while serving Chrome a page without it. Cloudflare's JS
detections ride along on ordinary pages. The rule now turns on the interstitial's
own title and DOM, or a document that never stops being a 4xx; the marks are
still recorded, as `jsDetect`.

## Re-run after the two crash fixes, eight hours later

Same script, same fifteen stations, same route — egress `108.211.179.124`, SJC,
seven minutes apart. Engine `1.0.0-dev.664+8fc2ac1d0` (the pixiv bounds guard,
the PerformanceObserver delivery loop, the CSP nonce fix and the 295-commit
upstream merge are all in) against headed `Chrome/151.0.7922.172`.

| station | vendor | Chrome (headed) | this engine |
|---|---|---|---|
| cf-scrapingcourse | cloudflare | **pass** / 34n [403→200] | cf-challenge / 46n [403] |
| cf-nopecha | cloudflare | cf-challenge / 46n [403→200] | cf-challenge / 46n [403] |
| cf-zeroclover | cloudflare | cf-blocked / 66n [403→502] | cf-challenge / 46n [403] |
| cf-chatgpt | cloudflare | pass / 725n [200] | pass / 491n [200] |
| cf-claude | cloudflare | pass / 1086n [200] | **pass** / 1066n [200] |
| cf-indeed | cloudflare | pass / 1207n [200] | pass / 1208n [200] |
| cf-nowsecure | cloudflare | pass / 51n [200] | pass / 51n [200] |
| cf-discord | cloudflare | pass / 1196n [200] | pass / 1531n [200] |
| cf-pixiv | cloudflare | pass / 311n [200] | **pass** / 311n [200] |
| dd-datadome | datadome | datadome-challenge / 9n [403→200] | pass / 2044n [200] |
| dd-g2 | datadome | datadome-challenge / 11n [403→200] | datadome-challenge / 11n [403→200] |
| dd-leboncoin | datadome | datadome-challenge / 9n [403→200] | datadome-challenge / 1488n [200] |
| dd-hermes | datadome | datadome-challenge / 10n [403→200] | pass / 2042n [200] |
| x-sony | unattributed | pass / 1355n [200] | pass / 1535n [200] |
| x-zillow | unattributed | pass / 1608n [200] | pass / 1866n [200] |
| | | **9/15** | **10/15** |

### What moved, and what it is worth

**The two crashes are gone from the scoreboard.** pixiv reads 311 nodes, which is
Chrome's 311 exactly; claude.ai reads 1066 against Chrome's 1086. Those were the
`error` and `empty-document` rows above. Both are `results/engine-wedge.md`.

**chatgpt.com went 40n → 491n**, against Chrome's 725n. It renders now rather than
serving `Application Error!`; it is still not the whole page, and the gap has not
been attributed.

**The Cloudflare interstitial is now rendered the way Chrome renders it, and still
not solved.** All three challenge stations read 46 nodes where they used to read
16 — the same 46 headed Chrome reads on nopecha. So the interstitial's own DOM is
no longer the difference; the 403 that never becomes a 200 still is. This is the
one row that has reproduced across every sweep, and it is the open question the
Turnstile widget note in the README belongs to.

**Chrome's column reproduced almost exactly**, eight hours and one Chrome patch
release apart: 34/46/66 on the challenges, 1086 on claude, 51 on nowsecure, 1196
on discord, 311 on pixiv, all four DataDome stations challenged, 1355 and 1608 on
sony and zillow. That is what makes the deltas above readable as ours rather than
as the route's.

**10/15 against Chrome's 9/15 is not a claim that this engine beats Chrome**, and
should not be quoted as one. The whole of that lead is DataDome serving
datadome.co and hermes.com to us and challenging headed Chrome — a policy
difference about the client it thinks it is talking to, on a residential IP,
which is the one thing on this table nobody here controls. The CF managed
challenge is still 0/3 for us and 1/3 for Chrome, and that is the row that
measures us.
