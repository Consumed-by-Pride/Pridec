#!/usr/bin/env bash
# Lower every stdlib module as a library through the low chain; one row per module: file<TAB>result.
# Usage: tests/air3/stdlib_stat.sh [OUT.tsv]   (default tmp/stdstat.tsv); prints a histogram of first errors.
cd "$(dirname "$0")/../.." || exit 1
out=${1:-tmp/stdstat.tsv}; mkdir -p tmp; tmpd=$(mktemp -d); : > "$out"
for f in $(find stdlib -name "*.pie" | sort); do
  rm -f "$tmpd/s.low.air"
  o=$(PFRONT_LOW_OUT="$tmpd/s.low.air" timeout 30 ./pfrontc "$f" --emit-air-low --quiet 2>&1)
  if echo "$o" | grep -q "air-low: error"; then
    r=$(echo "$o" | grep -m1 "air-low: error" | sed 's/air-low: error: [0-9]*:[0-9]*: in `[^`]*`: //' | cut -c1-80)
  elif echo "$o" | grep -qE "refusing to emit|errors=[1-9]"; then r=FRONT
  elif echo "$o" | grep -q "function(s) lowered"; then
    if tmp/airtool verify-low "$tmpd/s.low.air" >/dev/null 2>&1; then
      # LLVM must accept the module too: emit .ll, parse + verify + optimise + write an object (no link)
      if tmp/airtool emit-ll "$tmpd/s.low.air" -o "$tmpd/s.ll" >/dev/null 2>&1 && python3 scripts/ll-exe.py "$tmpd/s.ll" -o "$tmpd/s.o" -O2 --emit-obj >"$tmpd/ll.err" 2>&1; then r=OK
      else r="LLVM $(head -c 120 "$tmpd/ll.err" | head -1)"; fi
    else r=VERIFY; fi
  else r="OTHER $(echo "$o" | head -1 | cut -c1-50)"; fi
  printf '%s\t%s\n' "$f" "$r" >> "$out"
done
rm -rf "$tmpd"
cut -f2 "$out" | sort | uniq -c | sort -rn | head -${TOP:-30}
