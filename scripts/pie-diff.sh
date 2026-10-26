#!/usr/bin/env bash
# ============================================================================
# scripts/pie-diff.sh — differential execution harness: pear1c vs pear2c.
#
#   every tests/exec/pear/p*.pie
#     x { -O0, -O1, -O2, -O3 }
#     x { legacy/pear1/pear1c  (reference, full language)
#         pear2/pear2c         (backend under test, documented subset) }
#
#   .pie --pfrontc--> .air --backend--> executable --> run --> (exit status, stdout)
#
# The .air is produced ONCE per (fixture, opt) and handed to both backends, so
# the comparison is backend-vs-backend on identical input, not front-end noise.
#
# Output: a deterministic ledger (CSV + Markdown) and a gate that fails only on
# ledger rows missing from the checked-in baseline. See
# scripts/pie-diff-report.py for the verdict vocabulary and gate semantics.
#
# Usage:
#   scripts/pie-diff.sh                 run the matrix, write the ledger to tmp/
#   scripts/pie-diff.sh --check         run the matrix and gate against the baseline
#   scripts/pie-diff.sh --bless         run the matrix and record it as the baseline
#   scripts/pie-diff.sh --gate-only     re-judge the records a previous run left
#                                       in $DIFF_WORK against the baseline; no compiles
#
# Env:
#   PFRONTC=./pfrontc
#   PEAR1C=legacy/pear1/pear1c
#   PEAR2C=pear2/pear2c
#   DIFF_OPT="-O0 -O1 -O2 -O3"
#   DIFF_TIMEOUT=10          seconds per executed program
#   DIFF_JOBS=2              parallel cells (ledger order is sorted, so this
#                            changes wall time only, never the output)
#   LLVM23_BIN, LLVM23_LIBDIR, PEAR2_CLANG, LD_LIBRARY_PATH   toolchain
#
# Fail-closed rules this harness enforces on itself:
#   * a missing compiler or a missing toolchain is a hard error (exit 2), never
#     an empty ledger that would "pass" the gate by matching nothing;
#   * a backend that exits 0 but publishes no executable is recorded as
#     `noartifact`, not as a pass (CONTRACT.md section 1 forbids the artifact
#     surviving a failure);
#   * an output binary from a previous cell is deleted before the backend runs.
# ============================================================================
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT" || exit 2
export LC_ALL=C

PFRONTC=${PFRONTC:-./pfrontc}
PEAR1C=${PEAR1C:-legacy/pear1/pear1c}
PEAR2C=${PEAR2C:-pear2/pear2c}
FIXTURE_GLOB=${FIXTURE_GLOB:-'tests/exec/pear/p*.pie'}
SUBSET_FILE=${SUBSET_FILE:-tests/exec/pear2_cases.txt}
BASELINE=${BASELINE:-tests/exec/DIFF_BASELINE.csv}
MD_OUT=${MD_OUT:-tests/exec/DIFF_BASELINE.md}
DIFF_OPT=${DIFF_OPT:--O0 -O1 -O2 -O3}
DIFF_TIMEOUT=${DIFF_TIMEOUT:-10}
DIFF_JOBS=${DIFF_JOBS:-$(nproc 2>/dev/null || echo 2)}
WORK=${DIFF_WORK:-tmp/pie-diff}
case "$WORK" in /*) ;; *) WORK="$ROOT/$WORK" ;; esac   # absolute: cells run with their own cwd
CELLS="$WORK/cells"
META=()   # filled by main(); --meta args for the report engine

MODE=run
case "${1:-}" in
    --check)     MODE=check ;;
    --bless)     MODE=bless ;;
    --gate-only) MODE=gate-only ;;
    ""|--run)    MODE=run ;;
    -h|--help)   sed -n '3,42p' "$0"; exit 0 ;;
    *)           echo "pie-diff: unknown option '$1' (try --help)" >&2; exit 2 ;;
esac

report() { # report <args...> — the ledger engine; python3 keeps it deterministic
    python3 scripts/pie-diff-report.py "$@"
}

# ── 1. preflight: never run a matrix against a missing tool ──────────────────
# A missing binary must not degrade into "0 fixtures, gate passes".
preflight() {
    local missing=0
    [ -x "$PFRONTC" ] || { echo "pie-diff: front end not built at $PFRONTC (make)" >&2; missing=1; }
    [ -x "$PEAR1C" ]  || { echo "pie-diff: reference backend not built at $PEAR1C (make legacy-pear)" >&2; missing=1; }
    [ -x "$PEAR2C" ]  || { echo "pie-diff: backend under test not built at $PEAR2C (make pear2c)" >&2; missing=1; }
    [ -f "$SUBSET_FILE" ] || { echo "pie-diff: subset list missing at $SUBSET_FILE" >&2; missing=1; }
    command -v python3 >/dev/null || { echo "pie-diff: python3 required" >&2; missing=1; }
    # A backend linked against an absent libLLVM prints a loader error instead of
    # compiling, which would look like 300 rejects rather than a bad environment.
    local b lerr
    for b in "$PEAR1C" "$PEAR2C"; do
        [ -x "$b" ] || continue
        lerr=$("$b" 2>&1 | head -1)
        case "$lerr" in
            *"cannot open shared object"*|*"error while loading"*)
                echo "pie-diff: $b cannot load its LLVM runtime: $lerr" >&2
                echo "pie-diff: export LD_LIBRARY_PATH=\$HOME/.cache/llvm23:\$LD_LIBRARY_PATH" >&2
                missing=1 ;;
        esac
    done
    # PEAR2 links a native executable with LLVM clang; without it every case
    # reports a link failure that is really a missing tool.
    if [ -x "$PEAR2C" ]; then
        local clang=${PEAR2_CLANG:-${LLVM23_BIN:-}/clang}
        [ -n "$clang" ] && [ -x "$clang" ] || clang=$(command -v clang || true)
        if [ -z "$clang" ]; then
            echo "pie-diff: LLVM clang not found (set PEAR2_CLANG or LLVM23_BIN)" >&2
            missing=1
        else
            export PEAR2_CLANG=${PEAR2_CLANG:-$clang}
        fi
        if [ -n "${LLVM23_LIBDIR:-}" ]; then
            export LD_LIBRARY_PATH="$LLVM23_LIBDIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
        fi
    fi
    [ "$missing" -eq 0 ] || exit 2
    # shellcheck disable=SC2086
    set -- $FIXTURE_GLOB
    [ -f "${1:-}" ] || { echo "pie-diff: no fixtures match $FIXTURE_GLOB" >&2; exit 2; }
}

# ── 2. one cell: (fixture, opt, backend) -> one .rec record ──────────────────
# Written as a function so `--jobs 1` and `--jobs N` run identical code.
run_cell() { # $1=fixture $2=opt $3=backend $4=subset(yes|no)
    local src=$1 opt=$2 backend=$3 subset=$4
    local name; name=$(basename "$src" .pie)
    local bin
    case "$backend" in
        pear1c) bin=$PEAR1C ;;
        pear2c) bin=$PEAR2C ;;
    esac
    local dir="$WORK/$name/$opt/$backend"
    local rec="$CELLS/$name|$opt|$backend.rec"
    local air_src="$WORK/$name/$opt/prog.air"
    # $dir/$rec/$air_src all derive from $WORK, which is absolute (see the top of
    # this file): the program runs with its own directory as cwd, so a relative
    # redirect target would resolve somewhere else entirely.
    local out="$dir/out.txt" log="$dir/compile.log"
    rm -rf "$dir"; mkdir -p "$dir"

    local compile_rc run_rc="-" artifact=no stdout_hash="-" stdout_bytes=0 diag=""
    local want; want=$(want_exit_of "$src")

    if [ ! -f "$air_src" ]; then
        # The front end refused this fixture at this tier: there is nothing for
        # either backend to consume. Recorded once per backend so the ledger has
        # a full matrix either way.
        compile_rc=front-noartifact
        [ -f "$WORK/$name/$opt/front.log" ] || compile_rc=front-error
        diag=$(first_diag "$WORK/$name/$opt/front.log")
    else
        cp "$air_src" "$dir/prog.air"
        rm -f "$dir/prog"
        "$bin" "$dir/prog.air" --emit-exe "$opt" --quiet >"$log" 2>&1
        compile_rc=$?
        if [ -x "$dir/prog" ]; then
            artifact=yes
            # A backend may legitimately exit 1 for warnings while publishing the
            # artifact (pie-exe.sh relies on that), so the artifact is the truth
            # about "did it build" and the rc is recorded alongside it.
            ( cd "$dir" && timeout "$DIFF_TIMEOUT" ./prog >"$out" 2>/dev/null )
            run_rc=$?
            stdout_hash=$(sha256sum "$out" 2>/dev/null | cut -c1-16)
            stdout_bytes=$(wc -c <"$out" 2>/dev/null | tr -d ' ')
            [ -n "$stdout_hash" ] || stdout_hash="-"
            [ "$stdout_bytes" = "0" ] && stdout_hash="-"
            # A ledger is only a baseline if it is reproducible, so a program
            # that does not repeat itself is recorded as such instead of being
            # frozen at whatever it happened to return this time. Found for
            # real: p119_slice_len_read's slice reads return garbage on pear1c,
            # and the value differs run to run.
            ( cd "$dir" && timeout "$DIFF_TIMEOUT" ./prog >"$out.2" 2>/dev/null )
            local rc2=$? hash2 rc1=$run_rc hash1=$stdout_hash
            hash2=$(sha256sum "$out.2" 2>/dev/null | cut -c1-16)
            [ -n "$hash2" ] || hash2="-"
            [ "$(wc -c <"$out.2" 2>/dev/null | tr -d ' ')" = "0" ] && hash2="-"
            if [ "$rc2" != "$rc1" ] || [ "$hash2" != "$hash1" ]; then
                diag="second run differed: rc $rc1 -> $rc2, stdout $hash1 -> $hash2"
                run_rc=nondeterministic
                stdout_hash=nondeterministic
                stdout_bytes=nondeterministic
            fi
            rm -f "$out.2"
        else
            diag=$(first_diag "$log")
            # CONTRACT.md section 1: exit 0 with no artifact is a backend defect.
            if [ "$compile_rc" -lt 2 ] && [ -z "$diag" ]; then
                diag="exit $compile_rc but no executable at $dir/prog"
            fi
        fi
    fi

    {
        echo "fixture=$name"
        echo "opt=$opt"
        echo "backend=$backend"
        echo "subset=$subset"
        echo "want_exit=$want"
        echo "compile_rc=$compile_rc"
        echo "artifact=$artifact"
        echo "run_rc=$run_rc"
        echo "stdout_hash=$stdout_hash"
        echo "stdout_bytes=$stdout_bytes"
        echo "diag=$diag"
    } >"$rec"
}

# The fixture's own declared expectation (`-- EXIT: n`). Comparing against it is
# what stops the harness from blessing a matrix where BOTH backends miscompile
# identically: a differential-only ledger calls that `match`.
want_exit_of() { # $1=fixture path -> declared exit code, or `none`
    local v
    v=$(grep -m1 '^-- EXIT:' "$1" 2>/dev/null | sed 's/^-- EXIT: *//' | tr -d ' \r')
    printf '%s' "${v:-none}"
}

# The first line that actually explains the failure. Backend diagnostics are
# `file:line:col: message` (CONTRACT.md section 1); the front end writes
# `file:line:col: error [E3001/module] ...`. A bare "error" line from clang or
# the loader is still more useful than nothing. Paths are made repo-relative so
# the ledger stays machine-independent.
first_diag() { # $1=log file
    local log=${1:-} line
    [ -f "$log" ] || { printf ''; return 0; }
    line=$(grep -m1 -E '^[^ ]+:[0-9]+:[0-9]+: *(error|Error|ERROR)' "$log" 2>/dev/null)
    [ -n "$line" ] || line=$(grep -m1 -E '^[^ ]*:[0-9]+:[0-9]+:' "$log" 2>/dev/null)
    [ -n "$line" ] || line=$(grep -m1 -iE 'error|unsupported|reject|cannot|no such|front-end rc=' "$log" 2>/dev/null)
    [ -n "$line" ] || line=$(head -1 "$log" 2>/dev/null)
    printf '%s' "$line" | tr -d '\r' | tr '\t' ' ' | cut -c1-200 \
        | sed -e "s#$ROOT/##g" -e "s#$WORK/##g"
}

# ── 3. front end: one .air per (fixture, opt), shared by both backends ───────
# Compiled IN PLACE at the fixture's real path, then the .air is moved into the
# work dir. Two reasons, both about not lying in the ledger:
#   * the .air header and every diagnostic carry the real source path, so a
#     `file:line:col` in the ledger points at a file the reader can open;
#   * module resolution is identical to tests/exec/pear/run.sh (the loader's
#     search roots are the repo root, `stdlib/`, and the input's directory), so
#     the harness cannot pass a fixture the real suite would fail.
# It therefore runs serially: two cells of one fixture would race on the shared
# `<fixture>.air` path. Serial front end is also what makes the .air inputs
# bit-identical for both backends.
front_end() { # $1=fixture $2=opt
    local src=$1 opt=$2
    local name; name=$(basename "$src" .pie)
    local dir="$WORK/$name/$opt"
    # pfrontc writes the .air next to the source with .pie replaced by .air, so
    # the extension must be stripped: "$src.air" would be "<name>.pie.air".
    local air="${src%.pie}.air"
    rm -rf "$dir"; mkdir -p "$dir"
    rm -f "$air"
    # --plain: one-line `file:line:col: error [E####/pass] message` diagnostics,
    # which is what the ledger's diag column wants (no multi-line snippets).
    "$PFRONTC" "$src" --emit-air --plain "$opt" >"$dir/front.log" 2>&1
    local rc=$?
    # A stale .air must never reach a backend after a failed front end. The
    # artifact is the truth, not the exit status: rc=1 means "warnings", and
    # pie-exe.sh proceeds on it too.
    if [ ! -f "$air" ]; then
        echo "front-end rc=$rc, no .air for $src" >>"$dir/front.log"
    else
        mv "$air" "$dir/prog.air"
    fi
}

is_in_subset() { # $1=fixture path
    grep -Fqx "$1" "$SUBSET_FILE" 2>/dev/null
}

main() {
    preflight
    rm -rf "$WORK"; mkdir -p "$CELLS"

    local fixtures=() f
    # shellcheck disable=SC2086
    for f in $FIXTURE_GLOB; do [ -f "$f" ] && fixtures+=("$f"); done
    # Sort so the work order (and therefore any partial-failure output) is stable.
    IFS=$'\n' fixtures=($(printf '%s\n' "${fixtures[@]}" | sort)); unset IFS

    local opts=() o
    # shellcheck disable=SC2086
    for o in $DIFF_OPT; do opts+=("$o"); done

    echo "pie-diff: ${#fixtures[@]} fixtures x ${#opts[@]} tiers x 2 backends"
    echo "pie-diff: reference=$PEAR1C  under-test=$PEAR2C  timeout=${DIFF_TIMEOUT}s jobs=$DIFF_JOBS"

    # Front end first: it is shared by both backends, and a fixture it rejects
    # must not be retried per backend. Serial (see front_end).
    for f in "${fixtures[@]}"; do
        for o in "${opts[@]}"; do
            front_end "$f" "$o" 2>/dev/null
        done
    done

    # Backends. Cell order is fixture-major so a partial run still leaves whole
    # fixtures behind; the ledger itself is sorted by the report engine.
    local cells=()
    for f in "${fixtures[@]}"; do
        local subset=no
        is_in_subset "$f" && subset=yes
        for o in "${opts[@]}"; do
            cells+=("$f|$o|pear1c|$subset")
            cells+=("$f|$o|pear2c|$subset")
        done
    done

    n=0
    local cell
    for cell in "${cells[@]}"; do
        IFS='|' read -r cf co cb cs <<<"$cell"
        # `&` only when parallelism was actually asked for: with --jobs 1 an
        # unbatched background spawn would launch the whole matrix at once and
        # the compilers would die of resource exhaustion, which the ledger would
        # then report as hundreds of rejects.
        if [ "$DIFF_JOBS" -gt 1 ]; then
            run_cell "$cf" "$co" "$cb" "$cs" >/dev/null 2>&1 &
            n=$((n + 1))
            if [ $((n % DIFF_JOBS)) -eq 0 ]; then wait; fi
        else
            run_cell "$cf" "$co" "$cb" "$cs" >/dev/null 2>&1
        fi
    done
    wait

    # One --meta per value: these are argv items, so a value containing spaces
    # must stay inside a single argument.
    META=(
        --meta "pear1c=$PEAR1C" --meta "pear2c=$PEAR2C"
        --meta "timeout=$DIFF_TIMEOUT" --meta "subset_file=$SUBSET_FILE"
        --meta "opt_levels=${opts[*]}"
    )
    # A matrix that produced no records must not print a success line: an empty
    # ledger would otherwise be indistinguishable from an all-agreeing one.
    report --cells "$CELLS" --csv-out "$WORK/ledger.csv" --md-out "$WORK/ledger.md" "${META[@]}" || exit 1
    echo "pie-diff: ledger written to $WORK/ledger.csv (+ .md)"
}

case "$MODE" in
    run)
        main
        ;;
    check)
        main
        report --cells "$CELLS" --gate --baseline "$BASELINE" "${META[@]}"
        ;;
    bless)
        main
        report --cells "$CELLS" --csv-out "$WORK/ledger.csv" --md-out "$MD_OUT" \
               --bless --baseline "$BASELINE" "${META[@]}"
        echo "pie-diff: checked in: $BASELINE and $MD_OUT"
        ;;
    gate-only)
        # Re-judges the records a previous run left in $CELLS without recompiling.
        [ -d "$CELLS" ] && [ -n "$(ls -A "$CELLS" 2>/dev/null)" ] \
            || { echo "pie-diff: no cell records under $CELLS; run without --gate-only first" >&2; exit 2; }
        report --cells "$CELLS" --gate --baseline "$BASELINE"
        ;;
esac
