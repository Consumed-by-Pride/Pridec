# PEAR-bro handoff — v0.9.0 (2026-09-30, pushed to `dev`)

## Summary
v0.9 wires up real `malloc`/`free` for `alloc[T; N]`, replacing the v0.8
bootstrap 256-byte static stack buffer. This is the first step where PEAR
uses the heap at all — arrays larger than 256 B, the sieve kernel, stack VM
kernel, and any non-trivial program with alloc were previously impossible.

## What landed
1. **`alloc [T; N]` → `malloc(n_bytes)`** in air_lower.c3 (was `__pear_alloca`
   static alloca). `free(p)` now calls real libc free (bitcasts the i64
   pointer back to i8* at the call site).
2. **libc intrinsics declared correctly in pear.c3** — malloc/free/write
   signatures match their real C types (i8*(i64), void(i8*), i64(i32,i8*,i64)),
   and `@malloc` carries the `allockind("alloc,uninitialized")` string
   attribute so LLVM knows it's an allocator. Without this, the middle-end
   treated @malloc as a black-box external with no memory effects, inferred
   `memory(none) nofree` on main, deleted the malloc call, and folded the
   pointer to NULL → `movb $0x7, 0x0` → SIGSEGV (exit 139).
3. **Linker fix in pear_link.c3**: `-nostdlib` previously prevented libc
   from linking; the dynamic loader wasn't invoked so `malloc` resolved to a
   NULL PLT slot. Now:
   `ld start.o obj.o -o exe --entry=_start -nostdlib -no-pie
       -dynamic-linker /lib64/ld-linux-x86-64.so.2 -lc`
   with `LD_LIBRARY_PATH=` cleared for the `ld` child so it doesn't pick up
   LLVM-23's internal plugin `libc.so` instead of glibc (ld: "cannot find
   -lc: file format not recognized").
4. **`AirModule.init` pre-registers malloc/free/write as ADECL_DECLARE
   externs** so air_lower never synthesizes a zero-returning DEF stub for
   them. The DECL-fn path for BUILTIN_FN names (`malloc`/`free`/`write`)
   also bails out when a pre-existing extern decl is already in the module
   (`decl_fn` short-circuits). Before this, walking the prelude + BUILTIN_FN
   resolution caused the lowerer to emit a `define ptr @malloc(i64) { ret
   i64 0 }` body which overrode libc's malloc with a NULL-returning stub.

## Scoreboard: 29 PASS / 0 XFAIL / 0 FAIL (same as v0.8.9; alloc tests now use real malloc)
- p90 a[0]=7 (u8) → 7 through malloc-backed buffer ✅
- p91 loop writes a[i]=i on *i64 malloc'd buffer → 3 ✅
- p99 a[3]=77 on *i64, p99b 0x12345678 on *i32 both correct ✅
- bench/sum_to=0, fib=200, tak=100 ✅ (malloc never invoked; pure arith)

## Kernels status
- sieve/stack_vm/sum_array *compile* cleanly with clause-style fn defs
  (errors=0 warnings=0) but **runtime is incorrect for clause-style fns**:
  objdump shows `eratosthenes:` / `main:` containing only `endbr64` and
  returning 0. That's a codegen bug for **multi-clause and single-clause
  non-unit-pattern matches** — the irrefutable shortcut only fires for
  APAT_WILD or APAT_TUPLE with sub_count==0, so clause-style functions
  like `fn eratosthenes : (*u8, i64) -> i64 | (arr, n) -> ...` (tuple of
  two binders) fall into the unhandled-CASE path that builds a bool
  condbr on undef and dead-ends in unreachable.
- Switching the kernels to brace-style bodies (`fn eratosthenes(arr, n) {
  ... }`) instead of clause syntax hits a separate LLVM 23 crash:
  `Instruction::clone()` SIGSEGV during the O1 pass pipeline (the same
  EarlyCSE/memorySSA clone crash noted in the discoveries doc — this is
  the next fix).
- Brace-style single nested-loop programs (p100-p108, p91) still work.

## Files changed
- `pfront/pear_ir/air_ir.c3`: AirModule.init pre-declares malloc/free/write
  as ADECL_DECLARE with correct param/return types.
- `pfront/pear_ir/air_lower.c3`: N_EXPR_ALLOC calls `malloc` (not
  `__pear_alloca`); decl_fn bails out for libc names when a decl exists.
- `pfront/pear_ir/pear.c3`: malloc/free/write externs tagged with nounwind
  + `allockind` string attrs; callee-type dispatch for malloc (i8* ret)
  and free (void ret, arg bitcast); user fn attrs reduced to just nounwind
  (willreturn/nosync/mustprogress were too aggressive while malloc attrs
  were being sorted — re-enable once malloc/free carry willreturn etc);
  removed callee_is_alloca_intrinsic path; free_fn/write_fn cached on
  PearCg.
- `pfront/pear_ir/pear_link.c3`: link with -lc + dynamic linker, clear
  LD_LIBRARY_PATH for the ld child.

## Critical note for next agent
1. **allockind key length**: LLVM string attr lengths are byte-exact. I
   wrote `"allockind"` length 9 first (a-l-l-o-c-k-i-n-d), and an earlier
   iteration had 8 which truncated to `"allockin"` and silently produced
   garbage attrs that LLVM ignored. Verify with `grep allockind` on dumped
   IR if alloc programs start returning 139 again.
2. **ld LD_LIBRARY_PATH pollution**: pfrontc is invoked with
   `LD_LIBRARY_PATH=~/.cache/llvm23:...` so it can find libLLVM-23.so.
   That directory ALSO contains a non-glibc `libc.so` (LLVM plugin) which
   `ld` picks up when searching for `-lc`. The fix must run ld with
   LD_LIBRARY_PATH cleared (or empty), e.g. `LD_LIBRARY_PATH= ld ...`.
3. **LLVMGlobalGetValueType on a function returns a POINTER-to-function
   type in opaque-ptr LLVM**, not the function type itself. Don't pass it
   to LLVMBuildCall2 — that makes calls UB and LLVM treats them as
   undef. Build the fn_ty manually for known intrinsics (malloc/free/write)
   and use a fallback i64(...) signature for Pride-declared fns (which
   matches how pear_fn_type/pear_declare build them).
4. **C3 does NOT zero stack locals**. Any on-stack AirCns/AirPat/etc
   in PearCg.cmd/cns needs explicit per-field null initialization.
5. **The alloca-intrinsic path is dead but `__pear_alloca` name in prd_i64
   now returns cg.malloc_fn for back-compat** (so any old hand-written
   .air still works).

## NEXT UP (v0.9.1)
- Fix single-clause tuple-pattern ACNS_CASE: `| (arr, n) -> body` should
  bind arr/n from the single parameter and run body, not fall into the
  bool-condbr logic. That's the immediate unblocker for sieve/stack_vm.
- Debug `Instruction::clone()` crash for multi-nested-loop brace-style
  programs at -O1 (the EarlyCSE / simplifyGEPInst NULL TypeAllocSize
  family of bugs). Once this is fixed, the kernels run end-to-end.
- Re-enable willreturn/nosync/mustprogress on user fns once the
  alloc/free paths are verified, and add nofree only for functions
  without the Alloc effect (need to thread fn effects to pear_tag_fn).
- Restore default<O0> pipeline.
- Suppress duplicate libc warnings.
