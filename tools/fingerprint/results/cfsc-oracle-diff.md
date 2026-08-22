# cf-scrapingcourse, first divergence against a passing oracle (E1, 2026-08-22)

Three arms, one sitting, one address, `antibot-sweep --only cf-scrapingcourse`.
lightpanda is `dev.852+39c26410a`; the Chrome arms are Chrome 151.

| arm | verdict | doc | nodes | title | snapshot |
|---|---|---|---|---|---|
| Chrome `--headless=new --headed-ua` | **pass** | 403→200 | 34 | `Cloudflare Challenge - ScrapingCourse.com` | `cfsc-oracle.json` |
| Chrome `--headless=new` | cf-challenge | 403→200 | 47 | `Just a moment...` | `cfsc-headless-control.json` |
| lightpanda | cf-challenge | 403→200 | 47 | `Just a moment...` | `cfsc-lightpanda.json` |

So the target is live and diffable today: the oracle still clears it, and this
engine still does not. Traced arms, same verdicts reproduced, are
`cfsc-oracle-trace.json` and `cfsc-lightpanda-trace.json`.

**This engine already sends the headed UA, and still lands where headless
Chrome lands.** That is worth stating plainly, because the 2026-08-22 sweep
above this file attributes eight of fifteen stations to that one token. Here it
is not the token — the h1 and h2 request surfaces are byte-exact against Chrome
as of `f59fc2a7f` — so whatever this guard reads, it reads later.

## The first divergence is the second `fo/` POST

Both arms walk the same opening, request for request:

```
GET  /cloudflare-challenge                                  403
GET  /cdn-cgi/challenge-platform/h/b/orchestrate/chl_page/v1  200
     blob: script
GET  challenges.cloudflare.com/turnstile/v0/b/<v>/api.js?onload=…&render=explicit  200
POST /cdn-cgi/challenge-platform/h/b/fo/2851973148:…         200   <- telemetry, round 1
     blob: script
GET  challenges.cloudflare.com/…/turnstile/f/av0/rch/…       200
```

Then they part, and the POST bodies say where:

| | oracle | lightpanda |
|---|---|---|
| `fo/` round 1 | `www.scrapingcourse.com/…/fo/2851973148:…`, **2306** bytes | same host, same id, **2306** bytes |
| `fo/` round 2 | **`www.scrapingcourse.com`**/…/fo/**2851973148**:…, **8759** bytes | **`challenges.cloudflare.com`**/…/fo/**2058561374**:…, 4663 bytes |
| clearance | `POST /cloudflare-challenge`, 2605 bytes → **200, real page** | never sent |

Round 1 is the same size on both arms. Round 2 is not the same request at all:
the oracle posts a second, larger round to the **page-level** challenge
(`2851973148`, the id the interstitial was issued under) and is then handed the
clearance form to POST back at the document. This engine never returns to the
page-level challenge — it posts instead to the **Turnstile widget's own**
challenge instance (`2058561374`, on `challenges.cloudflare.com`) and stays
there.

So the escalation is the symptom: the page-level challenge did not accept round
1, the orchestrator fell back to the interactive widget, and everything after
that in this engine's trace is the widget grinding rather than the page clearing.

**Where to look next (E2).** The branch is taken after round 1's *response*, so
that response is the datum:

- The oracle's round-1 response is 32 825 bytes. This engine's is unmeasurable
  from the trace — `Network.dataReceived` is not emitted at all, so every
  `done` event reads `len: 0` (a known instrumentation gap, recorded in the
  synthetic-transfer section of the README). Fixing that, or reading the body a
  different way, is the prerequisite for comparing the two.
- Round 1's body is 2306 bytes on both arms, so the *amount* of telemetry
  matches. Its content does not have to.

## Two red herrings, checked and cleared

**`brunhild.challenges.cloudflare.com` → `CouldntResolveHost` is not ours.**
That host has **no A record**, only AAAA (`dig +short @8.8.8.8`:
`2606:4700::6812:1092` / `:1192`, and `host -t A` says "has no A record").
System `curl` on this machine fails the same way — `curl: (6) Could not resolve
host` — while `curl -6 https://cloudflare.com/` returns 301, so IPv6 itself
works here and the failure is name-specific and shared with plain curl, not
something this engine's resolver does differently. More to the point, the
oracle's trace contains **no request to that host at all**: it is on the
interactive-widget branch, downstream of the divergence above, so it cannot be
its cause.

**The `/pat/` 401 is not ours either.** Same reasoning: `…/h/b/pat/…` (a
Private Access Token probe) and `…/h/b/ci/…` appear only in this engine's
trace, i.e. only on the branch the oracle never enters.

Both are consequences of failing round 1, not candidate explanations for it.
Chasing either would repeat the mistake this file's parent section names — a
divergence found *after* the first divergence is not the first divergence.
