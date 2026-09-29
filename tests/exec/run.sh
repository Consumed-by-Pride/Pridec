#!/usr/bin/env bash
# ============================================================================
# tests/exec/run.sh — execution suite for the CURRENT pipeline (pfrontc → PEAR).
#
# The older tests/run_exec.sh drives the legacy `./pride` compiler through
# llvm-as/opt/llc/ld.lld and cannot run at all without those tools. This suite
# covers the pipeline that actually ships:
#
#     .pie ──pfrontc──► AIR ──PEAR──► native ELF ──► run it ──► check result
#
# Every case is a .pie file carrying its own expectation:
#
#     -- EXPECT: <text>      stdout must equal <text>  (\n allowed, see below)
#     -- EXIT: <n>           process exit status must be <n>   (default 0)
#
# It also smoke-tests the emit configuration matrix, because a broken
# optimization tier is invisible until something tries to build: no test
# executed a compiled binary, which is how -O1/-O2 shipped crashing.
#
# Known-broken cases live in XFAIL.tsv (pattern<TAB>reason) rather than being
# annotated in 47 files. A case in XFAIL.tsv that starts passing is reported as
# XPASS and makes the suite fail, so the entry gets promoted instead of rotting.
#
# Usage:  bash tests/exec/run.sh [-v]
# Env:    PEAR_OPT=-O0|-O1|-O2   optimization tier for the case runs (default -O0)
#         TIMEOUT=5              seconds per program
# ============================================================================
set -u
cd "$(dirname "$0")/../.." || exit 2

BIN=./pfrontc
PEAR_OPT=${PEAR_OPT:--O2}
TIMEOUT=${TIMEOUT:-5}
VERBOSE=0
[ "${1:-}" = "-v" ] && VERBOSE=1

[ -x "$BIN" ] || { echo "build ./pfrontc first (make)"; exit 2; }

# Preflight: pfrontc links against a versioned libLLVM. If that library is not
# on the loader path every single case reports "no binary", which looks exactly
# like a compiler bug. Fail loudly and say what to do instead.
if ! "$BIN" /dev/null --quiet >/dev/null 2>&1; then
    lerr=$("$BIN" /dev/null --quiet 2>&1 | head -1)
    case "$lerr" in
        *"cannot open shared object"*|*"error while loading"*)
            echo "FATAL: $lerr"
            echo "pfrontc is linked against a libLLVM that is not on the loader path."
            echo "Build per A2A/todo.md, e.g.:"
            echo "  c3c compile --stdlib ~/c3lib pfront/*.c3 pfront/pear_ir/*.c3 pfront/theory/*.c3 \\"
            echo "    pfront/theory/*/*.c3 -L ~/.cache/llvm23 -l LLVM-23 -o pfrontc"
            echo "  export LD_LIBRARY_PATH=\$HOME/.cache/llvm23:\$LD_LIBRARY_PATH"
            exit 2 ;;
    esac
fi

XFAIL=tests/exec/XFAIL.tsv
pass=0; fail=0; xfail=0; xpass=0
declare -a fail_list=() xpass_list=()

# ── helpers ─────────────────────────────────────────────────────────────────
xfail_reason() { # $1 = case id, e.g. "pear/p01_return_42" or "02_fibonacci"
    [ -f "$XFAIL" ] || return 1
    while IFS=$'\t' read -r pat reason; do
        [ -z "$pat" ] && continue
        case "$pat" in \#*) continue ;; esac
        # shellcheck disable=SC2254
        case "$1" in $pat) printf '%s' "$reason"; return 0 ;; esac
    done < "$XFAIL"
    return 1
}

# decode \n / \t escapes in an EXPECT line
expect_of() { grep -m1 '^-- EXPECT:' "$1" | sed 's/^-- EXPECT: //'; }
exit_of()   { v=$(grep -m1 '^-- EXIT:' "$1" | sed 's/^-- EXIT: *//'); printf '%s' "${v:-0}"; }

record() { # $1=status $2=id $3=detail
    case "$1" in
        PASS)  pass=$((pass+1));  [ $VERBOSE = 1 ] && printf '  PASS   %-34s %s\n' "$2" "$3" ;;
        FAIL)  fail=$((fail+1));  fail_list+=("$2"); printf '  FAIL   %-34s %s\n' "$2" "$3" ;;
        XFAIL) xfail=$((xfail+1)); [ $VERBOSE = 1 ] && printf '  XFAIL  %-34s %s\n' "$2" "$3" ;;
        XPASS) xpass=$((xpass+1)); xpass_list+=("$2"); printf '  XPASS  %-34s %s\n' "$2" "$3" ;;
    esac
}

# ── 1. emit configuration matrix ────────────────────────────────────────────
# A tier that cannot emit an object is a broken build configuration, not a
# missing case. The canary stays small, but it does a loop and a recursive call:
# a "return 7"-only canary compiles on a toolchain linked against the wrong
# libLLVM, which is a real configuration we hit (attribute enum IDs differ
# between LLVM 19 and 23, so -O1/-O2 die in instcombine). Sum of fib(0..7) = 33.
echo "=== emit configuration matrix (canary: fib-sum loop, expect exit 33) ==="
canary=/tmp/pear_canary_$$.pie
printf 'fn fib(n: i64) -> i64 { if (n < 2) { return n; } return fib(n-1) + fib(n-2); }\nfn main(_) -> i64 { let mut s: i64 = 0; let mut i: i64 = 0; while (i < 8) { s = s + fib(i); i = i + 1; } return s; }\n' > "$canary"
for O in -O0 -O1 -O2; do
    id="cfg/$O"
    rm -f "${canary%.pie}"
    out=$("$BIN" "$canary" --emit-exe "$O" --quiet 2>&1)
    bin="${canary%.pie}"
    if [ ! -x "$bin" ]; then
        why=$(xfail_reason "$id") && status=XFAIL || status=FAIL
        record "$status" "$id" "no binary emitted${why:+ — $why}"
    else
        timeout "$TIMEOUT" "$bin" >/dev/null 2>&1; rc=$?
        if [ "$rc" = "33" ]; then
            if reason=$(xfail_reason "$id"); then
                record XPASS "$id" "emits and runs (exit 33) — remove XFAIL entry: $reason"
            else
                record PASS "$id" "emits and runs (exit 33)"
            fi
        else
            why=$(xfail_reason "$id") && status=XFAIL || status=FAIL
            record "$status" "$id" "emitted but exit=$rc (want 33)${why:+ — $why}"
        fi
    fi
    rm -f "$bin"
done
rm -f "$canary" "${canary%.pie}"

# ── 2. case runs ────────────────────────────────────────────────────────────
echo "=== execution cases (pipeline tier: $PEAR_OPT) ==="
cases=$(ls tests/exec/*.pie tests/exec/pear/*.pie 2>/dev/null | sort)
count=0
for f in $cases; do
    count=$((count+1))
    rel=${f#tests/exec/}
    id=${rel%.pie}
    bin=${f%.pie}

    want_out=$(expect_of "$f")
    want_rc=$(exit_of "$f")

    rm -f "$bin"
    cout=$("$BIN" "$f" --emit-exe "$PEAR_OPT" --quiet 2>&1)
    if [ ! -x "$bin" ]; then
        # distinguish compiler crash from a normal diagnostic
        if printf '%s' "$cout" | grep -q 'Out of bounds\|ERROR:'; then
            why="compiler crashed during emit"
        else
            why=$(printf '%s' "$cout" | grep -m1 -oE 'errors=[0-9]+' || echo 'no binary')
        fi
        if reason=$(xfail_reason "$id"); then record XFAIL "$id" "$why"
        else record FAIL "$id" "$why"; fi
        continue
    fi

    timeout "$TIMEOUT" "$bin" >/tmp/pear_out_$$ 2>/dev/null; rc=$?
    got_out=$(cat /tmp/pear_out_$$ 2>/dev/null)

    if [ $rc -eq 124 ]; then detail="TIMEOUT after ${TIMEOUT}s"
    elif [ $rc -eq 133 ]; then detail="SIGTRAP (exit 133)"
    elif [ $rc -eq 139 ]; then detail="SIGSEGV (exit 139)"
    elif [ $rc -ne "$want_rc" ]; then detail="exit=$rc want $want_rc"
    elif [ "$got_out" != "$want_out" ]; then detail="stdout mismatch: got '$(printf '%s' "$got_out" | head -c 40)' want '$(printf '%s' "$want_out" | head -c 40)'"
    else detail="ok (exit $rc)"; fi

    if [ "$detail" = "ok (exit $rc)" ] || [ "${detail#ok}" != "$detail" ]; then
        if reason=$(xfail_reason "$id"); then record XPASS "$id" "now passes (exit $rc) — remove XFAIL entry: $reason"
        else record PASS "$id" "$detail"; fi
    else
        if reason=$(xfail_reason "$id"); then record XFAIL "$id" "$detail"
        else record FAIL "$id" "$detail"; fi
    fi
    rm -f "$bin"
done
rm -f /tmp/pear_out_$$

echo "---"
echo "exec suite: pass=$pass fail=$fail xfail=$xfail xpass=$xpass  (cases=$count, tier=$PEAR_OPT)"
if [ ${#fail_list[@]} -gt 0 ]; then
    echo "unexpected failures:"; for c in "${fail_list[@]}"; do echo "  - $c"; done
fi
if [ ${#xpass_list[@]} -gt 0 ]; then
    echo "fixes landed — promote these out of XFAIL.tsv:"; for c in "${xpass_list[@]}"; do echo "  + $c"; done
fi
[ "$fail" -eq 0 ] && [ "$xpass" -eq 0 ]
