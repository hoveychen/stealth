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

> **Correction (E2).** The two paragraphs above reach the right verdict —
> neither host is a cause — by the wrong argument. "The oracle's trace contains
> no request to that host at all" is false: the oracle requests `brunhild` and
> gets `net::ERR_NAME_NOT_RESOLVED`, and requests `/pat/` and gets 401, exactly
> as this engine does. They were invisible in E1 because the trace was taken
> without `--attach-frames`, so the Turnstile widget is an out-of-process iframe
> whose traffic never reached the trace. `cfsc-fo-diff.mjs` auto-attaches to
> child targets and both requests appear, flagged `frame: true`. The correct
> reason to clear them is the one that survives: they happen on **both** arms.

# E2 — the divergence, measured on both arms (2026-08-22)

`cfsc-fo-diff.mjs` reads the bodies with `Network.getResponseBody`, which both
engines implement (lightpanda captures every response body into the frame
arena, `CDP.zig:onHttpResponseData`), so the missing `Network.dataReceived` is
not on the critical path after all — E1's stated prerequisite was avoidable.
Snapshots: `cfsc-fo-oracle.json`, `cfsc-fo-oracle-hints.json`,
`cfsc-fo-lightpanda.json`, `cfsc-fo-lp-long.json`.

## E1's "demotion" framing was wrong: both arms enter the widget

With the widget's own target attached, the two arms walk the *same* path much
further than E1 could see. Neither is demoted; the interactive widget is simply
part of the managed-challenge flow on both.

| # | step | oracle | lightpanda |
|---|---|---|---|
| 1 | `GET /cloudflare-challenge` | 403 | 403 |
| 2 | `GET orchestrate/chl_page/v1` | 200 | 200 |
| 3 | `GET {cf} turnstile/…/api.js?onload` | 200 | 200 |
| 4 | `POST {sc} fo/2851973148` round 1 | 2306 | 2306 |
| 5 | `GET {cf} …/rch/…/new/normal` | 200 | 200 |
| 6 | `POST {cf} fo/2058561374` round 1 | 4706 | 4663 |
| 7 | widget probes: blob, `brunhild` (fails), `/pat/` 401, `/ci/` | yes | yes |
| 8 | `POST {cf} fo/2058561374` round 2 | **89 282** | **> 65 536** |
| 9 | round 2's response headers | **`cf-chl-out` + `cf-chl-out-s`** | **`cf-chl-gen`** |
| 10 | `POST {sc} fo/2851973148` round 2 | 8759 / 8770 | never |
| 11 | `POST /cloudflare-challenge` clearance | 2605 / 2626 → 200 real page | never |

**Step 9 is the divergence.** `cf-chl-out` / `cf-chl-out-s` is an *outcome* —
the widget's solve, ~6KB of it — and the page-level challenge turns it straight
into round 2 and then the clearance form. `cf-chl-gen` is another *program*:
the server declined the submission and issued more work. This engine fetches
that program (127 724 bytes), runs it — a fresh 291-byte blob appears after it,
so it does run — and then goes quiet.

**It is not slowness.** A 100-second settle (`cfsc-fo-lp-long.json`) produces a
byte-identical sequence: same steps, same sizes, same stop. The widget receives
its third program, executes it, and emits nothing further.

Step 8's size is the obvious next question and it is **not measured**: the
oracle posts 89 282 bytes, and lightpanda's is only known to exceed 65 536,
because `Network.requestWillBeSent` drops `postData` above
`network.max_post_data_size` — a hard-coded 64KB that ignores the
`maxPostDataSize` the client passed to `Network.enable` (`network.zig:40`,
`:480`; `CDP.zig:1053` skips the capture too, so `getRequestPostData` cannot
recover it either). Chrome honours the parameter. See sub-plan 2.

## An earlier divergence than any of the above: the client hints

Step 2 already differs, and E1 missed it because "the h1 and h2 request
surfaces are byte-exact against Chrome" was measured on a request nobody had
asked hints of. The challenge response asks:

```
cf-mitigated: challenge
accept-ch:   Sec-CH-UA-Bitness, Sec-CH-UA-Arch, Sec-CH-UA-Full-Version,
             Sec-CH-UA-Mobile, Sec-CH-UA-Model, Sec-CH-UA-Platform-Version,
             Sec-CH-UA-Full-Version-List, Sec-CH-UA-Platform, Sec-CH-UA,
             UA-Bitness, UA-Arch, … (the pre-standard spellings too)
critical-ch: (the same list)
```

`challenges.cloudflare.com` sends the identical pair on the widget frame. From
the request after the document onwards, the two arms carry different hint sets
on **every** same-origin request — `orchestrate`, the favicon, both `fo/`
POSTs, the clearance POST, and every asset of the cleared page:

| arm | document | everything after |
|---|---|---|
| oracle | 3 hints | **9 hints** |
| lightpanda | 3 hints | **3 hints** |

Cross-origin requests (google-analytics) correctly carry 3 on both, so this is
per-origin negotiated state, not a blanket header set.

`accept-ch-echo.mjs` serves Cloudflare's exact list off localhost and settles
the mechanism on all three arms:

- **Real headless Chrome** (`acceptch-chrome.json`) answers `Critical-CH` by
  **re-issuing the navigation at once** — two `GET /critical-ch`, the first
  with 3 hints, the second with 9 — and then carries 9 on every subsequent
  request to that origin, subresource and XHR alike. Values on this machine:
  `sec-ch-ua-arch: "arm"`, `-bitness: "64"`, `-model: ""`,
  `-platform-version: "26.3.1"`, `-full-version: "151.0.7922.172"`,
  `-full-version-list: "Not=A?Brand";v="99.0.0.0", "Google Chrome";v="151.0.7922.172", "Chromium";v="151.0.7922.172"`.
- **The oracle arm** (`acceptch-oracle.json`) does the same restart and sends
  all 9 names, but five of the six high-entropy values are the **empty
  string** — `--user-agent` detaches Chrome's hints from its UA. It still
  clears cf-scrapingcourse.
- **lightpanda** (`acceptch-lightpanda.json`) ignores both headers completely:
  3 hints everywhere, no restart, and no state carried to a later navigation.
- Chrome sends none of the pre-standard `UA-*` spellings despite the ask.

The oracle passing with **empty** hint values is the useful part of that
reading: whatever Cloudflare does with these, it is not reading the values. So
the implementable target is the *names* — cheap, and cheap to falsify.

On the real site the document itself is 3-hints-and-two-events on the oracle
(`cfsc-fo-oracle-hints.json`: two `requestWillBeSent` under one requestId, both
carrying 3) against one event on this engine. The restart is real but it did
not add hints there, so the delta that matters is the one in the table above.
