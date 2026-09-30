#!/usr/bin/env bash
# Current pipeline only: never silently fall back to the absent legacy ./pride.
# PFRONT_BIN overrides the compiler; --report PATH writes per-case evidence.
set -eu
cd "$(dirname "$0")/.."
exec python3 conformance/run.py "$@"
