#!/bin/bash
# One fresh engine container, one closed-loop bench.mjs run in cdp mode, one JSON
# line out (bench.mjs's fields plus load average, cpuset and the engine settings).
#
#   N=64 IMAGE=lp-crawl:sym CPUSET=128-255 LABEL=base OUT=$PWD/ab.jsonl bash profile/run1.sh
#
# env: IMAGE, N (connections), PAGE (list|wiki), PAGE_BASE (page server URL),
#      CPUSET (engine docker --cpuset-cpus), CCPUS (taskset for the load generator),
#      EENV ("K=V K=V" passed with -e), V8F (value for --v8-flags-unsafe, may hold
#      spaces), EARGS (extra `lightpanda serve` args), DARGS (extra docker run args,
#      e.g. --privileged for perf inside), NAME (container name), SECS, LABEL,
#      OUT (absolute path: this script cd's to the bench directory),
#      PROF (shell command run once the measured window has started; it sees
#      $PID = the engine's host pid, $NAME and $TAG = LABEL as a file-name slug),
#      PROFDELAY (seconds after warmup before PROF starts, default 2).
set -u
cd "$(dirname "$0")/.."
IMAGE=${IMAGE:-lp-crawl:latest}; N=${N:-64}; PAGE=${PAGE:-list}; PAGE_BASE=${PAGE_BASE:-http://172.17.0.1:29790}
CPUSET=${CPUSET:-}; CCPUS=${CCPUS:-0-31}; EENV=${EENV:-}; V8F=${V8F:-}; DARGS=${DARGS:-}
EARGS=${EARGS:---http-max-concurrent 255}; NAME=${NAME:-lp-crawl-prof}; SECS=${SECS:-10}
LABEL=${LABEL:-}; OUT=${OUT:-/dev/null}; PROF=${PROF:-}; PROFDELAY=${PROFDELAY:-2}
docker rm -f "$NAME" >/dev/null 2>&1 || true
envs=(); for kv in $EENV; do envs+=(-e "$kv"); done
docker run -d --name "$NAME" $DARGS ${CPUSET:+--cpuset-cpus "$CPUSET"} -e POOL_SIZE="$N" -e LP_HOST=0.0.0.0 \
  -e LP_CDP_MAX_CONNECTIONS=$((N * 2 + 8)) "${envs[@]}" "$IMAGE" $EARGS ${V8F:+--v8-flags-unsafe "$V8F"} >/dev/null || exit 1
ip=$(docker inspect -f '{{.NetworkSettings.IPAddress}}' "$NAME")
i=0; until curl -sf "http://$ip:9222/json/version" >/dev/null; do
  i=$((i + 1)); [ $i -gt 150 ] && { echo "container did not come up" >&2; docker logs --tail 20 "$NAME" >&2; docker rm -f "$NAME" >/dev/null; exit 1; }; sleep 0.1; done
PID=$(docker top "$NAME" -eo pid,comm | awk '$2 == "lightpanda" { print $1; exit }')
l0=$(cut -d' ' -f1 /proc/loadavg)
tmp=$(mktemp)
taskset -c "$CCPUS" node bench.mjs --mode cdp --target "http://$ip:9222" --url "$PAGE_BASE/$PAGE.html" -c "$N" \
  --procs $((N < 8 ? N : 8)) --warmup 3 --seconds "$SECS" --min-samples 40 --max-seconds $((SECS + 10 > 60 ? SECS + 10 : 60)) --container "$NAME" \
  --label "$LABEL" > "$tmp" &
bp=$!
if [ -n "$PROF" ]; then
  sleep $((3 + PROFDELAY))
  TAG=$(printf %s "$LABEL" | tr -c 'a-zA-Z0-9_.=-' '_')
  export PID TAG NAME CPUSET; bash -c "$PROF"
fi
wait $bp
l1=$(cut -d' ' -f1 /proc/loadavg)
node -e '
const r = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
Object.assign(r, { loadStart: +process.argv[2], loadEnd: +process.argv[3], cpuset: process.argv[4], eenv: process.argv[5], v8f: process.argv[6] });
console.log(JSON.stringify(r));' "$tmp" "$l0" "$l1" "$CPUSET" "$EENV" "$V8F" | tee -a "$OUT"
rm -f "$tmp"
docker rm -f "$NAME" >/dev/null
