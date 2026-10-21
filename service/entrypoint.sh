#!/bin/sh
# Starts the crawl service: `lightpanda serve` on loopback and the Node HTTP
# service in front of it. Arguments that start with "-" are appended to the
# serve command line (so `docker run IMAGE --log-level debug` works); anything
# else is executed as given (so `docker run IMAGE lightpanda version` or `sh`
# works).
#
# The engine is restarted here, in a loop, whenever it exits; the Node service
# is exec'd and is the process tini waits on, so if it exits the container
# exits and the restart policy takes over. The service already rides out an
# engine restart (queued requests wait for it), which a container restart
# would not: that drops the queue and the HTTP port with it.
#
# Never add --obey-robots, --web-bot-auth-* or --webmcp here: each one
# announces the client as a bot (see AGENTS.md).
set -e

case "$1" in
  "" | -*) ;;
  *) exec "$@" ;;
esac

POOL_SIZE=${POOL_SIZE:-4}
LP_PORT=${LP_PORT:-9222}
# Headroom over POOL_SIZE: after a timeout the service drops the connection
# and reconnects at once, and the engine may still be tearing the old worker
# down, so for a moment one slot can hold two connections.
LP_CDP_MAX_CONNECTIONS=${LP_CDP_MAX_CONNECTIONS:-$((POOL_SIZE * 2 + 4))}
if [ "$LP_CDP_MAX_CONNECTIONS" -le "$POOL_SIZE" ]; then
  echo "entrypoint: LP_CDP_MAX_CONNECTIONS=$LP_CDP_MAX_CONNECTIONS should be well above POOL_SIZE=$POOL_SIZE" >&2
fi
# The engine's HTTP connection pool is shared by every CDP connection; its
# default (40) is what heavy pages queue on from about 16 concurrent loads
# (service/bench). 255 is the most the flag takes (it is a u8).
LP_HTTP_MAX_CONCURRENT=${LP_HTTP_MAX_CONCURRENT:-255}
case "$LP_HTTP_MAX_CONCURRENT" in
  "" | *[!0-9]*) echo "entrypoint: LP_HTTP_MAX_CONCURRENT=$LP_HTTP_MAX_CONCURRENT is not a number" >&2; exit 2 ;;
esac
if [ "$LP_HTTP_MAX_CONCURRENT" -lt 1 ] || [ "$LP_HTTP_MAX_CONCURRENT" -gt 255 ]; then
  echo "entrypoint: LP_HTTP_MAX_CONCURRENT=$LP_HTTP_MAX_CONCURRENT must be 1..255" >&2; exit 2
fi

# The engine's malloc. Only the engine is switched; Node keeps glibc. jemalloc
# is the default: on a mixed load glibc held ~1.6 GB and kept 1.3 GB when idle,
# jemalloc ~0.75 GB and 0.24 GB idle, at the same throughput (service/README.md,
# Memory). glibc stays selectable.
case "${LP_MALLOC:-jemalloc}" in
  glibc) ENGINE_PRELOAD=${LD_PRELOAD:-} ;;
  jemalloc)
    ENGINE_PRELOAD=$(ls /usr/lib/*-linux-gnu/libjemalloc.so.2 2>/dev/null | head -n 1)
    if [ -z "$ENGINE_PRELOAD" ]; then
      echo "entrypoint: LP_MALLOC=jemalloc but libjemalloc.so.2 is not installed" >&2; exit 2
    fi
    # Without background_thread jemalloc only purges freed pages on later
    # allocations, so an idle engine would keep its peak.
    export MALLOC_CONF="${MALLOC_CONF:-background_thread:true}"
    ;;
  *) echo "entrypoint: LP_MALLOC=$LP_MALLOC must be glibc or jemalloc" >&2; exit 2 ;;
esac

engine() {
  while :; do
    LD_PRELOAD="$ENGINE_PRELOAD" /bin/lightpanda serve \
      --host "${LP_HOST:-127.0.0.1}" \
      --port "$LP_PORT" \
      --cdp-max-connections "$LP_CDP_MAX_CONNECTIONS" \
      --http-max-concurrent "$LP_HTTP_MAX_CONCURRENT" \
      --log-level "${LP_LOG_LEVEL:-info}" \
      "$@" &
    echo $! > /tmp/lightpanda.pid
    status=0
    wait $! || status=$?
    echo "entrypoint: lightpanda serve exited with $status, restarting in ${LP_RESTART_DELAY:-1}s" >&2
    sleep "${LP_RESTART_DELAY:-1}"
  done
}
engine "$@" &

export POOL_SIZE LP_CDP_URL="ws://127.0.0.1:${LP_PORT}/"
exec node /app/server.mjs
