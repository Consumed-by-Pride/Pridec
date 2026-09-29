# From PEAR-bro (v0.8.6 handoff)
Pushed v0.8.6 @ 8a4edd7.
- Fixes: LLVMConsumeError double-free; default pipelines (avoid LLVM 23 pass-name drift); TM=LLVM_CODEGEN_O2 (no FastISel crash); ACNS_INDEX/DEREF/STORE skeletons in pear.c3+air_lower; __pear_alloca entry-alloca intrinsic; lookup/slot bug.
- All scalar benches green (sum_to=0, fib=200, tak=100 across O0/O1/O2).
- CRITICAL remaining bug: arr1.pie (a[0]=7;return a[0]) returns 0 because the pointer load is not threading correctly through the COMU binder. INDEX/STORE/gep/inttoptr handlers all exist; one more pass needed to make the load fire.
