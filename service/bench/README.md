# crawl service concurrency benchmark

Measures how throughput and latency of the crawl service (and of the engine
behind it) change with the number of concurrent crawls. Everything runs on the
Docker host: the scripts read the container's cgroup and the engine's
`/proc/<pid>` for CPU and memory.

| file          | what it does |
|---------------|--------------|
| `site/`       | test pages: `hn.html` (34 KB + one script and one stylesheet, ~15 ms a load) and `wiki.html` (a 395 KB Wikipedia article, ~0.9 s a load, CPU-bound) |
| `site/` origin | snapshots: the Hacker News front page and Wikipedia's "Web browser" article (CC BY-SA 4.0), taken 2026-10-21 |
| `pagesrv.mjs` | serves `site/` from memory with a large listen backlog |
| `bench.mjs`   | closed-loop load generator: `-c` workers each crawl one page after another, either through the service (`--mode service`, `POST /crawl`) or straight over CDP with the service's own pool/crawl code (`--mode cdp`) |
| `sweep.sh`    | one fresh container per (tier, mode, page) run, so memory readings don't carry over |
| `multi.sh`    | the same concurrency split over K containers |
| `report.mjs`  | JSON lines → markdown tables |
| `soak.mjs`    | long-running memory soak: a closed-loop mix of request classes (small/large pages, scripts, scripts that throw, timeouts, refused connections, `Event`-heavy pages) through `POST /crawl`, sampling the container cgroup, the engine's `smaps_rollup`, threads, fds, `/metrics`, the Node service's RSS and `/health` reconnects every `--sample` seconds; `idle` phases stop the load and keep sampling |
| `soak.sh`     | one container + `soak.mjs` in the background (`NAME`, `POOL`, `CPUS`, `MIX`, `PHASES`, `IMAGE`, `SERVICE_ENV`) |
| `soak-report.mjs` | soak samples → markdown tables and per-phase slopes (MB per 1,000 requests over the second half of each load phase) |
| `soak-chart.mjs` | soak samples → inline SVG charts (RSS against time and against requests) |

```bash
# on the Docker host, from service/bench
node pagesrv.mjs 172.17.0.1 29790 8 &        # bridge gateway: reachable from containers
node bench.mjs --mode http --url http://172.17.0.1:29790/wiki.html -c 64   # page server alone
OUT=default.jsonl REPEATS=2 sh sweep.sh
OUT=hc255.jsonl REPEATS=2 ENGINE_ARGS="--http-max-concurrent 255" sh sweep.sh
OUT=multi.jsonl sh multi.sh 4 16 hn --http-max-concurrent 255
node report.mjs default.jsonl hc255.jsonl multi.jsonl

# memory soak: a mixed load for 2.5 h, then idle, then load again
NAME=lp-crawl-c-mixed POOL=16 CPUS=24 C=20 PHASES=load:150m,idle:20m,load:30m OUT=mixed.jsonl sh soak.sh
# one request class per container (see the class list at the top of soak.mjs)
NAME=lp-crawl-c-hn POOL=8 CPUS=12 C=8 MIX=hn=1 PHASES=load:150m,idle:20m OUT=hn.jsonl sh soak.sh
node soak-report.mjs mixed.jsonl hn.jsonl
```

Soak readings:

- **Read RSS from `smaps_rollup`, not `/proc/<pid>/status`.** Since Linux 6.2
  `VmRSS` is a per-CPU counter read without summing; on a 512-core host it
  is off by tens of MB (tini reads 0, the engine 16 MB while it holds 64 MB).
- **`pagesrv.mjs` never answers `/hang`**, which is how `soak.mjs` makes
  timeouts (`hang.html` loads a script from it, `hangdoc` is the document itself).

Things that made earlier readings wrong:

- **One load-generator process tops out around 1,000–1,200 small crawls a
  second.** With `--procs 1` the hn tiers at 32 and 64 measured the client,
  not the engine. `bench.mjs` prints `clientCoresPerProc`; near 1 means the
  client is the limit. `sweep.sh` uses `--procs 8`.
- **The service is one Node process.** For small pages it saturates (`node
  cores` ≈ 1.1–1.2) before the engine does.
- **The engine's shared HTTP connection pool** (`--http-max-concurrent`,
  default 40) caps how many page loads can be in flight across all
  connections. It shows up at 16 concurrent wiki loads already.
- **A page server with a small backlog** (Python's `http.server`) drops
  connections under load and the retransmits look like multi-second page
  loads. Measure `pagesrv.mjs` alone first (`--mode http`).
- **The host is shared.** Every row carries the load average at the start and
  end of its window; compare tiers that ran at similar load, or repeat.
