#!/bin/bash
# Lowering coverage over every .pie in the repo's test directories: which programs lower
# to a low-profile .air, and for the rest, the first reason.  Usage: low_stat.sh [OUT.tsv]
cd "$(dirname "$0")/../.." || exit 2
out=${1:-tmp/lowstat.tsv}; mkdir -p tmp /tmp/lowstat; : > "$out"
for f in tests/pfront/*.pie tests/lowering/*.pie tests/conformance/*.pie tests/exec/*.pie tests/exec/pear/*.pie examples/*.pie; do
  [ -f "$f" ] || continue
  rm -f /tmp/lowstat/s.low.air
  o=$(PFRONT_LOW_OUT=/tmp/lowstat/s.low.air timeout 30 ./pfrontc "$f" --emit-air-low --quiet 2>&1)
  src=/tmp/lowstat/s.low.air
  if echo "$o" | grep -q "air-low: error"; then r=$(echo "$o" | grep -m1 "air-low: error" | sed 's/.*in `[^`]*`: //' | cut -c1-90)
  elif echo "$o" | grep -qE "refusing to emit|errors=[1-9]"; then r=FRONT
  elif echo "$o" | grep -q "function(s) lowered"; then
    if tmp/airtool verify-low "$src" >/dev/null 2>&1; then r=OK; else r=VERIFY; fi
  else r="OTHER $(echo "$o" | head -1 | cut -c1-60)"; fi
  printf '%s\t%s\n' "$f" "$r" >> "$out"
done
cut -f2 "$out" | sort | uniq -c | sort -rn
