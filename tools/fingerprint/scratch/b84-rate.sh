#!/bin/bash
# Ticket rate for one knob over N runs. The verdict is a rate, not a decision --
# Chrome sits near 90% -- so a knob has to be counted, not sampled twice.
#   b84-rate.sh <engine> <knob> <n> <portbase>
eng="$1"; knob="$2"; n="$3"; base="$4"
hit=0
for i in $(seq 1 "$n"); do
  line=$(LP_BIN="${LP_BIN}" node kasada-knob.mjs "$eng" --knob "$knob" \
    --url https://www.hyatt.com/ --port $((base + i)) --settle 16000 2>&1 | head -1)
  # `r=1-...` only; a plain `r=` also matches `cr=true`, which counted every run.
  if echo "$line" | grep -qE 'r=1-[A-Za-z0-9_-]+'; then hit=$((hit+1)); mark=T; else mark=.; fi
  printf '%s' "$mark"
done
echo "  ${eng}/${knob}: ${hit}/${n}"
