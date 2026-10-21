#!/bin/bash
# PROF helper for run1.sh: which call sites issue futex waits and memory-mapping
# syscalls (mmap, mprotect, pkey_mprotect, madvise, munmap), and how long they take.
# Records sys_enter (with a DWARF user stack) and sys_exit (no stack) inside the
# engine container for SECS_REC seconds (default 0.3), writes $OUTDIR/$TAG.sc.txt.
# Then:  python3 profile/syscall-sites.py $OUTDIR/$TAG.sc.txt
#
# Copying 12 KB of stack per syscall inflates every duration to milliseconds:
# read the split between call sites, not the absolute times (sched-switch.sh is
# the low-overhead view). Needs a Dockerfile.perf image and DARGS=--privileged.
# The call graph must be set globally: a per-event call-graph=dwarf term does not
# sample the user registers and every stack stops at libc.
# Keep -m small: with -m 2048 and -q, perf silently traced one thread of forty.
set -u
OUTDIR=${OUTDIR:?absolute output directory}; mkdir -p "$OUTDIR"
docker exec "$NAME" sh -c '
mount -t tracefs nodev /sys/kernel/tracing 2>/dev/null
cd /tmp && rm -f sc.data
perf record -N -m 512 --call-graph dwarf,12288 -o sc.data -p "$(pgrep -x lightpanda)" \
  -e syscalls:sys_enter_futex --filter "op == 128 || op == 137 || op == 393 || op == 0 || op == 9 || op == 265" \
  -e syscalls:sys_exit_futex/call-graph=no/ \
  -e syscalls:sys_enter_mmap -e syscalls:sys_exit_mmap/call-graph=no/ \
  -e syscalls:sys_enter_mprotect -e syscalls:sys_exit_mprotect/call-graph=no/ \
  -e syscalls:sys_enter_pkey_mprotect -e syscalls:sys_exit_pkey_mprotect/call-graph=no/ \
  -e syscalls:sys_enter_madvise -e syscalls:sys_exit_madvise/call-graph=no/ \
  -e syscalls:sys_enter_munmap -e syscalls:sys_exit_munmap/call-graph=no/ \
  -- sleep '"${SECS_REC:-0.3}"'
perf script --no-inline -i sc.data > sc.txt 2>/dev/null'
docker cp "$NAME:/tmp/sc.txt" "$OUTDIR/$TAG.sc.txt"
