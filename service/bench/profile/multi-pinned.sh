#!/bin/bash
# K engine containers x N connections each, container i pinned to its own equal
# slice of CPUSET (a lo-hi range), one bench.mjs per container, all at once; prints
# one summed JSON line. Compare `multi-pinned.sh 4 16` with `multi-pinned.sh 1 64`
# on the same CPUSET to see what one process costs over several.
# env: IMAGE EENV V8F LABEL OUT CPUSET CCPUS PAGE PAGE_BASE SECS NAME  usage: multi-pinned.sh K N
set -u
cd "$(dirname "$0")/.."
K=$1; N=$2; IMAGE=${IMAGE:-lp-crawl:latest}; PAGE=${PAGE:-list}; SECS=${SECS:-10}
PAGE_BASE=${PAGE_BASE:-http://172.17.0.1:29790}; NAME=${NAME:-lp-crawl-prof}
lo=${CPUSET:?CPUSET=lo-hi}; lo0=${lo%-*}; hi0=${lo#*-}; per=$(( (hi0 - lo0 + 1) / K ))
envs=""; for kv in ${EENV:-}; do envs="$envs -e $kv"; done
tmp=$(mktemp -d)
for i in $(seq 0 $((K - 1))); do
  c=$NAME-m$i; docker rm -f $c >/dev/null 2>&1
  docker run -d --name $c --cpuset-cpus $((lo0 + i * per))-$((lo0 + (i + 1) * per - 1)) -e POOL_SIZE=$N -e LP_HOST=0.0.0.0 \
    -e LP_CDP_MAX_CONNECTIONS=$((N * 2 + 8)) $envs $IMAGE --http-max-concurrent 255 ${V8F:+--v8-flags-unsafe "$V8F"} >/dev/null
done
for i in $(seq 0 $((K - 1))); do ip=$(docker inspect -f '{{.NetworkSettings.IPAddress}}' $NAME-m$i)
  j=0; until curl -sf http://$ip:9222/json/version >/dev/null; do j=$((j + 1)); [ $j -gt 150 ] && exit 1; sleep 0.1; done; done
l0=$(cut -d' ' -f1 /proc/loadavg)
for i in $(seq 0 $((K - 1))); do ip=$(docker inspect -f '{{.NetworkSettings.IPAddress}}' $NAME-m$i)
  taskset -c "${CCPUS:-0-31}" node bench.mjs --mode cdp --target http://$ip:9222 --url $PAGE_BASE/$PAGE.html -c $N --procs $(( N < 8 ? N : 8 )) \
    --warmup 3 --seconds $SECS --min-samples 40 --container $NAME-m$i --label "${LABEL:-multi}" > $tmp/$i.json & done
wait
l1=$(cut -d' ' -f1 /proc/loadavg)
node -e '
const ds = process.argv.slice(3).map((f) => JSON.parse(require("fs").readFileSync(f, "utf8")));
const sum = (k) => ds.reduce((a, d) => a + d[k], 0);
console.log(JSON.stringify({ label: ds[0].label, containers: ds.length, c: sum("c"), pagesPerSec: +sum("pagesPerSec").toFixed(1),
  p50: Math.max(...ds.map((d) => d.p50)), p95: Math.max(...ds.map((d) => d.p95)), errors: sum("errors"),
  engineCores: +sum("engineCores").toFixed(1), peakContainerMB: sum("peakContainerMB"), peakEngineThreads: sum("peakEngineThreads"),
  loadStart: +process.argv[1], loadEnd: +process.argv[2] }));' "$l0" "$l1" $tmp/*.json | tee -a ${OUT:-/dev/null}
rm -rf $tmp; for i in $(seq 0 $((K - 1))); do docker rm -f $NAME-m$i >/dev/null; done
