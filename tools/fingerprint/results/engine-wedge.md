# The two "wedges" were crashes, 2026-08-20

`antibot-2026-08-20-vs-chrome.md` recorded pixiv and claude.ai as stations that
*wedge* the engine — `Runtime.evaluate` stops answering and never comes back.
Both are aborts, not hangs, and they are two different bugs.

## What the reading was hiding

The sweep only ever asked the page. Polling three independent channels instead —
the HTTP endpoint, `Runtime.evaluate`, and the process's own CPU time — says it
in one line:

```
  5s http=200          eval(1+1)=TIMEOUT  cpu=gone
 10s http=fetch failed eval(1+1)=TIMEOUT  cpu=gone
```

The process is gone by the first sample, and `ps` cannot find it. **A dead engine
and a stuck one look identical from a CDP client**, which is why this was written
down as a hang three times, across two separate sweeps and one `--fresh` re-run
that was specifically supposed to rule out interference. Nothing in the harness
was reading the child's exit signal; both stations exit `SIGABRT`.

## pixiv: an observer list that shrank under its own delivery loop — fixed

```
reason: index out of bounds: index 0, len 0
src/browser/frame/observers.zig:306 in deliverIntersections
        const observer = frame._intersection.observers.items[i];
```

`deliverIntersections` iterates the observer list backwards, with a comment
saying that handles an observer disconnecting during its own callback. It does —
but a callback can disconnect *other* observers too, and then the list is shorter
than the index already reached. Two observers whose callback drops both take the
length from 2 to 0 while the loop still has `i = 0` to go, and that read is out
of bounds. pixiv's lazy-loading does exactly that.

The fix is one `if (i >= …items.len) continue;` — the guard `deliverResizes`
twenty lines above already carries. That the sibling function had it and this one
did not is the whole bug.

`intersection_observer/disconnect_all_during_callback.html` reproduces it
locally: before the fix it aborts the test binary with the same reason and the
same line as pixiv, which is as close to the production crash as a test gets.

| | before | after |
|---|---|---|
| pixiv | `SIGABRT`, `Runtime.evaluate` never returns | **pass, 311 nodes — Chrome reads 311 too** |
| whole suite | — | 1264/1264 |

## claude.ai: a delivery pass walking a list that moved — fixed

Same shape, different bug, and it survives the fix above:

```
src/browser/webapi/PerformanceObserver.zig:195 in hasRecords
    return self._entries.items.len > 0;
src/browser/js/Scheduler.zig:132 in runQueue
```

`Performance.scheduleDelivery` queues a task that walks `perf._observers.items`
and calls `hasRecords()` on each. The crash is that read — and the thing that is
gone is not the observer and not the `Performance`, it is **the list's buffer**.
The task's loop was

```zig
for (perf._observers.items) |observer| {
```

which snapshots the slice once. A delivery callback that constructs a
`PerformanceObserver` and calls `observe()` appends to that same list; past the
capacity the arena had reserved, the append moves the buffer and releases the old
one. The snapshot keeps walking the released copy, and the next element it reads
is Zig's `0xaa` fill, dereferenced one line later in `hasRecords`. claude.ai's
login page registers observers from inside a delivery callback, which is why it
was the station that found this.

Re-reading `perf._observers.items[i]` each iteration is the whole fix, and this
fork already carries it: upstream `a4b258305` ("fix: UAF when Performance
Observer disconnects in callback", 2026-08-17, PR #3213) rewrote the loop and
added the `_delivering` flag, and it reached us with the 295-commit upstream
merge (`e7ef95431`). Upstream was chasing the *disconnect* case; what claude.ai
does is the opposite mutation — it registers, the list grows, and only the loop
half of that commit is what stops the crash (see the isolation table below). So
the engine needed no change here. What W3 adds is the test that pins it, and the
attribution below, which the two earlier readings of this crash got wrong.

## What to change in the harness

`antibot-sweep.mjs` should record the child's exit code and signal alongside the
station's verdict. Every reading in this file was available on the first sweep;
nobody was looking at the one channel that distinguishes `error` from `crash`,
and three runs' worth of "wedges the engine" would have said `SIGABRT` instead.

It does now — and it counted its own teardown as one. `teardown()` sends
`SIGKILL` and then sleeps 600ms waiting for the port, which is long enough for
the exit handler to fire, so **every healthy station printed `CRASHED SIGKILL`**.
The handler ignores the kill we sent ourselves now. Verified both directions on
the same station: the fixed binary prints no exit at all, the `9d117e371` binary
still prints `CRASHED SIGABRT`.

## claude.ai, named by isolation (same day)

Two earlier readings of this crash were wrong, and both were wrong the same way:
they reasoned from the code about *lifetimes* — an observer dying with a
navigation's arena, a queued task outliving its subject — because the poisoned
address said "released memory" and nothing said which release. The address said
more than that. `0xaaaaaaaaaaaaaac2` is `0xaaaaaaaaaaaaaaaa + 0x18`, and `0x18`
is the offset of `_entries.items.len` in `PerformanceObserver`: the *observer
pointer* was the poison, read out of the list, so the list's buffer was the dead
allocation and both the `Performance` and its `len` were alive. Instrumenting the
loop said it outright, one line before the abort:

```
PROBE.deliver.item  obs = 12297829382473034410  live_ptr = 5335940992  live_len = 13
```

`12297829382473034410` is `0xaaaaaaaaaaaaaaaa`. The live list had grown to 13
entries at a new address while the pass was still reading the old one.

**The isolation experiment.** Three runs of the station per column, same
afternoon, same site, `--fresh` each time:

| binary | result |
|---|---|
| `9d117e371` (the commit the crash was first recorded on) | `SIGABRT` 3/3, 86s |
| `9d117e371` + the index-based re-read, nothing else | pass 3/3, 28s |
| `main` (`172d6d2fd`, carries that re-read) | pass 4/4, 28s |

One loop's worth of difference, both directions. That is the fix named, not a
candidate.

**The regression test.**
`src/browser/tests/performance_observer/register_during_delivery.html` — two
observers pending in one pass, the first one's callback registering 128 more.
Against `9d117e371` it aborts the *test binary* with the production crash
verbatim (`0xaaaaaaaaaaaaaac2` in `hasRecords`, from `Scheduler.runQueue`); on
`main` it passes, suite 1361/1361.

**What was not established, and stays open.** `Scheduler` still has no removal
keyed by `ctx`, and `reset()` is still called only by the two worker global
scopes and `window.close()` — so a task queued against an object that dies before
its turn is still a shape this engine allows. `web_transport`, `EventSource`,
`XRSession` and `sensor` all queue tasks with themselves as `ctx`. Nothing here
demonstrates that any of them actually crashes; it was this list's buffer, not a
dead subject. Left alone deliberately: no evidence, no fix.
