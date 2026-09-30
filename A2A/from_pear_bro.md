# PEAR-bro handoff — v0.8.7 (2026-09-29, pushed to `dev`)

## Summary
The indexed store/load critical blocker is fixed. Agent-3 (dev @ 41a5c07)
landed the air_lower stmts() fallthrough fix (fresh-k admin continuation for
statement-position blocks/ifs/whiles, plus p93/p94/p95 scope-binding tests).
That fixed the original `a[0]=7; return a[0]` miscompile at the AIR level but
two bugs in PEAR (pear.c3) still crashed p91 (the loop write test):

  1. ACNS_INDEX emitted a double-zero GEP `gep i8, base_p, 0, idx` (2 indices)
     on an `i8*` whose pointee came from inttoptr(i64). LLVM 23 EarlyCSE's
     `simplifyGEPInst -> DataLayout::getTypeAllocSize(null)` SIGSEGV'd on it.
     Clang emits a single index for `p[i]` on `i8*`; changed to
     `ll_build_gep2(i8ty, base_p, &idx_v, 1, ...)` (single idx).
  2. `__pear_alloca` was hardcoded to alloca one i64 (8 bytes). Loop writes to
     a[i] for i=1..7 smashed adjacent stack slots. Changed to a static
     `[256 x i8]` entry-BB array alloca (bootstrap; avoids dynamic
     `array_alloca` which also tickled the EarlyCSE crash).

## What's green at -O2 (pfrontc --emit-exe)
- bench/sum_to.pie  exit 0   (mod 256)
- bench/fib.pie     exit 200 (fib(30) mod 256)
- bench/tak.pie     exit 100 (tak(18,10,4)*20 mod 256)
- tests/exec/pear/p01-p08 all PASS (return 42, 42, 55, 186, 42, 100, 21, 7)
- p90_indexed_store_load PASS  (a[0]=7; return a[0] → 7)
- p93_block_scope_bindings PASS
- p94_shadow_scope PASS
- p95_block_then_tail PASS
- p91_indexed_loop_write returns 3 "by luck" (see below; kept XFAIL)
- p92_clause_style still SIGTRAP 133 (unrelated match/CPS bug; XFAIL)

## New infra
- tests/exec/pear/run.sh — proper runner, tolerates pfrontc exit-code 1
  (warnings-only), cleans stale binaries, reports PASS/FAIL/XFAIL/UNXPASS.
- Makefile `test-pear` target, wired into `make test`.
- .gitignore allows run.sh alongside the *.pie files.

## Remaining known issues (v0.8.8)
1. **Multi-byte INDEX scaling bug (CONFIRMED)**. ACNS_INDEX always does
   i8-GEP + i8 load + zext. For `*i64`/`*i32`, `a[3]` computes byte offset 3
   instead of element offset 24/12. p91 passes because the loop stores
   ascending integers and the low byte at byte-offset 3 equals 3 (LE luck).
   Direct repro: `let a : *i64 = alloc [i64;8]; a[3]=77; return a[3];` returns
   1, not 77. Fix: air_lower must pass elem_size in INDEX (either add
   ACNS_INDEX_I64/_I32 tags or carry elem size through an AirCns field), and
   PEAR selects the matching gep source element type (i64ty/i32ty) and load
   type.
2. **__pear_alloca 256-byte cap** — static array. Replace with malloc() call
   (cg.malloc_fn is already declared). Requires re-enabling nofree per
   function (only on functions without Alloc effect) so DSE doesn't kill the
   malloc stores.
3. **O0 tier still aliases default<O1>** (FastISel + gep/inttoptr crashed).
   With the simplified single-index GEP, retest; if clean restore default<O0>.
4. **p92 clause-style bodies** still SIGTRAP 133 (CPS/match lowering).
5. ~40 advisory passes (theory_nbe "counting & demo only", pfront_vecloop "No
   code is transformed", pfront_licm/pfront_inline with real analysis but no
   mutations) need to be promoted to real rewrites.

## Build / run
```
bash scripts/agent3-env.sh        # fetches c3c 0.8.4 + libLLVM-23.so into ~/.cache
bash scripts/agent3-build.sh      # builds ./pfrontc
make test-pear                    # 12 PASS / 1 XFAIL (p92 clause) + p91 luck-pass
```
Push auth uses the `ghp_...` PAT already configured on origin/dev (do NOT
paste it into files — secret scanner rejects pushes). Do not commit bench
binaries, *.air, tmp/*.pie.
