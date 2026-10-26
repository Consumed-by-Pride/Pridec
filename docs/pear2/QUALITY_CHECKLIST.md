# PEAR 2 quality checklist (release gate for backend slices)

Ordered checklist run before any backend slice is considered done. Every item
must either pass with evidence or carry a filed issue. Ordered, do not skip.

## 0. Workspace and tooling

- [x] Bootstrap pins intact: `scripts/bootstrap-pear2-llvm23.sh`; llvm-runtime
      23.1.3, C3 0.8.4. Toolchain resolves from `~/.cache/c3src` +
      `~/.cache/llvm23` (the `~/c3bin` fallback is auto-refetched by
      `make c3c` when absent).
- [x] Workspace under snapshot budget (~28 MB after pruning the regenerable
      `c3bin`/`c3lib` toolchain fallback, built `pfrontc`, and `tmp/` scratch).
- [x] Exec bits survive edits: `git ls-files -s | awk '$1=="100755"{print $4}'`
      — hydration had stripped them once (root cause of "no binary" exec
      failures); restored and now guarded by test runs touching each script.

## 1. Build and suite gates (all required, current results 2026-10-26)

- [x] `make check-pear2` — PASS (syntax + signed-division model).
- [x] `make test-pear2` — **107 PASS / 0 FAIL**
      (scalar/control/aggregate/memory/phi/closure/target/effect fixtures,
      -O0..-O3 sweeps, positioned rejects, external aggregate ABI fixture).
- [x] `make test-pear2-exec` — pass=9 fail=0 (xfail 0).
- [x] `make test-pfront` — pass=173 fail=5 (the 5 are the recorded known
      baseline; unchanged by backend work).
- [x] `make test-conform` — pass=162 fail=100 (recorded baseline).
- [ ] Triage the 5 pfront + 100 conform known failures into an explicit
      accepted-baseline list with reasons, or fix (issue filed in Linear).

## 2. Fail-closed behavior

- [x] Unsupported forms exit 3 with `file:line:col` and publish no artifact
      (reject fixtures assert the position regex and stale-artifact cleanup).
- [x] M10: unknown attributes / calling conventions, main pinning,
      handler-less performs, multi-shot handlers, wasm32 effects all reject
      positioned rather than silently dropping markers.
- [x] CLI usage/flag errors exit 2; `--target=wasm32-freestanding` executable
      mode denies with guidance.

## 3. Determinism and cross-level equivalence

- [x] Every positive exec fixture runs identical exit codes over
      -O0/-O1/-O2/-O3 (run.sh enforces per fixture).
- [x] Default `--target=x86_64` output layout is unchanged by the target
      profile machinery (pointer-width sites default to 64-bit/8-byte).

## 4. Documentation consistency

- [x] `docs/pear2/CONTRACT.md` aggregate ABI boundary statement matches the
      checked-in `external_record_abi_*` fixtures (verified exit 42 at
      -O0..-O3).
- [x] `docs/pear2/IMPLEMENTATION_PLAN.md` M1–M3 wording matches the committed
      backend; M4 effects language matches the M10 escape-only subset +
      positioned rejections.
- [x] README/LLVM23_SETUP document every new flag, fixture, and rejection
      class added in the slice.

## 5. Git hygiene

- [x] No stray uncommitted files: the `external_record_abi_*` fixtures are now
      wired into run.sh and tracked; CONTRACT/PLAN doc updates are committed
      with this checklist; `git status` is clean.
- [x] Commit author Ayon; no force-push; only `arena/fd318e2a-pridec` is pushed.
- [ ] **BLOCKED — push pending credentials**: local commits 5dec6b1 (M9/M8),
      0555d69 (M10), and the hygiene commit sit on top of remote tip ad9481f;
      the PAT authenticates as Hubris-tic which lacks write access (403 ×2).
      Needs repo write for that account or a new PAT; both chat-exposed tokens
      must be rotated. Tracked in Linear.
