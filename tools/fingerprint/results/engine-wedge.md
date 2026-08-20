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

## claude.ai: a stale observer pointer — attributed, not fixed

Same shape, different bug, and it survives the fix above:

```
src/browser/webapi/PerformanceObserver.zig:195 in hasRecords
    return self._entries.items.len > 0;
src/browser/js/Scheduler.zig:132 in runQueue
```

`Performance.scheduleDelivery` queues a task that walks `perf._observers.items`
and calls `hasRecords()` on each. The crash is that read, on an observer whose
memory is gone — so `Performance._observers` is holding a pointer past its
referent's life. `disconnect()` does unregister, so this is not the disconnect
path; it is an observer dying some other way (its arena going with a navigation
is the obvious candidate) while the longer-lived `Performance` keeps pointing at
it, and the already-queued `Performance.deliverObservers` task then runs.

That is a lifetime question rather than a bounds check, so it is written down
here rather than guessed at. It reproduces on every run of the claude.ai station
(`wedge-claude-after.json`, 86s then `SIGABRT`), which is enough to work from.

## What to change in the harness

`antibot-sweep.mjs` should record the child's exit code and signal alongside the
station's verdict. Every reading in this file was available on the first sweep;
nobody was looking at the one channel that distinguishes `error` from `crash`,
and three runs' worth of "wedges the engine" would have said `SIGABRT` instead.
