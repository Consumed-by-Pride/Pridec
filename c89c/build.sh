#!/bin/bash
# c89c/build.sh — concatenate modules into a single file for the legacy ./pride compiler
# (which doesn't support multi-file modules). pfront parses the multi-file layout.
set -e
cd "$(dirname "$0")/.."
{
  echo "-- c89c: auto-combined single-file build for legacy pride"
  echo "mod c89c_main;"
  # de-duplicate use statements by emitting the necessary ones once
  grep -h "^use " c89c/*.pie | sort -u
  # emit all module content stripped of `mod X;` and `use ...` lines and duplicated const/struct defs
  for f in c89c/ast.pie c89c/lex.pie c89c/parse.pie c89c/driver.pie c89c/main.pie; do
    echo ""
    echo "// ---- $f ----"
    grep -v "^mod " "$f" | grep -v "^use "
  done
} > c89c/_combined.pie
echo "wrote c89c/_combined.pie"