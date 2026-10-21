#!/usr/bin/env python3
"""Off-CPU time of one process from a system-wide `perf record -e sched:sched_switch -g`
on the CPUs it is pinned to. Pairs each switch-out of a thread with its next switch-in and
attributes the gap to the switch-out stack. usage: offsched.py script.txt <tids-file> [secs]"""
import re, sys, collections
tids = {}
for l in open(sys.argv[2]):
    p = l.split(None, 1)
    if len(p) == 2: tids[int(p[0])] = 'v8' if p[1].startswith('V8') else 'lp'
secs = float(sys.argv[3]) if len(sys.argv) > 3 else 1
hdr = re.compile(r'^\s*(\S.*?)\s+(\d+)\s+\[(\d+)\]\s+([\d.]+):\s+sched:sched_switch:.*prev_pid=(\d+).*prev_state=(\S+) ==> .*next_pid=(\d+)')
frame = re.compile(r'^\s*([0-9a-f]+)\s+(.*?)\s+\(([^)]*)\)\s*$')
events = []; cur = None
for line in open(sys.argv[1], errors='replace'):
    m = hdr.match(line)
    if m:
        if cur: events.append(cur)
        cur = [float(m.group(4)), int(m.group(5)), m.group(6), int(m.group(7)), []]; continue
    f = frame.match(line)
    if f and cur is not None:
        sym = re.sub(r'\+0x[0-9a-f]+$', '', f.group(2)); sym = re.sub(r'\(.*$', '', sym).strip()
        cur[4].append((int(f.group(1), 16) >= 0xffff000000000000, sym))
if cur: events.append(cur)
events.sort(key=lambda e: e[0])
out = {}; cat = collections.defaultdict(float); site = collections.defaultdict(float); cnt = collections.Counter()
SKIPU = re.compile(r'^(syscall|\[unknown\]|__GI_|__lll|absl::|AbslInternal|pthread_|__pthread|___pthread|__futex|futex|v8::base::(Mutex|ConditionVariable|Semaphore)|__mmap|mmap64|__mprotect|__madvise|madvise|mprotect|pkey_mprotect|munmap|__poll|poll|epoll_wait|__libc|v8::base::OS::|v8::base::PageAllocator::|v8::base::(AddressSpaceReservation|VirtualAddressSubspace|MemoryProtectionKey)::|v8::internal::VirtualMemory::)')
def classify(st, state):
    ks = [s for k, s in st if k]
    if state.startswith('R'): return 'preempted(runqueue)'
    j = ' '.join(ks)
    if 'rwsem_down' in j or 'mmap_lock' in j or 'down_read' in j or 'down_write' in j: return 'mmap_lock(rwsem)'
    if 'futex' in j: return 'futex'
    if 'ep_poll' in j or 'do_epoll_wait' in j: return 'epoll_wait'
    if 'do_sys_poll' in j or 'do_poll' in j: return 'poll'
    if 'flush_tlb' in j or 'smp_call_function' in j: return 'tlb_ipi'
    if 'exc_page_fault' in j or 'handle_mm_fault' in j: return 'page_fault'
    if 'nanosleep' in j or 'clock_nanosleep' in j: return 'sleep'
    return 'other:' + (ks[1] if len(ks) > 1 else (ks[0] if ks else '?'))
for t, prev, state, nxt, st in events:
    if prev in tids and prev != 0:
        out[prev] = (t, classify(st, state), ' < '.join([s for k, s in st if not k and not SKIPU.match(s)][:3]))
    if nxt in tids:
        o = out.pop(nxt, None)
        if o:
            d = t - o[0]; c = tids[nxt]
            cat[(c, o[1])] += d; cnt[(c, o[1])] += 1
            if o[1] in ('futex', 'mmap_lock(rwsem)'): site[(c, o[1], o[2])] += d
nthr = collections.Counter(tids.values())
print(f'threads: {dict(nthr)}  window {secs}s')
for k, v in sorted(cat.items(), key=lambda x: -x[1]):
    print(f'{k[0]} {k[1]:24} {v:8.3f}s  {100*v/(secs*nthr[k[0]]):5.1f}% of class thread-time  n={cnt[k]}')
print('== futex / mmap_lock waits by user call site (FP-unwound, may be partial)')
for k, v in sorted(site.items(), key=lambda x: -x[1])[:25]:
    print(f'{v:8.3f}s {k[0]} {k[1]:16} {k[2][:240]}')
