#!/bin/sh
# Six antibot sweeps, alternating between the branch's base and its head, so a
# station that opens and closes on its own clock cannot be read as a change in
# the engine. B50 established the method: report a *rate* over interleaved
# runs, never a single verdict.
#
# Both binaries are ReleaseFast -- a debug build SIGABRTs on x-sony and every
# station after it times out, which reads as a collapse that is not there --
# and every run takes its own --port so a stray server from another session
# cannot be measured instead of ours.
set -e
CONTROL=/Users/hoveychen/workspace/stealth/.worktrees/b52-control/zig-out-rel/bin/lightpanda
TREATMENT=/Users/hoveychen/workspace/stealth/.worktrees/proto-completeness-window/zig-out-rel/bin/lightpanda
HERE=/Users/hoveychen/workspace/stealth/.worktrees/proto-completeness-window
PORT=13200

for round in 1 2 3; do
    for arm in control treatment; do
        if [ "$arm" = control ]; then BIN=$CONTROL; else BIN=$TREATMENT; fi
        PORT=$((PORT + 10))
        echo "=== round $round $arm (port $PORT) $(date +%H:%M:%S)"
        LP_BIN=$BIN node "$HERE/tools/fingerprint/antibot-sweep.mjs" lightpanda \
            --port "$PORT" \
            --out "$HERE/tools/fingerprint/results/b52-sweep-$arm-$round.json" \
            > "/tmp/b52-sweep-$arm-$round.log" 2>&1 || true
        echo "--- done $(date +%H:%M:%S)"
    done
done
echo "ALL SWEEPS DONE"
