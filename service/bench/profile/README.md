# profiling one engine process

Tools for finding out where a `lightpanda serve` process spends the time it is
*not* running: which locks and syscalls its worker threads wait on, and which
call sites they wait from. They were written to find why one process stops
scaling past ~32 connections (see the fleet wiki report
`crawl-service/single-process-ceiling`); the same harness runs any A/B on
engine flags, environment knobs or images.

| file | what it does |
|---|---|
| `run1.sh` | one fresh engine container, one `bench.mjs` run (`--mode cdp`, or through the service with `MODE=service`), one JSON line; optional pinning (`CPUSET`), env (`EENV`), V8 flags (`V8F`) and a profiling hook (`PROF`) that runs inside the measured window |
| `ab.sh` | runs a list of configs (`N\|IMAGE\|EENV\|V8F\|LABEL[\|CPUSET[\|MODE]]`; `CPUSET` `none` = unpinned, `MODE` `cdp` or `service`) for several repeats, shuffled per repeat, then prints `summary.mjs` |
| `multi-pinned.sh` | K containers × N connections, each pinned to its own slice of `CPUSET`, all loaded at once |
| `Dockerfile.perf` | an engine image plus perf/procps/binutils, so perf runs inside the engine's mount namespace |
| `sched-switch.sh` + `offsched.py` | **off-CPU breakdown**: every context switch on the engine's CPUs for 1 s, paired switch-out → switch-in per thread, attributed to a reason (futex, `mmap_lock` rwsem, poll, epoll, run queue) and to the user call site |
| `syscall-sites.sh` + `syscall-sites.py` | futex waits and mmap/mprotect/pkey_mprotect/madvise/munmap with DWARF stacks: which call sites issue them |

## Setup

```bash
# 1. A build with symbols: service/Dockerfile without -Dstrip (a copy of it with
#    `-Dstrip=true` removed from both zig build lines; needs ~16 GB of RAM).
# 2. The debug image on top of it:
docker build -t lp-crawl:prof --build-arg IMAGE=lp-crawl:sym -f profile/Dockerfile.perf profile
# 3. The page server, from service/bench:
node pagesrv.mjs 172.17.0.1 29790 8 &
```

## Typical runs

```bash
# A/B with random order and repeats; pin the engine to one NUMA node
cat > cfg.txt <<'X'
64|lp-crawl:sym|||base
64|lp-crawl:sym||--single-threaded-gc|stgc
X
CPUSET=128-255 bash profile/ab.sh cfg.txt 3 $PWD/ab.jsonl

# off-CPU breakdown at 64 connections
N=64 IMAGE=lp-crawl:prof DARGS=--privileged CPUSET=128-255 LABEL=base64 \
  PROF='OUTDIR=$HOME/prof bash profile/sched-switch.sh' bash profile/run1.sh
python3 profile/offsched.py ~/prof/base64.ss.txt ~/prof/base64.tids 1

# which call sites issue the waits and the mmap-family syscalls
N=16 IMAGE=lp-crawl:prof DARGS=--privileged CPUSET=128-255 LABEL=sites16 \
  PROF='OUTDIR=$HOME/prof bash profile/syscall-sites.sh' bash profile/run1.sh
python3 profile/syscall-sites.py ~/prof/sites16.sc.txt 0.3 4
```

`offsched.py` prints, per thread class (`lp` = engine threads, `v8` = V8's
platform workers), the share of thread time spent in each wait, then the futex
and `mmap_lock` waits by call site. Stacks are frame-pointer unwound at record
time: V8 frames come out, Zig frames often end the chain (empty site).

## Things that made earlier readings wrong

- **V8's mutexes are absl::Mutex.** A blocked waiter sleeps on its own
  per-thread semaphore, so `perf trace -e futex` shows every waiter on a
  different address even when all of them queue on one lock. "Each futex address
  has one waiter" does not rule out a global lock; the call site does.
- **perf from the host loses the stack at the container's libc**, and the
  host's perf 6.8 writes an unreadable file when `-C` spans 128 CPUs. Run perf
  inside the container (`Dockerfile.perf`, `DARGS=--privileged`). sched_switch
  reports host thread ids even there, so `sched-switch.sh` lists them from the
  host's `/proc`.
- **`perf record -p` with sampling halves throughput** at 64 connections (perf
  bookkeeping on every context switch). Use system-wide `-C` on the pinned CPUs.
- **`--v8-flags-unsafe --no-memory-pool` changes nothing** on V8 14.9: the
  process-wide `MemoryPool` and its lock are used either way.
- **Load on a shared host moves the whole column.** Runs at load ~70 and ~250
  differ by 25% for the same config; compare configs inside one `ab.sh` run,
  never across runs.
