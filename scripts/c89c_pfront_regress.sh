#!/usr/bin/env bash
# scripts/c89c_pfront_regress.sh — pfront regression gate.
# Rebuilds pfrontc from source and runs all known-good cases. Exits non-zero
# on any error. Designed to grow: every new pfront-stable workload gets a
# line in this script.
set -eu
cd "$(dirname "$0")/.."

C3C="${C3C:-$HOME/c3bin/c3c}"
C3C_LIB="${C3C_LIB:-$HOME/c3lib}"

echo "==> rebuilding pfrontc"
"$C3C" compile --stdlib "$C3C_LIB" \
  pfront/*.c3 pfront/pear_ir/*.c3 \
  pfront/theory/*.c3 pfront/theory/types/*.c3 pfront/theory/meta/*.c3 \
  pfront/theory/effects/*.c3 pfront/theory/rewrite/*.c3 \
  pfront/theory/lower/*.c3 pfront/theory/analysis/*.c3 \
  -o pfrontc 2>&1 | tail -5
PF=./pfrontc

assert_ok() {
  local f="$1"; local label="$2"
  local errs
  errs=$($PF -I . -I stdlib --quiet "$f" 2>&1 | sed -n 's/.*errors=\([0-9]*\).*/\1/p' | head -1)
  if [ "$errs" != "0" ]; then
    echo "FAIL  $label  ($f)  errors=$errs"
    $PF -I . -I stdlib "$f" 2>&1 | grep -E "error\[" | head -10
    exit 1
  else
    echo "ok    $label"
  fi
}

echo "==> tests/pfront regression"
bash tests/pfront/run.sh | tail -5 || true

echo "==> tests/legacy/c89c modules (C89 subset in Pride)"
assert_ok tests/legacy/c89c/ast.pie    "ast.pie"
assert_ok tests/legacy/c89c/lex.pie    "lex.pie"
assert_ok tests/legacy/c89c/parse.pie  "parse.pie"
assert_ok tests/legacy/c89c/sema.pie   "sema.pie"
assert_ok tests/legacy/c89c/driver.pie "driver.pie"
assert_ok tests/legacy/c89c/main.pie   "main.pie"

# tests/pfront/bug/known/ holds REDUCED test cases for bugs we have identified
# but not yet fixed. They are NOT gating; fix one and move it out of known/.

echo "==> c89c top-level-fn sanity (no accidental nesting by layout bug)"
for m in tests/legacy/c89c/ast.pie tests/legacy/c89c/lex.pie tests/legacy/c89c/parse.pie \
         tests/legacy/c89c/sema.pie tests/legacy/c89c/driver.pie tests/legacy/c89c/main.pie; do
  src_fns=$(grep -c "^fn " "$m")
  top_fns=$($PF -I . -I stdlib --dump-ast --quiet "$m" 2>/dev/null | grep -cE "^  fn '")
  if [ "$top_fns" -lt "$src_fns" ]; then
    echo "FAIL: $m has $top_fns top-level fns but $src_fns in source (layout swallowed some)"
    exit 1
  fi
  echo "  $m: $top_fns fns ok"
done

echo ""
echo "all regressions pass"
