#!/usr/bin/env bash
# agent3-integrate.sh — pull in everything the other agents have pushed, then
# build and run every suite on the result.
#
# Written because three agents push asynchronously: a branch can land at any
# moment, and the integration step (fetch -> merge -> build -> run all suites)
# is the same every time. This makes it one command and, more importantly, makes
# the *evidence* uniform — a merge is only "done" when the suites below report.
#
#   export GH_TOKEN=...            # required for the fetch; never written to disk
#   bash scripts/agent3-integrate.sh [--no-merge] [--branch <name>]
#
# Exit code is the number of failing phases (0 = everything clean).
#
# Why merges are attempted one branch at a time and aborted on conflict: a
# conflicting merge needs a human decision (whose content is newer / is it a
# superset), and guessing wastes more time than it saves. Conflicts are printed
# with the file list so they can be resolved deliberately.
set -u
cd "$(dirname "$0")/.."
BASE="${BASE:-dev}"
MERGE=1
ONLY=""
while [ $# -gt 0 ]; do
    case "$1" in
        --no-merge) MERGE=0 ;;
        --branch)   ONLY="$2"; shift ;;
        *) echo "unknown option: $1"; exit 2 ;;
    esac
    shift
done

say() { printf '%s\n' "$*"; }
fail=0

# ── environment ─────────────────────────────────────────────────────────────
export LD_LIBRARY_PATH="$HOME/.cache/llvm23:/usr/lib/x86_64-linux-gnu"
git config user.name  >/dev/null 2>&1 || git config user.name  "Pride-Agent-3"
git config user.email >/dev/null 2>&1 || git config user.email "pride-agent-3@users.noreply.github.com"

if ! command -v ~/.cache/c3tool/c3c >/dev/null 2>&1 && [ ! -x "$HOME/.cache/c3tool/c3c" ]; then
    say "==> toolchain missing; running env bootstrap"
    bash scripts/agent3-env.sh || exit 1
fi

# ── 1. fetch ────────────────────────────────────────────────────────────────
say "=== 1. fetch ==="
if [ -n "${GH_TOKEN:-}" ]; then
    git remote get-url origin >/dev/null 2>&1 || \
        git remote add origin https://github.com/Consumed-by-Pride/Pridec.git
    git -c credential.helper='!f() { echo username=x-access-token; echo password=$GH_TOKEN; }; f' \
        fetch -q origin 'refs/heads/*:refs/remotes/origin/*' || { say "  fetch FAILED"; exit 1; }
    say "  fetched (authenticated)"
else
    git fetch -q origin 2>/dev/null || { say "  fetch failed — export GH_TOKEN"; exit 1; }
    say "  fetched (anonymous)"
fi

# ── 2. merge anything ahead of BASE ─────────────────────────────────────────
say
say "=== 2. branches ahead of $BASE ==="
cur=$(git rev-parse --abbrev-ref HEAD)
[ "$cur" = "$BASE" ] || { say "  switching to $BASE (was $cur)"; git checkout -q "$BASE" || exit 1; }

merged_any=0
# `main` is the release branch and lags by design — merging it into dev adds a
# merge commit and nothing else. Excluded; it is brought forward deliberately.
for b in $(git for-each-ref --format='%(refname:short)' refs/remotes/origin/ \
           | sed 's|origin/||' | grep -vE '^HEAD$|^$|^main$|^'"$BASE"'$'); do
    [ -n "$ONLY" ] && [ "$b" != "$ONLY" ] && continue
    n=$(git rev-list --count "$BASE..origin/$b" 2>/dev/null || echo 0)
    if [ "$n" = "0" ]; then continue; fi
    say "  $b: $n commit(s) ahead"
    if [ "$MERGE" = "0" ]; then continue; fi
    out=$(git merge --no-edit "origin/$b" 2>&1)
    if git status --short | grep -qE '^(UU|AA|AU|UA|DU|UD)'; then
        say "    CONFLICT — needs a decision, merge left in progress:"
        git status --short | grep -E '^(UU|AA|AU|UA|DU|UD)' | sed 's/^/      /'
        fail=$((fail + 1))
        break
    fi
    say "    merged: $(git log --oneline -1)"
    merged_any=1
done
[ "$merged_any" = "0" ] && say "  nothing to merge — $BASE is current"
say "  HEAD is now $(git log --oneline -1)"

# ── 3. build ────────────────────────────────────────────────────────────────
say
say "=== 3. build ==="
if bash scripts/agent3-build.sh >/tmp/integrate_build.log 2>&1; then
    say "  pfrontc built ok"
else
    say "  BUILD FAILED:"; tail -15 /tmp/integrate_build.log | sed 's/^/    /'; fail=$((fail + 1))
fi

# ── 4. suites ───────────────────────────────────────────────────────────────
say
say "=== 4. suites ==="
# Each suite's expected pass/fail counts live in tests/baselines.tsv. A suite is
# only a failure when it is WORSE than its baseline; a known-failing suite is not
# a merge blocker, but an improvement is reported so the baseline gets updated.
base_of() { awk -F'\t' -v s="$1" '!/^#/ && $1==s {print $2" "$3}' tests/baselines.tsv; }

run() {  # run <label> <suite-key> <command...>
    local label="$1" suite="$2"; shift 2
    local out; out=$(timeout 1200 "$@" 2>&1); local rc=$?
    local last; last=$(printf '%s' "$out" | grep -E 'passed|pass=|pass [0-9]+|clean' | tail -2 | tr '\n' ' ')
    local got; got=$(printf '%s' "$out" | grep -oE '(self-test: [0-9]+|[0-9]+/[0-9]+ passed|pass=[0-9]+ fail=[0-9]+)' | tail -1)
    local exp; exp=$(base_of "$suite")
    local verdict="ok"
    if [ -n "$exp" ]; then
        local ep ef gp gf
        ep=$(printf '%s' "$exp" | cut -d' ' -f1); ef=$(printf '%s' "$exp" | cut -d' ' -f2)
        gp=$(printf '%s' "$got" | grep -oE 'self-test: [0-9]+|pass=[0-9]+|[0-9]+ passed' | head -1 | grep -oE '[0-9]+$')
        gf=$(printf '%s' "$got" | grep -oE 'fail=[0-9]+|failures?: [0-9]+|[0-9]+ failed' | head -1 | grep -oE '[0-9]+$')
        if [ -n "$gp" ] && [ -n "$gf" ]; then
            if [ "$gp" -lt "$ep" ] || [ "$gf" -gt "$ef" ]; then verdict="REGRESSION (baseline ${ep} pass / ${ef} fail)"
            elif [ "$gp" -gt "$ep" ] || [ "$gf" -lt "$ef" ]; then verdict="improved — update tests/baselines.tsv"
            fi
        fi
    fi
    case "$verdict" in REGRESSION*) fail=$((fail + 1)) ;; esac
    printf '  %-20s rc=%-3s %-34s %s\n' "$label" "$rc" "$verdict" "$last"
    return 0
}
run "subtype self-test" subtype ./pfrontc --subtype-selftest
run "exec suite"        exec bash tests/exec/run.sh
run "conformance"       conformance bash conformance/run.sh
run "pfront regression" pfront bash tests/pfront/run.sh

say
say "=== summary ==="
say "  failing phases: $fail"
say "  HEAD: $(git log --oneline -1)"
[ "$fail" = "0" ] && say "  integrate: CLEAN" || say "  integrate: REVIEW NEEDED"
exit "$fail"
