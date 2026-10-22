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

The same port also serves MCP (`/mcp`), for agents that drive a page step by
step (goto, click, fill, page through...); see [MCP](#mcp-mcp).

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
`crawl-data` volume on `/data` for session cookies and the request history.

The build compiles the engine (ReleaseFast) and needs ~12 GB of RAM; a cold
build downloads Rust, Zig, a prebuilt V8 (~130 MB from GitHub) and the
crates and Zig packages. The Dockerfile header lists the mirror build-args and
how to hand in V8 and the Zig packages from the host instead
(`--build-context v8=… / zigpkg=…`). It needs BuildKit (`docker buildx`).

Inside the container, `tini` is PID 1 and `entrypoint.sh` starts:

- `lightpanda serve` on `127.0.0.1:9222` — the CDP port is not exposed. When
  the engine exits it is restarted after `LP_RESTART_DELAY` seconds;
  requests in flight fail with `engine_disconnected`, queued ones wait for it.
  The engine and this restart loop run under `setsid`, in a process group of
  their own, so `docker stop`'s SIGTERM reaches only the service, which ends
  the engine itself once the crawls in flight are done (see
  [Stopping](#stopping)).
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
| `HISTORY_DIR`                  | `/data/history`    | where the request history is kept (see [History](#request-history)) |
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
| `HISTORY_DIR`        | (none: no history)      | directory for the request history, one file per UTC day and replica (see [Request history](#request-history)) |
| `HISTORY_RETENTION_DAYS` | `7`                 | days of history kept, today included; older files are deleted at startup and hourly. `0` keeps everything |
| `HISTORY_REPLICA`    | the hostname (in a container: its id) | this process's part of the history file names, so replicas sharing a volume never write the same file |
| `MCP_PROCS`          | `0` (the image: `2`)    | engine `lightpanda mcp` processes the service starts for `/mcp`; `0` turns `/mcp` off. Each runs one tool call at a time (see [MCP](#mcp-mcp)) |
| `MCP_MAX_SESSIONS`   | `32`                    | MCP sessions at once; `initialize` beyond it is a 503 |
| `MCP_SESSION_IDLE_MS`| `1800000` (30 min)      | an MCP session with no call for this long is closed; `0` never |
| `MCP_CALL_TIMEOUT_MS`| `120000`                | longest wait for the engine's answer to one MCP request (then 504) |
| `SHUTDOWN_DRAIN_MS`  | `5000`                  | on SIGTERM/SIGINT, longest wait for the `/crawl` requests in flight to finish; those still running then are abandoned (see [Stopping](#stopping)) |
| `SHUTDOWN_PARTIAL_MS`| `1000`                  | time an abandoned crawl's page gets to hand over a partial result |
| `SHUTDOWN_SAVE_MS`   | `5000`                  | on SIGTERM/SIGINT, longest wait for the open MCP sessions bound to a `session_id` to write their cookies back (alongside the drain) |
| `SHUTDOWN_ENGINE_MS` | `1000`                  | after the drain, time the engines get to exit on SIGTERM before SIGKILL |
| `SHUTDOWN_HISTORY_MS`| `1000`                  | last, time the history's queued lines get to reach the disk |
| `MCP_PROXY`          |                         | one proxy URL for all MCP browsing (the engine's `--http-proxy`) |
| `MCP_BASE_PORT`      | `9300`                  | first loopback port of the MCP processes (one each, consecutive) |
| `LP_BIN`             | `/bin/lightpanda`       | the engine binary the MCP processes run |

There is no authentication; the service, its admin page included, is meant
for an internal network.

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
| 503  | `shutting_down`       | the service is stopping: a request sent then, one still queued for a slot, or one still running after `SHUTDOWN_DRAIN_MS` (with `partial`, as after a timeout); see [Stopping](#stopping) |
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

An MCP session can share a jar too: see `?session_id=` under
[MCP](#mcp-mcp).

## `DELETE /sessions/:id`

Drops a session's cookie jar; see [Sessions](#sessions).

## `GET /sessions`

The sessions there are, most recently used first (`?limit=`, default 200):

```json
{ "total": 2, "sessions": [
  { "id": "shop-login-1", "lastUsed": "2026-10-22T00:19:17.618Z", "expiresAt": "2026-10-29T00:19:17.618Z", "cookies": 4, "domains": ["shop.example"], "loaded": true }
] }
```

Cookie values are never listed. `expiresAt` is `null` with `SESSION_TTL_MS=0`;
`loaded` says whether the jar is held in memory (otherwise it is only on disk).

## MCP (`/mcp`)

`/mcp` is an MCP Streamable HTTP endpoint (JSON responses; `GET` is 405, no
event stream). Each `initialize` gets a browser of its own, driven with the
engine's MCP tools (`goto`, `click`, `fill`, `press`, `scroll`,
`waitForSelector`, `markdown`, `extract`, `evaluate`, ...); the page stays
between calls, as with Playwright. Chinese guide with client configuration:
[README.zh-CN.md](README.zh-CN.md#agent-接入mcp).

```bash
claude mcp add --transport http crawl http://crawl.internal:8080/mcp
```

How it is put together (`lib/mcp.mjs`):

- The service starts `MCP_PROCS` `lightpanda mcp --port` processes on
  loopback, with `--no-webmcp` and a clean environment (no `LP_*`: the
  engine's `getEnv` tool would hand them to the agent), and restarts one that
  exits. `mcp --port` cannot share a process with `serve`: it and
  `--cdp-port` each need the main thread for their accept loop
  (`src/main.zig`).
- One engine `mcp` process runs all of its sessions' tool calls on one
  thread, one at a time: measured, a goto that waited 4 s for a slow page
  held a second session's goto of a fast page for 3.8 s. So sessions are
  spread over the processes (fewest sessions first) and stay on theirs; with
  `MCP_PROCS=2` the same pair took 21 ms for the fast page while the slow one
  loaded.
- Sessions are minted by the service on `initialize`, as random ids. A
  request without `Mcp-Session-Id` (other than `initialize`) is a 400 rather
  than the engine's shared `default` session; an unknown id is a 404, which
  tells an MCP client to initialize again. The engine's `session_new`,
  `session_list`, `session_close` (list, join or close other agents'
  sessions) and `save` (writes a file in the container) are left out of
  `tools/list` and refused, and so are `cookies_import` / `cookies_export`,
  which the service uses itself (below).
- Calls to one session are forwarded one at a time. After `goto`, `click`
  and `press` the service asks the engine for the page URL (`getUrl`), so
  the history shows where a click led.
- Idle sessions are closed after `MCP_SESSION_IDLE_MS`; Claude Code's
  `claude -p` does not send `DELETE` when it ends. A process that dies takes
  its sessions with it: they answer 404 and the history gets a
  `session_lost` line.
- `MCP_PROXY` is the only proxy: the engine's MCP tools take none, so there
  is no per-session proxy and no pool.
- `GET /mcp/sessions` lists the live sessions (bound `session_id`, process,
  created, last call, calls, current URL); `/health` has an `mcp` block.
- `/mcp?session_id=<id>` on `initialize` binds the MCP session to the
  `/crawl` [session](#sessions) `<id>`, so a login made on either side holds
  on the other (put the query in the client's URL:
  `claude mcp add --transport http crawl 'http://crawl.internal:8080/mcp?session_id=shop-login-1'`).
  The jar's cookies, HttpOnly ones included, go into the new browser through
  the engine's `cookies_import` MCP tool. From then on the two are kept in
  sync both ways, the jar being the reference and the browser its copy:
  - Out: the browser's cookies (`cookies_export`) are merged back into the
    jar by the rules above, against what this MCP session last synced: after
    every tool call, before its answer goes out — so a `/crawl` sent after the
    agent saw its login click succeed already has the login — and once more
    when the session ends (`DELETE`, idle, or the service stopping), for what
    page scripts set after the last call. An unchanged jar is not rewritten.
  - In: before every tool call, if anyone else (a `/crawl`, or another MCP
    session bound to the same `session_id`) changed the jar since this
    session last synced, the browser is brought to the jar: cookies added or
    changed there are imported, and cookies the jar no longer has are
    removed from the browser (imported already expired). A login made with
    `/crawl` while the agent works is there at its next step, and so is a
    logout. Whether the jar changed is one in-memory version comparison: with
    no change there is no extra engine call.
  - Conflicts: when both sides changed the same cookie (name, domain, path),
    the change that reached the jar last wins, as between two crawls. The
    browser's changes reach the jar at the end of each call, and changes a
    page script made between calls at the start of the next one (the pull
    writes them out first) — so a page script and a `/crawl` changing the same
    cookie after the session's last call is won by the page script.
  Measured on bt with 21 cookies in the jar (median of 200 calls,
  two rounds): with the jar unchanged a call costs what it did with
  write-back only (`getUrl` 1.62/2.55 → 1.67/2.24 ms, small-page `goto`
  9.05/12.30 → 10.17/9.26 ms, within the machine's noise); with a `/crawl`
  changing one cookie before every call, the pull adds 1.1–1.9 ms to
  `getUrl` and 2.1–2.2 ms to `goto`. An engine process that dies loses only what changed since
  the session's last call. The binding is fixed at `initialize`.
- On SIGTERM/SIGINT (`docker stop`) the service refuses new `/mcp`
  requests (503), lets every bound session finish its call in flight, writes
  its cookies back one last time and persists them, then exits — at most
  `SHUTDOWN_SAVE_MS` (5 s) for that, alongside the `/crawl` drain, all inside
  `docker stop`'s default 10 s (see [Stopping](#stopping)). It logs `mcp cookies saved on shutdown`
  (sessions, saved, timedOut, ms). The MCP engine processes run in a process
  group of their own so that the signal tini forwards to the service's group
  does not end them before that write-back.
  Measured on bt: a cookie a page script set after the last call was in the
  jar after `docker stop` and a new container (stop took ~0.6 s, the
  write-back 5–6 ms, exit code 0); with the previous image it was lost.
  History lines of a bound session carry its `session_id`, so
  `GET /history?session_id=<id>` lists the jar's crawls and MCP calls
  together. Without `session_id` an MCP session starts from no cookies and
  nothing is written anywhere, as before.

The pages carry no WebMCP surface: `typeof navigator.modelContext`,
`ModelContext` and `ModelContextClient` are `"undefined"` (the engine's `mcp`
command adds all three unless given `--no-webmcp`). The same page opened
through `/crawl` and through MCP sent the same 14 request headers and the
same `navigator.userAgent` / `webdriver` / `plugins` / `languages`.

Measured on bt (2026-10-22): `claude -p` (Sonnet 5.5) over an SSH tunnel to
the container's `/mcp`, told only to find the next-page control and page to
the end, collected all 25 items of a 5-page link-paged list (clicking
`a.next` four times when told to click; otherwise reading the page links and
opening each) and all 20 of a 4-page ajax list (`click #next` then `extract`,
three times), 13–18 s each.

## Paging

Three ways, from least to most code: give the task to an agent over MCP; for
ajax paging (the next-page button swaps the list, the URL stays) loop over
the clicks inside one `/crawl` request's `js`; for link paging (a URL per
page) loop in the caller, each `js` returning the page's items and the next
page's link, with one `session_id` so cookies carry over. Both `/crawl`
recipes are in [README.zh-CN.md](README.zh-CN.md#翻页) and run in
`test/run.mjs` (section 19). The ajax loop shares the request's one
`timeout`; each link-paged request is a fresh browser context in which only
cookies carry over (via `session_id`).

## Request history

With `HISTORY_DIR` set (the image sets `/data/history`), every `POST /crawl`
— finished, failed, timed out, or rejected with 400 — and every MCP tool call adds one JSON line to
`HISTORY_DIR/crawl-YYYY-MM-DD.<replica>.jsonl` (the UTC date). The same line
goes to stdout. It records what happened, never the page itself:

```json
{"time":"2026-10-22T00:18:56.217Z","kind":"crawl","url":"http://172.17.0.1:41879/slow-load","finalUrl":"http://172.17.0.1:41879/slow-load","status":504,"code":"timeout","message":"request exceeded its 1500ms timeout (...)","pageStatus":200,"ms":1504,"queueMs":0,"proxyMode":"direct","proxy":null,"proxiesTried":0,"session_id":null,"formats":["html","markdown","meta"],"htmlBytes":null,"markdownBytes":null,"partial":{"source":"dom","htmlBytes":147,"markdownBytes":36},"replica":"6f0888d64ad7"}
```

| field | meaning |
|---|---|
| `time` | when the response went out |
| `url`, `finalUrl` | the requested URL and the main document's final URL (after redirects; `location.href` when `meta` was asked for). Passwords in URLs are replaced by `***` |
| `status`, `code`, `message` | this service's HTTP status, the error `code` (`null` on success) and its message |
| `pageStatus` | the main document's HTTP status, when it arrived (also after a timeout) |
| `ms`, `queueMs` | total time, and time spent waiting for a slot |
| `proxyMode`, `proxy`, `proxiesTried` | `direct` / `pool` / `url`; the last proxy used, password replaced by `***`; how many pool proxies the request tried |
| `session_id`, `formats` | as requested |
| `htmlBytes`, `markdownBytes` | UTF-8 size of the returned `html` / `markdown`, `null` when not returned |
| `partial` | after a timeout with `partial`: its `source` and the sizes of what it carried |
| `replica` | which process wrote it |
| `kind` | `crawl` or `mcp`; lines from before the field existed are crawls |

An MCP line has the same fields (`null` where they don't apply) plus `tool`
(also `session_start`, `session_end`, `session_lost`), `mcp_session`,
`mcp_process`, `args` (short arguments such as a selector; long strings
clipped, `fill` values reduced to their length) and `resultBytes`. Its `url`
is the call's `url` argument or the page the call started on, `finalUrl` the
page after it; `code` is `tool_error` (the tool's message in `message`),
`timeout` (a `goto` that did not reach load), `rpc_error` or `engine_error`.

What it costs, through the service on small pages (`list.html`, the A/B
runs of `bench/profile/ab.sh` against the image without history, same
engine binary, 3 runs each): writing the files costs nothing measurable
(16 slots: 723 / 716 / 750 pages a second with history, 718 / 726 / 731 with
`HISTORY_DIR` unset); the fuller line itself (sizes, final URL, proxy) costs
3–4% at 16 slots, where the one Node core is the limit (726 against 760),
and up to 2% at 64 (1,078 against 1,103), after the response is encoded
once instead of measured and then encoded.

Lines are queued and appended once a second, so writing never holds up a
response; a failed write is logged on stderr and counted in `/health`
(`history.writeErrors`), and the request is not affected. Replicas that share
a volume (compose's `crawl-multi`) each write their own files and every
replica's `GET /history` reads all of them. Files of days older than
`HISTORY_RETENTION_DAYS` are deleted at startup and every hour.

A line is about 0.4 KB (376 bytes on average over 116,000 lines of a
small-page benchmark; longer URLs and error messages make it longer), so the
disk it takes follows the request rate: 10 requests a second is ~0.3 GB a
day, a container kept at its small-page ceiling (~700 a second with 16
slots) ~23 GB a day.

### `GET /history`

```
GET /history?url=shop.example&code=timeout,navigation_failed&since=2026-10-21T00:00:00Z&limit=50
```

| parameter | meaning |
|---|---|
| `url` | substring of `url` or `finalUrl`, case-insensitive |
| `status` | HTTP statuses of this service, comma-separated (`200,504`) |
| `code` | error codes, comma-separated; `ok` matches successes |
| `session_id` | exact; also matches an MCP line's `mcp_session` |
| `kind` | `crawl` or `mcp` |
| `since`, `until` | ISO time or milliseconds since the epoch |
| `days` | without `since`: how many days back to read, today included (default 3) |
| `limit` | 1–1000, default 100 |

Newest first: `{ "enabled": true, "entries": [...], "scanned": { "files", "lines", "unreadable" }, "from": "..." }`.
The files of the days covered are read line by line, newest day first, until
`limit` matches are found; a query over days of a busy container takes a
while (it reads every line of those days), so narrow it with `since` / `days`.
Without `HISTORY_DIR` the answer is `{ "enabled": false, "entries": [] }`.

## Admin page

`GET /` serves a page (Chinese; one static file, no external resources) with:

- the live status, from `/health` every 3 s: slots busy / idle / queued,
  reconnects, each pool proxy and whether it is ejected, sessions, history,
  the MCP processes and the live MCP sessions,
- the request history with the filters above; a row opens the full line,
- a form to try a crawl (formats, `js`, proxy, `session_id`, `timeout`,
  `waitUntil`) showing the result and its `meta`,
- the session list, with delete.

## `GET /health`

```json
{
  "ok": true,
  "stopping": false,
  "pool": { "size": 4, "busy": 1, "connected": 3, "queued": 0, "reconnects": 0 },
  "proxies": {
    "size": 2, "active": 1, "maxFails": 3, "retryAfterMs": 60000,
    "proxies": [
      { "proxy": "http://user:***@10.0.0.1:3128", "state": "active", "uses": 41, "ok": 40, "failed": 1, "consecutiveFails": 0, "lastError": "..." },
      { "proxy": "socks5://10.0.0.2:1080", "state": "ejected", "retryInMs": 42000, "uses": 3, "ok": 0, "failed": 3, "consecutiveFails": 3, "lastError": "proxy socks5://10.0.0.2:1080 failed: CouldntConnect (https://...)" }
    ]
  },
  "sessions": { "persisted": true, "dir": "/data/sessions", "ttlMs": 604800000, "stored": 30, "loaded": 12, "saves": 340, "writeErrors": 0, "expired": 4, "deleted": 1, "lastSweep": "2026-10-21T11:48:28.299Z" },
  "history": { "enabled": true, "dir": "/data/history", "replica": "6f0888d64ad7", "retentionDays": 7, "written": 38, "queued": 0, "writeErrors": 0, "dropped": 0, "lastError": null, "removedFiles": 0, "lastSweep": "2026-10-22T00:16:11.890Z" }
}
```

While the service is stopping, `/health` answers **503** with `"ok": false`
and `"stopping": { "signal": "SIGTERM", "since": "…", "phase": "draining", "inFlight": 2 }`
(`phase` goes `draining` → `stopping engines` → `writing history`), so a load
balancer checking it takes the instance out at once.

`proxies` is `null` when no pool is configured. In `sessions`, `stored` is the
number of sessions there are (on disk, or in memory without `SESSION_DIR`),
`loaded` the ones held in memory, `expired` / `deleted` count since startup.
In `history`, `written` counts lines since startup, `queued` the ones not yet
on disk, `dropped` lines lost because the disk stayed unwritable (the queue
is capped at 100,000), `removedFiles` files deleted for age.

## Stopping

On SIGTERM or SIGINT (`docker stop`, `docker compose down`, Ctrl-C):

1. **At once:** `/health` answers 503 with `stopping`; a new `/crawl` gets
   503 `shutting_down` and a new `/mcp` request 503; every answer from then
   on closes its connection. Requests still **queued** for a browser slot
   fail at once with 503 `shutting_down` too: they have not started, so a
   client can send them to another instance right away instead of waiting
   out the drain only to be refused at its end.
2. **Drain, up to `SHUTDOWN_DRAIN_MS` (5 s):** the `/crawl` requests in
   flight run on. Those still running when it is up are **abandoned**: the
   page gets `SHUTDOWN_PARTIAL_MS` (1 s) to hand over what it has, and the
   answer is 503 `shutting_down` with `partial`, exactly as after a timeout
   (see [Timeouts and partial results](#timeouts-and-partial-results)).
   Their session cookies are saved as usual. At the same time the MCP
   sessions bound to a `session_id` write their cookies back (up to
   `SHUTDOWN_SAVE_MS`, 5 s).
3. **Engines, up to `SHUTDOWN_ENGINE_MS` (1 s):** SIGTERM to the `serve`
   engine's process group and the MCP engines, SIGKILL to whatever is left.
4. **History, up to `SHUTDOWN_HISTORY_MS` (1 s),** then exit code 0.

Every request refused or abandoned has its history line, `code`
`shutting_down`, the reason in `message` (`…sent while stopping`, `…still
queued…`, `…still running after SHUTDOWN_DRAIN_MS…`) and, for an abandoned
one, the partial result's size. The log has a `stopping` line at the signal
and a `stopped` line before exit (requests refused from the queue, crawls in
flight and abandoned, whether the engine had to be killed, each phase's ms).

With the defaults the worst case is 5 + 1 (+0.5 slack) + 1 + 1 = 8.5 s,
inside `docker stop`'s default 10 s grace; a stop with nothing in flight
takes well under a second. To let longer crawls finish, raise
`SHUTDOWN_DRAIN_MS` **and** the grace period with it, keeping the grace
above `max(SHUTDOWN_DRAIN_MS + SHUTDOWN_PARTIAL_MS + 500, SHUTDOWN_SAVE_MS) +
SHUTDOWN_ENGINE_MS + SHUTDOWN_HISTORY_MS` plus a second or so: for 30 s
crawls, `SHUTDOWN_DRAIN_MS: 30000` with `stop_grace_period: 35s` in compose
(`docker stop -t 35`, `docker run --stop-timeout 35`). The service logs a
warning at startup when the sum is above 9.5 s. Past the grace Docker sends
SIGKILL, and whatever is still in flight is cut off without an answer or a
history line.

Measured on bt (`lp-crawl:drain`, `service/test/docker-test.sh`): with POOL_SIZE 3, three crawls in flight
and one queued when `docker stop` started: the queued one got 503
`shutting_down` 135 ms later; a 3 s page finished 2.5 s into the stop with
its full answer (200); a new request and `/health` 0.7 s in got 503; two
pages that never finish loading were abandoned at 5.14 s with their partial
result (one with the DOM it had, 147 bytes of html); an MCP call in flight
finished at 2.0 s and its session's cookies were written back; the engine
exited on SIGTERM in 52 ms; `docker stop` took 5.57 s, exit code 0. With
nothing in flight it took 0.6 s. With `SHUTDOWN_DRAIN_MS=12000` and
`docker stop -t 15`, a 10 s page finished (200 at 10.1 s) and the stop took
10.2 s, exit code 0. With the previous image (`lp-crawl:mcpsync`), the same
3 s crawl and a never-finishing one sent 0.5 s before `docker stop` got no
answer at all: their connections closed ~0.08 s after the signal, and the
container was gone 0.59 s after it.

Why the engine has its own process group: tini (PID 1, `-g`) forwards
`docker stop`'s SIGTERM to its child's whole process group. Before, the
`serve` engine was in that group and died with the service at once, so
every crawl in flight failed (with the previous image the service was gone
in ~0.6 s and the clients got no answer at all).

## Scaling

One container is one engine process and one Node process, and both have a
per-process ceiling (`service/bench/`, small pages, measured on a 512-core
host):

- the service tops out around 1,000–1,100 small pages a second (one Node
  core): 700–760 with `POOL_SIZE=16`, 930–1,050 with 32, 1,000–1,100 with 64,
- the engine alone (`bench.mjs --mode cdp`) is well above that: 1,250 / 2,100 /
  3,300 small pages a second at 16 / 32 / 64 connections, 1,500 / 2,900 / 4,800
  with the container on one NUMA node (see [NUMA](#numa)),
- heavy pages queue on the engine's shared HTTP connection pool unless it is
  raised, which the image does (`LP_HTTP_MAX_CONCURRENT=255`; with the
  engine's default of 40, 64 concurrent Wikipedia-sized loads ran at 16
  pages/s instead of 52).

So **add containers for more concurrency, not slots**: `POOL_SIZE=16` per
container, 32 where memory allows (a quarter to a half more small pages a
second for twice the memory), and no more: past 32 the Node process is the
limit and a slot adds memory, not throughput. Four containers of 16 served
2,500–2,600 small pages a second where one container of 64 served 800.

Budget per slot, by the pages crawled:

| page | engine memory per slot | CPU per busy slot |
|---|---|---|
| small (~35 KB, a script and a stylesheet) | ~20 MB | ~1 core (the page's thread plus V8's background threads) |
| large (a ~400 KB Wikipedia article, CPU-bound) | ~85 MB | ~1 core |

and give each container `--cpus` of at least 1.3 × `POOL_SIZE`: below that,
CFS throttling costs more than the cores taken away (16 slots on 16 cores lost
27% on small pages; on 8 cores large pages ran at 6 pages/s instead of ~9).

The small-page memory is V8 heap the engine no longer collects after every
crawl. It used to ask V8 for a full GC each time a crawl's browser context
closed, which kept a slot at ~6 MB but cost every small page about a third
of its CPU time (18 → 11 ms at 16 slots, 17 → 12 ms at 64). V8 now collects
on its own schedule; the heap levels off (see [Memory](#memory)).

`compose.yaml` has a `crawl-multi` service (profile `multi`) that runs
`CRAWL_REPLICAS` copies of the container on a range of host ports; put any
HTTP load balancer in front of them:

```bash
CRAWL_REPLICAS=4 CRAWL_PORTS=8081-8084 docker compose -f service/compose.yaml --profile multi up -d crawl-multi
```

The replicas share the `crawl-data` volume; each writes its own history files
(named after its container id), and any replica's `GET /history` shows them all.

Sessions are per process: a replica keeps the jars it has loaded in memory, so
send all requests of one `session_id` to the same replica (hash on it in the
load balancer), or the replicas will each have their own copy of it.

### NUMA

On a host with more than one NUMA node, pin each container to the cores of one
node. A container left free spreads its threads over every node, where they
share V8's process-wide locks and the process's memory map across sockets
(the likely cause; not measured directly). Pinned, the same container served
(pages a second, same time window, 2 × 128-core EPYC host):

| | 16 | 32 | 64 |
|---|---|---|---|
| engine alone (`--mode cdp`) | +23% | +36% | +47% |
| through the service | −8% | +12% | +10% |

Through the service at 16 slots the Node process is the limit either way; the
gain is in the engine and grows with the slots. Find the nodes' cores with
`lscpu | grep NUMA` or `/sys/devices/system/node/node*/cpulist`, then give
each container one node (`docker run --cpuset-cpus`, or `CRAWL_CPUSET` in
`compose.yaml`). With replicas, run one compose project per node:

```bash
for n in 0 1; do
  CRAWL_CPUSET=$(cat /sys/devices/system/node/node$n/cpulist) CRAWL_REPLICAS=2 \
  CRAWL_PORTS=808$((2 * n + 1))-808$((2 * n + 2)) \
    docker compose -f service/compose.yaml -p crawl-node$n --profile multi up -d crawl-multi
done
```

Each project gets its own `crawl-data` volume, which is fine: sessions are per
replica anyway.

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

Since the engine stopped forcing a GC after every crawl (see
[Scaling](#scaling)), V8 keeps more heap per slot, and it levels off. Same
host, one container per row in the same 70-minute window, then 10 idle
minutes, engine RSS:

| load | before | now | now, glibc |
|---|---|---|---|
| small pages only, 8 slots, `--cpus 12` (10-minute means over 70 min) | 94–96 MB | 185–189 MB | – |
| small pages: pages served / a second | 2.18 M / 522 | 2.61 M / 624 | – |
| mixed, 16 slots, `--cpus 24` (mean and range, 30–70 min) | 778 MB (561–1,026) | 938 MB (781–1,179) | 2,094 MB (1,754–2,376) |
| mixed, after 10 idle minutes | 256 MB | 298 MB | 1,547 MB |

On small pages the engine went from 185 to 189 MB over 2.6 million pages
(0.4 bytes a page); the mixed load's 10-minute means stayed within 900–962 MB
with no trend. jemalloc is still the right allocator: glibc holds more than
twice as much and gives little back, and with 64 connections on one NUMA node
it served 3,735 small pages a second against jemalloc's 4,945 (at 16, 1,492
against 1,528).

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
and restarting the engine, pages stuck in script, the request history (fields,
redacted proxies, filters, retention at startup, surviving a restart), the
admin page (served, no external resources), `GET /sessions`, MCP (the
processes' flags, no WebMCP surface on the page, link and ajax paging clicked
to the end, two concurrent sessions neither waiting on nor seeing each other,
cookie isolation, `MCP_PROXY` with credentials, refused session tools,
400/404/405, `/mcp/sessions`, the history lines and filters, a killed MCP
process, `DELETE`), stopping (`docker stop` with crawls in flight: the
finished one's full answer, the abandoned ones' partial results, the queued
and new ones refused, `/health` 503, the history lines, an MCP session's
cookies written back, exit code 0 within 10 s) and the two `/crawl` paging
recipes. Against the container it
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
diagnosis (against local test proxies), the session store (cookie merge,
TTL, delete) and the history (daily files per replica, failed writes,
retention, query filters) and the MCP gateway (routing, sessions, hidden
tools, idle sweep, history; against fake engine MCP servers) without an engine.
