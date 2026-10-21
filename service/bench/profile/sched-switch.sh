#!/bin/bash
# PROF helper for run1.sh: records every context switch on the engine's CPUs for
# SECS_REC seconds (default 1) with kernel and frame-pointer user stacks, using
# perf inside the engine container (needs a Dockerfile.perf image and
# DARGS=--privileged). Writes $OUTDIR/$TAG.ss.txt and $OUTDIR/$TAG.tids (host
# thread ids, which is what sched_switch reports even from inside the container).
# Then:  python3 profile/offsched.py $OUTDIR/$TAG.ss.txt $OUTDIR/$TAG.tids 1
#
#   PROF='OUTDIR=$HOME/prof bash profile/sched-switch.sh' DARGS=--privileged ... bash profile/run1.sh
#
# Only sched_switch is traced, so the overhead stays small (a few percent of
# throughput); per-thread sampling with `perf record -p` halves throughput here.
# Recorded system-wide (-C) rather than per process: a switch-in is emitted in
# the context of the task being switched out, which a -p session never sees.
set -u
OUTDIR=${OUTDIR:?absolute output directory}; mkdir -p "$OUTDIR"
for t in $(ls /proc/$PID/task); do echo "$t $(cat /proc/$PID/task/$t/comm)"; done > "$OUTDIR/$TAG.tids"
docker exec "$NAME" sh -c "mount -t tracefs nodev /sys/kernel/tracing 2>/dev/null
  perf record -q -m 1024 -N -e sched:sched_switch -g -C ${CPUSET:?pin the engine with CPUSET} -o /tmp/ss.data -- sleep ${SECS_REC:-1}
  perf script --no-inline -i /tmp/ss.data > /tmp/ss.txt 2>/tmp/ss.err"
docker cp "$NAME:/tmp/ss.txt" "$OUTDIR/$TAG.ss.txt"
