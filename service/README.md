# crawl service

A small HTTP service in front of one `lightpanda serve` process. It keeps a
pool of CDP connections to the engine — each connection gets its own worker
thread and browser inside the engine — and runs one crawl per connection at a
time. When every connection is busy, requests wait in a FIFO queue.

Node ≥ 22, no dependencies.

```bash
lightpanda serve --host 127.0.0.1 --port 9222 &
LP_CDP_URL=ws://127.0.0.1:9222/ POOL_SIZE=4 node service/server.mjs
```

Don't start the engine with `--obey-robots`, `--web-bot-auth-*` or `--webmcp`;
each of them identifies the client as a bot (see `AGENTS.md`).

## Docker

One image, one container: `lightpanda serve` built from this checkout plus
this service. Build from the repository root:

```bash
docker build -f service/Dockerfile -t lp-crawl .
docker run -d --name lp-crawl --restart unless-stopped -p 8080:8080 -e POOL_SIZE=8 lp-crawl
curl -s localhost:8080/crawl -d '{"url":"https://example.com/","formats":["markdown","meta"]}'
```

or `docker compose -f service/compose.yaml up -d --build` (`CRAWL_PORT` picks
the host port; see [Scaling](#scaling) for the multi-replica variant). The compose file puts the container on Docker's default
`bridge` network (`network_mode: bridge`) rather than a network of its own, so
it also starts on a daemon whose address pools are used up, and mounts the
`crawl-data` volume on `/data` for session cookies.

The build compiles the engine (ReleaseFast) and needs ~12 GB of RAM; a cold
build downloads Rust, Zig, a prebuilt V8 (~130 MB from GitHub) and the
crates and Zig packages. The Dockerfile header lists the mirror build-args and
how to hand in V8 and the Zig packages from the host instead
(`--build-context v8=… / zigpkg=…`). It needs BuildKit (`docker buildx`).

Inside the container, `tini` is PID 1 and `entrypoint.sh` starts:

- `lightpanda serve` on `127.0.0.1:9222` — the CDP port is not exposed. When
  the engine exits it is restarted after `LP_RESTART_DELAY` seconds;
  requests in flight fail with `engine_disconnected`, queued ones wait for it.
- the service on `0.0.0.0:8080`, pointed at that engine. If the service
  exits, the container exits and the restart policy brings it back.

Image environment, on top of the service variables above:

| variable                       | default            | meaning |
|--------------------------------|--------------------|---------|
| `POOL_SIZE`                    | `4`                | as above; see [Scaling](#scaling) for memory and CPU per slot |
| `LP_CDP_MAX_CONNECTIONS`       | `2*POOL_SIZE+4`    | engine connection cap. Keep it well above `POOL_SIZE`: after a timeout the service reconnects at once while the engine may still be tearing down the old connection |
| `LP_HTTP_MAX_CONCURRENT`       | `255`              | the engine's `--http-max-concurrent`: page loads in flight across *all* connections, 1–255 (the engine's own default is 40). Set it here, not as an extra argument |
| `LP_LOG_LEVEL`                 | `info`             | engine log level |
| `LP_RESTART_DELAY`             | `1`                | seconds before restarting a dead engine |
| `LP_MALLOC`                    | `jemalloc`         | the engine's malloc, `jemalloc` or `glibc` (see [Memory](#memory)); the Node service always uses glibc. With jemalloc, `MALLOC_CONF` defaults to `background_thread:true` |
| `SESSION_DIR`                  | `/data/sessions`   | where session cookie jars are kept; mount a volume on `/data` |
| `LP_HOST` / `LP_PORT`          | `127.0.0.1` / `9222` | where the engine listens inside the container |
| `LIGHTPANDA_DISABLE_TELEMETRY` | `true`             | telemetry is off whenever this variable exists, whatever its value; the engine logs `telemetry status disabled=true` at startup |

Arguments starting with `-` are appended to the `serve` command line
(`docker run lp-crawl --log-level debug`); anything else runs instead of the
service (`docker run --rm lp-crawl lightpanda version`).

## Configuration

| variable             | default                 | meaning |
|----------------------|-------------------------|---------|
| `LP_CDP_URL`         | `ws://127.0.0.1:9222/`  | the engine's CDP websocket (`http://` is accepted and rewritten) |
| `POOL_SIZE`          | `4`                     | concurrent crawls; must not exceed the engine's `--cdp-max-connections` (default 16). Memory and CPU per slot: see [Scaling](#scaling) |
| `QUEUE_MAX`          | `100`                   | requests allowed to wait for a slot; beyond that → 503 `queue_full` |
| `DEFAULT_TIMEOUT_MS` | `30000`                 | used when a request has no `timeout` |
| `MAX_TIMEOUT_MS`     | `120000`                | largest `timeout` a request may ask for |
| `HOST` / `PORT`      | `0.0.0.0` / `8080`      | where this service listens |
| `MAX_BODY_BYTES`     | `1048576`               | request body limit |
| `PARTIAL_GRACE_MS`   | `2000`                  | after a timeout, how long to try for the page's html/markdown so far (see [Timeouts](#timeouts-and-partial-results)); `0` turns it off |
| `PROXY_POOL`         |                         | proxy URLs for the pool, separated by commas, spaces or newlines |
| `PROXY_POOL_FILE`    |                         | a file of proxy URLs, one or more per line, `#` comments; added to `PROXY_POOL` |
| `PROXY_POOL_DEFAULT` | `false`                 | `true`: requests without a `proxy` field use the pool |
| `PROXY_MAX_FAILS`    | `3`                     | consecutive failures that eject a proxy from the pool |
| `PROXY_RETRY_AFTER_MS` | `60000`               | how long an ejected proxy sits out |
| `PROXY_POOL_RETRIES` | `2`                     | with `proxy: "pool"`, how many more pool proxies a request tries after its proxy fails (see [Pool](#pool)); `0` turns retries off |
| `PROXY_PROBE`        |                         | `host:port` (or a URL) every pool proxy should always be able to reach; used to tell a dead site from a dead proxy (see [Pool](#pool)) |
| `SESSION_DIR`        | (none: memory only)     | directory for session cookie jars, one `<session_id>.json` each |
| `SESSION_TTL_MS`     | `604800000` (7 days)    | a session not used for this long is dropped, file included; `0` keeps sessions forever |
| `SESSION_SWEEP_MS`   | `600000`                | how often expired sessions are cleaned up (also once at startup) |

There is no authentication.

## `POST /crawl`

```json
{
  "url": "https://example.com/",
  "formats": ["html", "markdown", "eval", "meta"],
  "js": "(async () => document.querySelectorAll('a').length)()",
  "timeout": 30000,
  "waitUntil": "load",
  "proxy": "http://user:pass@10.0.0.1:3128",
  "session_id": "shop-login-1"
}
```

| field       | required | meaning |
|-------------|----------|---------|
| `url`       | yes      | http or https |
| `formats`   | no       | any of `html`, `markdown`, `eval`, `meta`. Default `["html","meta"]`, plus `eval` when `js` is given |
| `js`        | for `eval` | a JavaScript **expression** evaluated in the page after it loads. A returned promise is awaited, so wrap statements in `(async () => { ... })()`. The value must be JSON-serialisable |
| `timeout`   | no       | milliseconds for the whole request, time spent queued included |
| `waitUntil` | no       | `load` (default), `domcontentloaded` or `networkidle` |
| `proxy`     | no       | a proxy URL (see [Proxies](#proxies)), `"pool"` for the next proxy from the pool, or `"direct"` / `null` for none. Omitted: `"direct"`, or `"pool"` when `PROXY_POOL_DEFAULT=true` |
| `session_id`| no       | 1-128 characters of `A-Za-z0-9._-`. Crawls with the same id share cookies (see [Sessions](#sessions)) |

The script runs before the HTML and markdown are captured, so it can change
the page (click, expand, scroll) and the snapshots will show the result.

### 200 response

Only the requested formats are present.

```json
{
  "url": "http://127.0.0.1:9790/redirect",
  "eval": { "value": 3 },
  "html": "<html><head><title>Fixture Home</title></head><body>...</body></html>",
  "markdown": "\n# Fixture Home\n\nStatic paragraph.\n- one\n...",
  "meta": {
    "url": "http://127.0.0.1:9790/index.html",
    "title": "Fixture Home",
    "status": 200,
    "statusText": "OK",
    "headers": { "content-type": "text/html; charset=utf-8", "set-cookie": "..." },
    "redirects": ["http://127.0.0.1:9790/redirect"],
    "cookies": [{ "name": "fixture_session", "value": "abc123", "domain": "127.0.0.1", "path": "/", "expires": -1, "httpOnly": false, "secure": false, "session": true, "size": 20 }],
    "timing": { "queueMs": 0, "navigateMs": 9, "totalMs": 88 }
  }
}
```

- `html` is `document.documentElement.outerHTML` after scripts ran.
- `markdown` comes from the engine's `LP.getMarkdown`.
- `eval` is `{ "value": ... }`, or `{ "error": "TypeError: ..." }` when the
  script threw — that is still a 200.
- `meta.url` is the page's final `location.href`; `status`, `statusText` and
  `headers` belong to the main document's final response (after redirects),
  and `redirects` lists the URLs that redirected to it. A 404 page is a
  successful crawl with `meta.status: 404`.
- `cookies` are all cookies the browser context holds at the end of the crawl.

### Errors

```json
{ "error": { "code": "timeout", "message": "request exceeded its 1500ms timeout (...)" } }
```

| HTTP | `code`                | when |
|------|-----------------------|------|
| 400  | `bad_request`         | invalid body |
| 404  | `not_found`           | `DELETE /sessions/:id` for a session that does not exist |
| 502  | `navigation_failed`   | the main document could not be fetched (DNS, refused, TLS, ...), also when the proxy is fine but cannot reach the site |
| 502  | `engine_disconnected` | the engine connection dropped mid-crawl |
| 502  | `cdp_error`           | the engine rejected a command |
| 502  | `proxy_failed`        | the proxy could not be used: unreachable, unresolvable, SOCKS handshake failed, or it refused the CONNECT |
| 502  | `proxy_auth_failed`   | the proxy rejected the credentials (or wanted some and got none) |
| 503  | `no_proxy_available`  | `proxy: "pool"` and every proxy in the pool is ejected |
| 503  | `queue_full`          | `QUEUE_MAX` requests already waiting |
| 503  | `engine_unavailable`  | could not connect to the engine before the deadline |
| 504  | `timeout`             | the deadline passed (queued, loading, or evaluating) |

Proxy error messages show the proxy with its password replaced by `***`.

### Timeouts and partial results

A request that runs out of `timeout` gets a 504. If it asked for `html` or
`markdown`, the service then spends up to `PARTIAL_GRACE_MS` more asking the
page for them as they are, and puts them in `partial`; what doesn't answer in
time is `null`. Only the requested ones are present, and there is no `partial`
when neither was requested. `partial.source` says what they are:

- `"dom"`: read from the page, as a finished crawl's `html` and `markdown`
  would be (scripts have run, the html is the serialized DOM).
- `"raw-body"`: the main document's body never finished arriving, so the page
  was never parsed; `html` is the body as far as it got, as source text
  (decoded with the charset the page would have been parsed with, possibly cut
  mid-tag), and `markdown` is made from that text without running any of its
  scripts or loading anything it refers to.
- `null`: nothing answered in time.

The response therefore comes at most
`timeout + PARTIAL_GRACE_MS` after the request (plus a few ms), and the
connection is dropped afterwards whatever happened.

```json
{ "error": { "code": "timeout", "message": "..." }, "partial": { "html": "<html>...</html>", "markdown": "# ...", "source": "dom" } }
```

What there is to get depends on where the page is stuck:

- loaded but the load event never comes (a script or other resource that
  never arrives, `waitUntil` that is never reached), or `js` that never
  settles: `partial` has the page as it is.
- the main document is still downloading: the engine parses it only once the
  whole body is in, so `partial` has what has arrived, with
  `source: "raw-body"`.
- the main document never answered: there is nothing yet, so `html` and
  `markdown` are `""` (the previous `about:blank`).
- a script that never yields (`for (;;) {}`), or a synchronous `<script src>`
  that never arrives: the engine answers no CDP command, so both are `null`.
  The engine's watchdog terminates the script after `--watchdog-ms` (30 s by
  default); until then that worker keeps one CPU core busy and holds one of
  the engine's connections, which is what the headroom in
  `LP_CDP_MAX_CONNECTIONS` is for. `docker run lp-crawl --watchdog-ms 10000`
  shortens it.

## Proxies

`proxy` (or a pool entry) is passed to the engine as `proxyServer` of
`Target.createBrowserContext`. It applies to that crawl's connection only —
every request, subresources included, goes through it — and is undone when the
context is disposed. Credentials go in the URL and are sent up front, on the
first request:

| proxy URL | works | checked with |
|-----------|-------|--------------|
| `http://host:port`, `http://user:pass@host:port` | yes: plain requests for `http://` pages, `CONNECT` tunnels for `https://` | test suite |
| `https://host:port` (TLS to the proxy) | yes with `--insecure-disable-tls-host-verification` (which turns verification off for every site too); with verification on, a self-signed proxy certificate fails with `PeerFailedVerification`. A CA-issued certificate should verify but has not been tried | by hand, self-signed |
| `socks5://[user:pass@]host:port` | yes; the engine resolves the target name itself | test suite |
| `socks5h://[user:pass@]host:port` | yes; the proxy resolves the name | by hand |
| `socks4://`, `socks4a://` | not verified, so rejected with a 400 | |

Characters in the username or password that are special in URLs (`@ : / %`)
must be percent-encoded.

A wrong password shows up two ways: a `http://` page through an HTTP proxy
loads the proxy's 407 page, and anything through `CONNECT` or SOCKS fails with
a generic connect error — the same error (`CouldntConnect`) the engine reports
for a proxy that is down, and for an `https://` site that is down behind a
proxy that is up. So after such an error the service asks the proxy itself,
with the same credentials, to open a tunnel to the same site:

| the proxy... | result | counted against a pool proxy |
|---|---|---|
| can't be connected to | `proxy_failed` | yes |
| rejects the credentials, or wants some | `proxy_auth_failed` | yes |
| refuses the tunnel, and opens one to `PROXY_PROBE` | `navigation_failed`: the site is down | no |
| refuses the tunnel, and also refuses `PROXY_PROBE` | `proxy_failed`: the proxy's own upstream is broken | yes |
| refuses the tunnel, and no `PROXY_PROBE` is set | `proxy_failed`, message says the site may be down | no |
| opens the tunnel fine this time | `proxy_failed`, transient | no |

When the service cannot tell, it does not charge the proxy: ejecting a good
proxy because one site is down would take it away from every other request,
while a bad proxy that is not ejected only costs a retry. Setting
`PROXY_PROBE` (any host:port the proxies can reach, e.g. a site you control)
removes most of the "can't tell" cases. The check takes at most 2 s, within
the request's `timeout`.

### Pool

`PROXY_POOL` and `PROXY_POOL_FILE` list the proxies. A request with
`"proxy": "pool"` gets the next proxy in round-robin order, skipping ejected
ones. Requests without `proxy` go direct unless `PROXY_POOL_DEFAULT=true`:
opting in per request means a request's network path never changes just
because a pool was configured, and the pool's failures never show up in
callers that didn't ask for it.

A crawl is a failure of its proxy when the proxy is down or rejects the
credentials (the "yes" rows above), and a success when the page was fetched
(any HTTP status). Timeouts and other errors count as neither. After
`PROXY_MAX_FAILS` consecutive failures a proxy is ejected for
`PROXY_RETRY_AFTER_MS`; then it is offered again, and a single further failure
ejects it again (a success resets the count).

A `"pool"` request whose proxy fails (any `proxy_failed` / `proxy_auth_failed`
row, charged or not) is run again on the next pool proxy it has not tried yet,
up to `PROXY_POOL_RETRIES` more times, on the same browser slot and within the
same `timeout` — the retries do not get time of their own. A site that is down
(`navigation_failed`) is not retried. When the retries run out, or no untried
proxy is left, the caller gets the last error, with the number of proxies
tried in the message. A request that names its proxy is never moved to
another one.

## Sessions

Crawls with the same `session_id` share a cookie jar. The jar is loaded into
the new browser context before the navigation (`Network.setCookies`) and
written back from it before the context is disposed (`Network.getAllCookies`),
after a timeout too when the page still answers. With `SESSION_DIR` set (the
image sets `/data/sessions`) every jar is also written to
`SESSION_DIR/<session_id>.json` before the response goes out, so it survives
a restart. Only cookies are kept, not localStorage or the cache.

A session not used by any crawl for `SESSION_TTL_MS` (7 days by default)
expires: its jar is dropped from memory and its file deleted, at startup and
every `SESSION_SWEEP_MS` after that, and a crawl that names it after the TTL
starts from an empty jar even before the sweep has run. "Used" means a crawl
with that `session_id` started or finished; on disk it is the file's mtime.
The default keeps the login of a job that comes back daily or weekly and still
stops one-off session ids from piling up. Individual cookies also expire on
their own `Expires`/`Max-Age`, as in a browser.

`DELETE /sessions/<session_id>` drops a session at once: `200
{"deleted": "<id>"}`, or `404` if there is none. A crawl on that session still
running at the time does not write its cookies back, so the session stays
gone; the next crawl that names it starts a new, empty one.

Two crawls on one session at the same time each start from the jar as it was,
and when each finishes its changes are merged in per cookie (name, domain,
path): cookies it set or changed are written, cookies it started with and no
longer has (the site deleted them, or they expired) are removed, and cookies
it left alone are not touched — so a change made by the other crawl in the
meantime survives. If both changed the same cookie, the one that finished
last wins.

## `DELETE /sessions/:id`

Drops a session's cookie jar; see [Sessions](#sessions).

## `GET /health`

```json
{
  "ok": true,
  "pool": { "size": 4, "busy": 1, "connected": 3, "queued": 0, "reconnects": 0 },
  "proxies": {
    "size": 2, "active": 1, "maxFails": 3, "retryAfterMs": 60000,
    "proxies": [
      { "proxy": "http://user:***@10.0.0.1:3128", "state": "active", "uses": 41, "ok": 40, "failed": 1, "consecutiveFails": 0, "lastError": "..." },
      { "proxy": "socks5://10.0.0.2:1080", "state": "ejected", "retryInMs": 42000, "uses": 3, "ok": 0, "failed": 3, "consecutiveFails": 3, "lastError": "proxy socks5://10.0.0.2:1080 failed: CouldntConnect (https://...)" }
    ]
  },
  "sessions": { "persisted": true, "dir": "/data/sessions", "ttlMs": 604800000, "stored": 30, "loaded": 12, "saves": 340, "writeErrors": 0, "expired": 4, "deleted": 1, "lastSweep": "2026-10-21T11:48:28.299Z" }
}
```

`proxies` is `null` when no pool is configured. In `sessions`, `stored` is the
number of sessions there are (on disk, or in memory without `SESSION_DIR`),
`loaded` the ones held in memory, `expired` / `deleted` count since startup.

## Scaling

One container is one engine process and one Node process, and both have a
per-process ceiling (`service/bench/`, measured on a 512-core host):

- the service tops out around 800–850 small pages a second (one Node core),
- the engine around 1,900 small pages a second, whatever `POOL_SIZE` is,
- heavy pages queue on the engine's shared HTTP connection pool unless it is
  raised, which the image does (`LP_HTTP_MAX_CONCURRENT=255`; with the
  engine's default of 40, 64 concurrent Wikipedia-sized loads ran at 16
  pages/s instead of 52).

So **add containers for more concurrency, not slots**: `POOL_SIZE=16` per
container, at most 32. Four containers of 16 served 2,500–2,600 small pages a
second where one container of 64 served 800.

Budget per slot, by the pages crawled:

| page | engine memory per slot | CPU per busy slot |
|---|---|---|
| small (~35 KB, a script and a stylesheet) | ~6 MB | ~1.3 cores (the page's thread plus V8's background threads) |
| large (a ~400 KB Wikipedia article, CPU-bound) | ~85 MB | ~1 core |

and give each container `--cpus` of at least 1.3 × `POOL_SIZE`: below that,
CFS throttling costs more than the cores taken away (16 slots on 16 cores lost
27% on small pages; on 8 cores large pages ran at 6 pages/s instead of ~9).

`compose.yaml` has a `crawl-multi` service (profile `multi`) that runs
`CRAWL_REPLICAS` copies of the container on a range of host ports; put any
HTTP load balancer in front of them:

```bash
CRAWL_REPLICAS=4 CRAWL_PORTS=8081-8084 docker compose -f service/compose.yaml --profile multi up -d crawl-multi
```

Sessions are per process: a replica keeps the jars it has loaded in memory, so
send all requests of one `session_id` to the same replica (hash on it in the
load balancer), or the replicas will each have their own copy of it.

### Memory

The engine runs on jemalloc (`LP_MALLOC=jemalloc`). glibc's malloc holds on to
what a busy engine freed: on a mixed load it sat at ~1.6 GB and kept 1.3 GB
after the load stopped, where jemalloc held about half and gave all but
~0.24 GB back. Measured on the 512-core host, one container per column in the
same time window (`service/bench/soak.sh`, `POOL_SIZE=16`, `--cpus 24`, 20
closed-loop workers, hn 50 / js 20 / wiki 15 / refused 5 / hang 4 / hangdoc 3 /
throw 3, 60 minutes, then 15 idle), engine RSS from `smaps_rollup`:

| | glibc | glibc, `MALLOC_ARENA_MAX=2` | jemalloc |
|---|---|---|---|
| under load, 30–60 min (mean, range) | 1,617 MB (1,392–1,819) | 1,142 MB (1,113–1,262) | 749 MB (574–1,071) |
| after 15 idle minutes | 1,315 MB | 1,078 MB | 238 MB |
| requests in 60 min | 154,798 | 157,172 | 154,011 |
| small pages a second, CPU-bound (8 slots, 12 cores) | 434.8 | 381.0 | 445.2 |
| Wikipedia-sized pages a second (same) | 8.5 | 8.6 | 8.2 |

`MALLOC_ARENA_MAX=2` saves less and costs 12% on small pages (16 threads
contending for two arenas). The memory does not grow with time on any of them:
the per-crawl leaks the soaks found are fixed (a ~56-byte record per wrapped
object with a finalizer, an inspector id per in-place first navigation, and 4–8
bytes V8 kept per forced GC), and on one reused connection 1.07 million small
pages over 40 minutes moved the engine from 96 to 94 MB (0.9 bytes a page,
against 184 before).

## How a crawl runs

Each request leases one connection, creates a fresh browser context on it
(`Target.createBrowserContext`, with the proxy if there is one), opens a page,
loads the session's cookies if it has a `session_id`, navigates, collects, and
disposes the context. Apart from those session cookies, nothing — storage,
cache — carries over from one request to the next.

If anything leaves the browser in an unknown state (timeout, dropped
connection, failed dispose), the connection is closed instead of reused, and
the next request on that slot reconnects. Connections are opened lazily and
retried with backoff until the request's deadline, so the service rides out an
engine restart: requests made while the engine is down wait for it (or fail
with `engine_unavailable` at their deadline).

## Test

```bash
LP_BIN=/path/to/lightpanda node service/test/run.mjs
```

Starts local fixture pages, test proxies (HTTP with and without a password,
SOCKS5), a `lightpanda serve` and this service on free ports, then checks all
four outputs, a redirect, a 404, a throwing script, bad input, a timeout, an
unreachable host, more concurrent requests than slots, per-request proxies
and their credentials, the pool's rotation, retry on the next proxy and
ejection, a dead site behind a good proxy (not charged to the proxy), session
cookies (across requests, concurrent requests, a service restart, `DELETE`,
and expiry after `SESSION_TTL_MS`), partial results after a timeout, killing
and restarting the engine, and pages stuck in script. Against the container it
also checks the engine's command line for `--http-max-concurrent`.
Use a ReleaseFast engine build; the Debug build in `zig-out` is about 3.5×
slower.

Against the container instead, on the Docker host:

```bash
service/test/docker-test.sh lp-crawl     # NAME, PORT, TEST_PROXY_BASE override the defaults
```

It starts the image with a test proxy pool and a session volume, serves the
fixture pages and proxies on the bridge gateway, runs `run.mjs` against it
(re-creating the container on the same volume for the restart check), and
removes the container and volume. The header of `run.mjs` lists what it needs
when you set it up by hand.

`node service/test/unit.mjs` checks the pool, the dead-proxy / dead-site
diagnosis (against local test proxies) and the session store (cookie merge,
TTL, delete) without an engine.
