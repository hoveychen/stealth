#!/bin/sh
# Starts `lightpanda serve` from environment defaults. Arguments that start
# with "-" are appended to the serve command line (so `docker run IMAGE
# --log-level debug` works); anything else is executed as given (so
# `docker run IMAGE lightpanda version` or `sh` works).
#
# Never add --obey-robots, --web-bot-auth-* or --webmcp here: each one
# announces the client as a bot (see AGENTS.md).
set -e

case "$1" in
  "" | -*)
    exec /bin/lightpanda serve \
      --host "${LP_HOST:-0.0.0.0}" \
      --port "${LP_PORT:-9222}" \
      --cdp-max-connections "${LP_CDP_MAX_CONNECTIONS:-128}" \
      --log-level "${LP_LOG_LEVEL:-info}" \
      "$@"
    ;;
  *)
    exec "$@"
    ;;
esac
