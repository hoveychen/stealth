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

## Configuration

| variable             | default                 | meaning |
|----------------------|-------------------------|---------|
| `LP_CDP_URL`         | `ws://127.0.0.1:9222/`  | the engine's CDP websocket (`http://` is accepted and rewritten) |
| `POOL_SIZE`          | `4`                     | concurrent crawls; must not exceed the engine's `--cdp-max-connections` (default 16). Budget ~50 MB of engine memory per slot |
| `QUEUE_MAX`          | `100`                   | requests allowed to wait for a slot; beyond that → 503 `queue_full` |
| `DEFAULT_TIMEOUT_MS` | `30000`                 | used when a request has no `timeout` |
| `MAX_TIMEOUT_MS`     | `120000`                | largest `timeout` a request may ask for |
| `HOST` / `PORT`      | `0.0.0.0` / `8080`      | where this service listens |
| `MAX_BODY_BYTES`     | `1048576`               | request body limit |

There is no authentication.

## `POST /crawl`

```json
{
  "url": "https://example.com/",
  "formats": ["html", "markdown", "eval", "meta"],
  "js": "(async () => document.querySelectorAll('a').length)()",
  "timeout": 30000,
  "waitUntil": "load"
}
```

| field       | required | meaning |
|-------------|----------|---------|
| `url`       | yes      | http or https |
| `formats`   | no       | any of `html`, `markdown`, `eval`, `meta`. Default `["html","meta"]`, plus `eval` when `js` is given |
| `js`        | for `eval` | a JavaScript **expression** evaluated in the page after it loads. A returned promise is awaited, so wrap statements in `(async () => { ... })()`. The value must be JSON-serialisable |
| `timeout`   | no       | milliseconds for the whole request, time spent queued included |
| `waitUntil` | no       | `load` (default), `domcontentloaded` or `networkidle` |

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
| 502  | `navigation_failed`   | the main document could not be fetched (DNS, refused, TLS, ...) |
| 502  | `engine_disconnected` | the engine connection dropped mid-crawl |
| 502  | `cdp_error`           | the engine rejected a command |
| 503  | `queue_full`          | `QUEUE_MAX` requests already waiting |
| 503  | `engine_unavailable`  | could not connect to the engine before the deadline |
| 504  | `timeout`             | the deadline passed (queued, loading, or evaluating) |

## `GET /health`

```json
{ "ok": true, "pool": { "size": 4, "busy": 1, "connected": 3, "queued": 0, "reconnects": 0 } }
```

## How a crawl runs

Each request leases one connection, creates a fresh browser context on it
(`Target.createBrowserContext`), opens a page, navigates, collects, and
disposes the context. Nothing — cookies, storage, cache — carries over from one
request to the next.

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

Starts local fixture pages, a `lightpanda serve` and this service on free
ports, then checks all four outputs, a redirect, a 404, a throwing script,
bad input, a timeout, an unreachable host, more concurrent requests than slots,
and killing and restarting the engine. Use a ReleaseFast engine build; the
Debug build in `zig-out` is about 3.5× slower.
