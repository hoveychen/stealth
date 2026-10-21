#!/bin/sh
# End-to-end test against the container: starts IMAGE with a test proxy pool
# and a session volume, runs test/run.mjs on this host (fixture pages and test
# proxies listen on the Docker bridge gateway), then removes the container and
# its volume. Run on the Docker host, from anywhere:
#
#   service/test/docker-test.sh [IMAGE]
#
# NAME (container and volume prefix), PORT (host port for the service) and
# TEST_PROXY_BASE (first of six consecutive free ports for the test proxies)
# can be overridden from the environment.
set -eu

IMAGE=${1:-lp-crawl}
NAME=${NAME:-lp-crawl-test}
PORT=${PORT:-18080}
BASE=${TEST_PROXY_BASE:-18481}
HERE=$(cd "$(dirname "$0")" && pwd)
GW=$(docker network inspect bridge -f '{{(index .IPAM.Config 0).Gateway}}')

start() {
  docker run -d --name "$NAME" -p "127.0.0.1:$PORT:8080" \
    -v "$NAME-data:/data" \
    -e POOL_SIZE=3 -e LP_RESTART_DELAY=4 \
    -e PROXY_POOL="http://$GW:$BASE,http://pool:secret@$GW:$((BASE + 1)),http://$GW:$((BASE + 2))" \
    -e PROXY_MAX_FAILS=2 -e PROXY_RETRY_AFTER_MS=5000 \
    "$IMAGE" >/dev/null
}

case "${2:-}" in
  # Used by run.mjs as LP_SERVICE_RESTART: a new container on the same volume.
  recreate) docker rm -f "$NAME" >/dev/null; start; exit 0 ;;
esac

docker rm -f "$NAME" >/dev/null 2>&1 || true
docker volume rm "$NAME-data" >/dev/null 2>&1 || true
start
trap 'docker rm -f "$NAME" >/dev/null 2>&1; docker volume rm "$NAME-data" >/dev/null 2>&1' EXIT

status=0
LP_SERVICE_URL="http://127.0.0.1:$PORT" \
FIXTURE_HOST="$GW" FIXTURE_URL_HOST="$GW" \
TEST_PROXY_HOST="$GW" TEST_PROXY_BASE="$BASE" \
LP_ENGINE_KILL="docker exec $NAME sh -c 'kill -9 \$(cat /tmp/lightpanda.pid)'" \
LP_SERVICE_RESTART="NAME=$NAME PORT=$PORT TEST_PROXY_BASE=$BASE '$HERE/docker-test.sh' '$IMAGE' recreate" \
node "$HERE/run.mjs" || status=$?
[ "$status" = 0 ] || docker logs --tail 40 "$NAME" >&2
exit $status
