#!/bin/sh
# Starts one crawl-service container and runs soak.mjs against it in the
# background; the sample lines go to $OUT, progress to $OUT.log. Run on the
# Docker host with pagesrv.mjs on PAGE_HOST:PAGE_PORT. The container is left
# running when the soak ends (inspect it, then `docker rm -f`).
#
#   NAME=lp-crawl-c-mixed POOL=16 CPUS=24 C=20 MIX=... PHASES=load:120m,idle:20m \
#     OUT=mixed.jsonl sh service/bench/soak.sh
#
# Environment: IMAGE (lp-crawl:bench), NAME, POOL (POOL_SIZE, 16), CPUS
# (docker --cpus, 24), C (load workers, POOL+4), MIX, PHASES, SAMPLE (30 s),
# ENGINE_ARGS (--http-max-concurrent 255), SERVICE_ENV (extra `-e K=V ...`).
set -eu
cd "$(dirname "$0")"
IMAGE=${IMAGE:-lp-crawl:bench}
NAME=${NAME:?NAME}
POOL=${POOL:-16}
CPUS=${CPUS:-24}
C=${C:-$((POOL + 4))}
PAGE_HOST=${PAGE_HOST:-172.17.0.1}
PAGE_PORT=${PAGE_PORT:-29890}
OUT=${OUT:-$NAME.jsonl}
ENGINE_ARGS=${ENGINE_ARGS:---http-max-concurrent 255}

docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --name "$NAME" --cpus "$CPUS" -e POOL_SIZE="$POOL" ${SERVICE_ENV:-} "$IMAGE" $ENGINE_ARGS >/dev/null
ip=$(docker inspect -f '{{.NetworkSettings.IPAddress}}' "$NAME")
i=0; until curl -sf "http://$ip:8080/health" >/dev/null; do
  i=$((i + 1)); [ $i -gt 100 ] && { echo "container did not come up" >&2; exit 1; }; sleep 0.1; done
nohup node soak.mjs --target "http://$ip:8080" --container "$NAME" --pages "http://$PAGE_HOST:$PAGE_PORT" \
  --refused "http://$PAGE_HOST:1/" -c "$C" ${MIX:+--mix "$MIX"} --phases "${PHASES:-load:120m}" \
  --sample "${SAMPLE:-30}" --out "$OUT" --label "$NAME" >"$OUT.log" 2>&1 &
echo "$NAME at $ip, soak pid $!, samples in $OUT"
