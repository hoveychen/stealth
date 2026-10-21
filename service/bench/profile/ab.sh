#!/bin/bash
# Runs every config once per repeat, in a fresh random order each repeat (a
# shared host's load drifts over minutes, so a fixed order biases whichever
# config runs first), one fresh container per run via run1.sh. Prints a summary.
#
#   CPUSET=128-255 bash profile/ab.sh configs.txt 3 $PWD/ab.jsonl
#
# config line:  N|IMAGE|EENV|V8F|LABEL     e.g.
#   64|lp-crawl:sym|||base
#   64|lp-crawl:sym||--single-threaded-gc|stgc
# Other run1.sh settings (CPUSET, PAGE, PAGE_BASE, SECS, ...) come from the environment.
cfg=$1; reps=$2; out=$3
here=$(cd "$(dirname "$0")" && pwd)
for r in $(seq "$reps"); do
  grep -v '^#' "$cfg" | grep . | shuf | while IFS='|' read -r n img eenv v8f label; do
    N=$n IMAGE=$img EENV="$eenv" V8F="$v8f" LABEL="$label r$r" OUT=$out bash "$here/run1.sh" > /dev/null
  done
done
node "$here/summary.mjs" < "$out"
