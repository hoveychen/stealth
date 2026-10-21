#!/usr/bin/env python3
"""Pairs sys_enter_X (with stack) and sys_exit_X per thread from syscall-sites.sh output and
sums syscall time by call site (first non-wrapper frames). usage: syscall-sites.py sc.txt [seconds] [depth]"""
import re, sys, collections
path = sys.argv[1]; secs = float(sys.argv[2]) if len(sys.argv) > 2 else 0; depth = int(sys.argv[3]) if len(sys.argv) > 3 else 4
hdr = re.compile(r'^(.+?)\s+(\d+)\s+\[(\d+)\]\s+([\d.]+):\s+syscalls:sys_(enter|exit)_(\w+):?(.*)$')
SKIP = re.compile(r'^(syscall|__lll_|__futex|futex_|pthread_|__pthread|___pthread|absl::|AbslInternal|std::|v8::base::(Mutex|RecursiveMutex|ConditionVariable|Semaphore|SharedMutex|.*Mutex)|\[unknown\]|__GI_|__libc|__mmap|mmap64|__mprotect|__madvise|madvise|mprotect|pkey_mprotect|munmap|v8::base::OS::|v8::base::PageAllocator::|v8::base::BoundedPageAllocator::|v8::internal::(anonymous namespace)::|v8::platform::DefaultJobState::|v8::platform::DelayedTaskQueue)')
pending = {}  # tid -> (name, ts, cls, stack)
agg = collections.defaultdict(lambda: [0, 0.0])
tot = collections.defaultdict(lambda: [0, 0.0])
cur = None
def flush(rec):
    if rec is None: return
    comm, tid, ts, kind, name, stack = rec
    cls = 'v8' if comm.startswith('V8') else 'lp'
    if kind == 'enter':
        pending[tid] = (name, ts, cls, stack)
    else:
        p = pending.pop(tid, None)
        if p is None or p[0] != name: return
        d = ts - p[1]
        frames = [f for f in p[3] if not SKIP.match(f)]
        key = (p[2], name, ' < '.join(frames[:depth]))
        agg[key][0] += 1; agg[key][1] += d
        tot[(p[2], name)][0] += 1; tot[(p[2], name)][1] += d
with open(path, errors='replace') as f:
    for line in f:
        m = hdr.match(line)
        if m:
            flush(cur)
            cur = [m.group(1).strip(), int(m.group(2)), float(m.group(4)), m.group(5), m.group(6), []]
            continue
        s = line.strip()
        if cur is not None and s:
            parts = s.split(None, 1)
            if len(parts) == 2:
                sym = re.sub(r'\+0x[0-9a-f]+$', '', parts[1])
                sym = re.sub(r'\(.*$', '', sym) if not sym.startswith('v8::internal::(anonymous') else sym
                cur[5].append(sym.strip())
flush(cur)
print('== totals (thread class, syscall): calls, total s' + (', share of window per class thread-s' if secs else ''))
for k, (n, t) in sorted(tot.items(), key=lambda x: -x[1][1]):
    print(f'{k[0]} {k[1]:14} n={n:7d} total={t:9.3f}s avg={1e6*t/n:8.1f}us')
print('== by call site')
for k, (n, t) in sorted(agg.items(), key=lambda x: -x[1][1])[:45]:
    print(f'{t:8.3f}s n={n:6d} avg={1e6*t/n:7.1f}us {k[0]} {k[1]:13} {k[2][:260]}')
