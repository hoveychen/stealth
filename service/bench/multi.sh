#!/bin/sh
# Splits one concurrency budget over several engine containers: K containers
# with N connections each, one bench.mjs per container, all at once. Compare
# with `multi.sh 1 K*N ...` to see what one engine process costs over several.
#
#   OUT=multi.jsonl sh service/bench/multi.sh 4 16 list --http-max-concurrent 255
#
# Arguments after the page are passed to `lightpanda serve`. Environment: IMAGE,
# NAME (container name prefix), MODE (cdp or service), PAGE_HOST, PAGE_PORT,
# OUT, CPUS (docker run --cpus per container).
set -eu
cd "$(dirname "$0")"
IMAGE=${IMAGE:-lp-crawl:bench}
NAME=${NAME:-lp-crawl-bench}
MODE=${MODE:-cdp}
PAGE_HOST=${PAGE_HOST:-172.17.0.1}
PAGE_PORT=${PAGE_PORT:-29790}
OUT=${OUT:-multi.jsonl}
CPUS=${CPUS:-}
K=$1; N=$2; P=$3; shift 3
tmp=$(mktemp -d)

for i in $(seq "$K"); do
  docker rm -f "$NAME-m$i" >/dev/null 2>&1 || true
  docker run -d --name "$NAME-m$i" ${CPUS:+--cpus "$CPUS"} -e POOL_SIZE="$N" -e LP_HOST=0.0.0.0 \
    -e LP_CDP_MAX_CONNECTIONS=$((N * 2 + 8)) "$IMAGE" "$@" >/dev/null
done
for i in $(seq "$K"); do
  ip=$(docker inspect -f '{{.NetworkSettings.IPAddress}}' "$NAME-m$i")
  j=0; until curl -sf "http://$ip:8080/health" >/dev/null && curl -sf "http://$ip:9222/json/version" >/dev/null; do
    j=$((j + 1)); [ $j -gt 100 ] && { echo "container $i did not come up" >&2; exit 1; }; sleep 0.1; done
done
for i in $(seq "$K"); do
  ip=$(docker inspect -f '{{.NetworkSettings.IPAddress}}' "$NAME-m$i")
  if [ "$MODE" = cdp ]; then t=http://$ip:9222; else t=http://$ip:8080; fi
  node bench.mjs --mode "$MODE" --target "$t" --url "http://$PAGE_HOST:$PAGE_PORT/$P.html" -c "$N" --procs 8 \
    --warmup 3 --seconds 10 --min-samples 40 --container "$NAME-m$i" \
    --label "multi ${K}x$N${CPUS:+ cpus=$CPUS} $*" > "$tmp/$i.json" &
done
wait
cat "$tmp"/*.json >> "$OUT"
node -e '
const ds = process.argv.slice(1).map((f) => JSON.parse(require("fs").readFileSync(f, "utf8")));
const sum = (k) => ds.reduce((a, d) => a + d[k], 0);
console.log(JSON.stringify({ label: ds[0].label, mode: ds[0].mode, page: ds[0].page, containers: ds.length, c: sum("c"),
  pagesPerSec: +sum("pagesPerSec").toFixed(1), p50: Math.max(...ds.map((d) => d.p50)), p95: Math.max(...ds.map((d) => d.p95)),
  errors: sum("errors"), engineCores: +sum("engineCores").toFixed(1), containerCores: +sum("containerCores").toFixed(1),
  peakContainerMB: sum("peakContainerMB"), load: ds[0].load }));
' "$tmp"/*.json
rm -rf "$tmp"
for i in $(seq "$K"); do docker rm -f "$NAME-m$i" >/dev/null; done
