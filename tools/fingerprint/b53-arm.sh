#!/bin/sh
# One arm of the B53 reading: is the door that is shut to this engine also shut
# to headed Chrome?
#
#   usage: b53-arm.sh <round> <chrome|lightpanda> [lightpanda-binary]
#
# The stations are the nine that B52's six ReleaseFast sweeps left at 0/3 on
# *both* lightpanda arms, plus ks-canadagoose, which straddled. B52 could only
# say "this engine does not get in"; it could not say whether anybody does, and
# a station Chrome also fails is not a gap in this engine -- chasing one is how
# B35 burned half a month. So the arms here are the two browsers, not two
# builds, and the answer wanted is a *rate*: three rounds, arm order flipped
# inside each round, so a guard that opens and shuts on its own clock cannot be
# read as a difference between the browsers.
#
# Both arms cold at every station: Chrome gets a fresh --user-data-dir, this
# engine a fresh `serve`, so nothing is carried in on a cookie. One station per
# invocation because --only takes a single substring; merge the per-station
# JSONs into one file per arm-round before feeding sweep-rate.mjs.
#
# Run the two arms of a round back to back and the three rounds back to back,
# and do not let a second sweep -- another session's included -- hit these
# stations while this is running: two clients at one guard from one address is
# exactly the noise the interleaving exists to remove.
set -e
ROUND=$1
ARM=$2
HERE=$(cd "$(dirname "$0")" && pwd)
OUT="$HERE/results/b53"
LP=${3:-$(cd "$HERE/../.." && pwd)/zig-out-rel/bin/lightpanda}
STATIONS="cf-scrapingcourse cf-nopecha cf-zeroclover dd-allopneus dd-g2 dd-saks dd-datadome dd-hermes x-hyatt ks-canadagoose"
mkdir -p "$OUT"
# A distinct port per (round, arm, station), so a stray server left behind by
# another session cannot be measured instead of ours.
case "$ARM" in chrome) BASE=13500;; *) BASE=13600;; esac
PORT=$((BASE + ROUND * 40))

for st in $STATIONS; do
    PORT=$((PORT + 3))
    echo "=== r$ROUND $ARM $st (port $PORT) $(date +%H:%M:%S)"
    if [ "$ARM" = chrome ]; then
        node "$HERE/antibot-sweep.mjs" chrome --headed \
            --port "$PORT" --only "$st" --out "$OUT/$ARM-$ROUND-$st.json" \
            > "$OUT/$ARM-$ROUND-$st.log" 2>&1 || true
    else
        LP_BIN=$LP node "$HERE/antibot-sweep.mjs" lightpanda \
            --port "$PORT" --only "$st" --out "$OUT/$ARM-$ROUND-$st.json" \
            > "$OUT/$ARM-$ROUND-$st.log" 2>&1 || true
    fi
    node -e '
      const fs = require("fs");
      try {
          const s = JSON.parse(fs.readFileSync(process.argv[1], "utf8")).stations[0];
          console.log(`    -> ${s.verdict} first=${s.first} last=${s.last} nodes=${s.nodes} title=${JSON.stringify(s.title)}`);
      } catch (e) { console.log("    -> NO OUTPUT: " + e.message); }
    ' "$OUT/$ARM-$ROUND-$st.json"
done
echo "ARM DONE r$ROUND $ARM $(date +%H:%M:%S)"
