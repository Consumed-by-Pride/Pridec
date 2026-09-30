# PEAR-bro handoff — v0.8.8 (2026-09-30, pushed to `dev`)

## Summary
On top of v0.8.7 (fixed the stmts() fallthrough + EarlyCSE crash), this round
fixes the multi-byte INDEX scaling bug. AirCns.idx now carries the pointee
byte size (1/2/4/8). air_lower computes it from type annotations (`*u8→1`,
`*i32→4`, `*i64→8`, etc.) via `index_elem_size()` / `index_elem_size_for_deref()`
and passes it into `air_mk_index(i, esz, k)` and into ACNS_STORE via
`store_c.idx = esz`. pear.c3 ACNS_INDEX/ACNS_STORE select the correct
element LLVM type, bitcast the int-encoded pointer to that type, GEP with
scaled index, and trunc/zext/sext the value appropriately.

## What's green at -O2 (pfrontc --emit-exe) — 18 PASS / 1 XFAIL
- bench/sum_to=0, fib=200, tak=100 across O0/O1/O2
- p01-p08 scalars (return 42/42/55/186/42/100/21/7)
- p90 `a[0]=7; return a[0]` (u8 byte store/load) → 7
- p91 loop writes `a[i]=i` for i<8 on `*i64`, returns a[3] → 3 (now CORRECT,
  not LE luck)
- p93-p95 Agent-3's block-scope/shadow/block-then-tail tests
- p96-p98 Agent-3's while-return/while-break/many-bindings tests
- **p99 i64 indexing**: `let a:*i64 = alloc [i64;8]; a[3]=77; return a[3]` → 77
- **p99b i32 indexing**: `*i32` write 0x12345678, returns (a[2]&255) → 120
- p92 clause-style bodies still SIGTRAP 133 (XFAIL; CPS/match lowering bug)

## Files changed this round
- pfront/pear_ir/air_ir.c3: air_mk_index(i, esz, k) — passes elem size in `idx` field.
- pfront/pear_ir/air_lower.c3:
  - Added elem_size_from_name() (u8/i8/bool→1, i16→2, i32/f32→4, i64/f64/usize/ptr→8).
  - Added index_elem_size() / index_elem_size_for_deref() that inspect type
    annotations on the base/deref expr (handles `*T` / `[T;N]`).
  - index_acc() reads the size from the base and passes into air_mk_index.
  - assign_mem() computes store_esz for the LHS, sets store_c.idx, and uses
    esz when constructing the wrapping INDEX consumer (for indexed stores).
- pfront/pear_ir/pear.c3:
  - ACNS_INDEX selects el_ty (i8/i16/i32/i64) from k.idx, bitcasts the
    inttoptr to <el>*, single-index GEP, then loads with el_ty and
    sext/zexts to i64 as needed.
  - ACNS_STORE similarly bitcasts addr to <el>*, truncates val to el_ty, stores.
  - Removed the volatile markers (they were bootstrap debug noise; volatile
    was preventing DSE/GVN from cleaning up redundant slot traffic).
- tests/exec/pear/p99_i64_index.pie, p99b_i32_index.pie (new).
- tests/exec/pear/p91_indexed_loop_write.pie: removed LE-luck note.
- tests/exec/pear/run.sh: cleanup handles non-executable stale binaries.

## Remaining known issues (v0.8.9)
1. **__pear_alloca 256-byte cap** — static `[256 x i8]` array alloca. Replace
   with a real malloc() call (cg.malloc_fn is declared in pear_setup).
   Requires re-enabling per-function attribute tagging (nofree only for
   functions without the Alloc effect) so DSE doesn't kill malloc stores.
2. **O0 tier still aliases default<O1>** (FastISel + gep/inttoptr crashed
   before). Now that GEP types match the pointee, retest default<O0>; if
   clean, restore it.
3. **p92 clause-style bodies** SIGTRAP 133 (CPS/match lowering for the
   `fn f : (T) -> U | (x) -> body` shape). All bench/*_kernel.pie use this
   form and are blocked on it.
4. **~40 advisory passes** (theory_nbe "counting & demo only", pfront_vecloop
   "No code is transformed", pfront_licm/pfront_inline with real analysis
   but no mutations, etc.) need to be promoted to real rewrites.
5. Pointer-as-i64 convention: inttoptr/ptrtoint produce redundant casts that
   mem2reg should eliminate but we still see 2 hops (slot→load→inttoptr→gep).
   A peephole pass or fixing the bind to hold pointers natively (mark_ptr +
   Lvalue typed ptrs) would clean up the IR and let GVN/LICM do better.

## Build / run
```
bash scripts/agent3-env.sh        # c3c 0.8.4 + libLLVM-23 into ~/.cache
bash scripts/agent3-build.sh      # builds ./pfrontc (chmod +x afterwards — c3c sometimes drops +x)
make test-pear                    # 18 PASS / 1 XFAIL (p92 clause)
```
Push uses the PAT already set on origin/dev. Do NOT paste `ghp_...` tokens
into tracked files — GitHub's secret scanner rejects pushes. Do not commit
bench binaries, *.air, tmp/*.pie.
