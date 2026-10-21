#!/bin/sh
# Runs bench.mjs over concurrency tiers, modes and pages, one fresh container
# per run so memory readings don't carry over. Run on the Docker host, with
# pagesrv.mjs listening on PAGE_HOST:PAGE_PORT (reachable from containers).
#
#   OUT=results.jsonl TIERS="1 4 8 16 32 64" REPEATS=2 sh service/bench/sweep.sh
#
# Environment: IMAGE (lp-crawl:bench), NAME (container name prefix,
# lp-crawl-bench), PAGES ("list wiki"), MODES ("service cdp"), PROCS (load
# generator processes, default 8, capped at the tier), CPUS (passed to
# docker run --cpus when set), ENGINE_ARGS (extra `lightpanda serve` flags,
# e.g. "--http-max-concurrent 255"), BENCH_ARGS (extra bench.mjs flags).
set -eu
cd "$(dirname "$0")"
IMAGE=${IMAGE:-lp-crawl:bench}
NAME=${NAME:-lp-crawl-bench}
TIERS=${TIERS:-1 4 8 16 32 64}
PAGES=${PAGES:-list wiki}
MODES=${MODES:-service cdp}
REPEATS=${REPEATS:-1}
PAGE_HOST=${PAGE_HOST:-172.17.0.1}
PAGE_PORT=${PAGE_PORT:-29790}
OUT=${OUT:-results.jsonl}
CPUS=${CPUS:-}
ENGINE_ARGS=${ENGINE_ARGS:-}

run() { # repeat tier mode page
  c=$NAME-run
  docker rm -f "$c" >/dev/null 2>&1 || true
  docker run -d --name "$c" ${CPUS:+--cpus "$CPUS"} -e POOL_SIZE="$2" -e LP_HOST=0.0.0.0 \
    -e LP_CDP_MAX_CONNECTIONS=$(($2 * 2 + 8)) "$IMAGE" $ENGINE_ARGS >/dev/null
  ip=$(docker inspect -f '{{.NetworkSettings.IPAddress}}' "$c")
  i=0; until curl -sf "http://$ip:8080/health" >/dev/null && curl -sf "http://$ip:9222/json/version" >/dev/null; do
    i=$((i + 1)); [ $i -gt 100 ] && { echo "container did not come up" >&2; exit 1; }; sleep 0.1; done
  if [ "$3" = cdp ]; then t=http://$ip:9222; else t=http://$ip:8080; fi
  # A wiki load takes ~1s on one connection, so a single connection needs a
  # longer window to reach the sample floor.
  node bench.mjs --mode "$3" --target "$t" --url "http://$PAGE_HOST:$PAGE_PORT/$4.html" -c "$2" \
    --procs "${PROCS:-8}" --warmup 3 --seconds 10 --min-samples 40 --max-seconds 60 --container "$c" \
    --label "r$1${CPUS:+ cpus=$CPUS}${ENGINE_ARGS:+ $ENGINE_ARGS}" ${BENCH_ARGS:-} | tee -a "$OUT"
  docker rm -f "$c" >/dev/null
}

r=1
while [ $r -le "$REPEATS" ]; do
  for n in $TIERS; do
    # Alternate the mode order between repeats so neither mode always runs
    # first in a tier (the shared host's load drifts over minutes).
    if [ $((r % 2)) -eq 1 ]; then ms=$MODES; else ms=$(echo "$MODES" | awk '{for (i = NF; i > 0; i--) printf "%s ", $i}'); fi
    for m in $ms; do for p in $PAGES; do run "$r" "$n" "$m" "$p"; done; done
  done
  r=$((r + 1))
done
