# Backend contract (PEAR 1 and PEAR 2)

Normative for any program that consumes `.air`. Format: [`docs/specs/AIR.md`](../specs/AIR.md).

## 1 Process interface

```
BACKEND FILE.air [FILE.air | FILE.bc ...] [--emit-exe | --emit-bc] [-O0 | -O1 | -O2 | -O3 | -Os | -Oz] [--quiet]
BACKEND FILE.bc [FILE.bc ...] --verify-bc [--target=x86_64 | --target=wasm32-freestanding] [--quiet]
```

| | |
|---|---|
| `--emit-exe` (default) | write the executable `FILE` (the path with its last extension removed, next to the input) |
| `--emit-bc` | write verified LLVM bitcode `FILE.bc`; a backend without bitcode support exits 2 |
| `--emit-obj` | (PEAR 2) write the native object `FILE.o` produced by LLVM's backend in process |
| `--emit-asm` | (PEAR 2) write the x86-64 assembly listing `FILE.s` the object was assembled from |
| `--emit-native` | (PEAR 2) write the x86-64 ELF object `FILE.o` from PEAR 2's own backend — no LLVM, no textual IR; `--native-entry` adds a `_start` so `ld -static` yields a runnable program |
| `--verify-bc` | (PEAR 2) the first argument is a `.bc` instead of a `.air`: load, parse, verify, compare the triple, report the module's shape. Writes nothing and deletes nothing |
| multiple inputs | (PEAR 2) every `.air` input is parsed and merged into **one** module before optimisation, so cross-unit calls are ordinary direct calls; a symbol defined twice (function, coterm definition, or global) is exit 3 naming the symbol, and so is a type (data/codata/effect) declared by two inputs — the emitter writes one identified struct per record and LLVM does not unique two same-named structs, so that merge cannot be papered over; an external declaration or import is merged once by name, and each unit is verified against its own file first. A `.bc` input is not parsed as AIR: it is loaded, its triple compared with `--target=`, and linked with `LLVMLinkModules2`. `--emit-native` refuses `.bc` inputs (exit 2) rather than dropping them |
| `--cpu=NAME\|native`, `--features=LIST\|native` | (PEAR 2) target tuning, resolved through `LLVMGetHostCPUName`/`LLVMGetHostCPUFeatures` when `native`, used for the optimiser *and* written into the module as `"target-cpu"`/`"target-features"` so a published `.bc` keeps its tuning after it leaves the process |
| `--reloc=static\|pic\|dynamic-no-pic\|default`, `-fPIC` | (PEAR 2) `LLVMRelocMode` for code generation; static unless asked, and a PIC build records `!{i32 8, !"PIC Level", i32 2}` in `!llvm.module.flags` (Min behavior, as `Module::setPICLevel` does) so a later link cannot silently mix PIC and non-PIC code. Only the *default* code model is ever passed, because that enum's order has changed between LLVM releases |
| `--passes=PIPELINE`, `--print-pipeline`, `--inline-threshold=N` | (PEAR 2) an explicit pipeline replaces the `-On` default, but `verify` is appended when absent: a custom pipeline may not skip verification. `--print-pipeline` prints what would run and writes nothing |
| `--check` | (PEAR 2) parse, merge and verify the AIR, report the verdict, write nothing and delete nothing; exit 0 clean / 1 invalid. Refused with an `--emit-*` mode or a `.bc` input (exit 2), because it would then report on work it did not do |
| `--probe` | (PEAR 2) the next gate after `--check`: run the real IR emitter over every function without creating an LLVM context, print one positioned line per refusal, and a `N function(s), M lower, K refuse` summary; exit 0 when every function lowers, 3 otherwise. Writes nothing; refused with an `--emit-*` mode or a `.bc` input (exit 2), because a file it never reads would make the report describe a smaller program than the command line |
| `-Os`, `-Oz` | (PEAR 2) `default<Os>` / `default<Oz>` with the `-O2` AIR tier |
| `-On` | optimisation tier; default `-O2` (PEAR 2: `-O1` = AIR folding, reassociation, and self-operand folding, `-O2` adds the dead-binding pass, `-O3` adds whole-body propagation and literal-decided control-flow folding; `-Os` keeps the `-O2` AIR tier and selects `default<Os>`, and every other tier selects the matching `default<On>` LLVM pipeline) |
| exit 0 | the artifact was written |
| exit 1 | the `.air` was rejected (syntax, version, limits) — message `file:line:col: …`, **no artifact** |
| exit 2 | usage error, or a requested mode this backend does not provide |
| exit 3 | the file was valid but the backend produced nothing (unsupported form, internal failure) — message names the form and the definition, **no artifact** |

PEAR 2 additionally accepts `--emit-obj` (write the native object `FILE.o`), `--emit-asm` (write the assembly
listing `FILE.s` — the same target-machine call with the assembly file type, so the listing is what the object
was assembled from rather than a second compilation), `--emit-ll` (write the verified textual LLVM IR as
`FILE.ll`, the same module the bitcode would be serialised from) and `--stats` (report the AIR optimizer
counters and the effective linkage policy on stdout). `--internalize` and `--no-internalize`
control symbol visibility: with it, a definition or global that is not `pub`, is not `main`/`pride_main`/`_start`,
and carries no `export`/`section` attribute is emitted with `internal` linkage so LLVM may inline it and drop it
when unused; without it every definition keeps external linkage. `--emit-exe` defaults to internalizing (there
PEAR 2 performs the final link and `main` is the only symbol the CRT resolves by name), while `--emit-bc`,
`--emit-obj`, `--emit-asm`, and `--emit-ll` default to external linkage because the published object may be
linked against any symbol. A symbol named only by inline-asm text must be `pub` or `#export`ed. The six
emit modes (`--emit-exe`, `--emit-bc`, `--emit-obj`, `--emit-asm`, `--emit-ll`, `--emit-native`) are mutually
exclusive; naming two of them is a usage error (exit 2). `--emit-ll` is the diagnostic counterpart of `--emit-bc`: it shows exactly what the producer
lowered, including the effect of the `-On` IR passes. `PEAR2_KEEPLL` in the environment publishes the same file
during an `--emit-exe` run.

A stale artifact from a previous run must not survive a failure: delete the output first or write atomically.
PEAR2 builds an LLVM module through the LLVM C API, verifies it, and then generates machine code with LLVM's own
backend **in process** — no textual IR is handed to an external compiler and no `clang` is needed to compile.
Default executable mode links the object it just produced with `ld`, using glibc's `crt1.o`/`crti.o`/`crtn.o` for
startup and `-lc` for the C runtime; `PEAR2_CRT_DIR` relocates those objects and `PEAR2_LINK=clang` swaps in a
clang driver over the same object if the system linker cannot be used. A link failure is exit 3 and must leave no
executable or temporary artifact. `--emit-bc`, `--emit-obj`, `--emit-native`, and `--emit-ll` never link and never invoke clang.

`--emit-bc` is the only mode whose artifact is checked after it is written: the file is loaded back with
`LLVMCreateMemoryBufferWithContentsOfFile`, parsed with `LLVMParseBitcodeInContext2`, verified, its triple
compared with the requested one, and every symbol that had external linkage before optimisation looked up
again. A file that fails any of those steps is removed and the run exits 3, so a published `.bc` is by
construction one this LLVM can read and one that still exports what the source declared. Emitted modules carry
`source_filename`, `!llvm.ident` (compiler, AIR profile, target) and `!llvm.module.flags` (`wchar_size`,
`uwtable`).

`--verify-bc FILE.bc` applies the same load/parse/verify/triple checks to a file this run did not produce, and
writes no artifact; exit 0 means valid, exit 3 means unreadable, unparsable, unverifiable, or the wrong triple,
and combining it with an `--emit-*` mode is exit 2. `--emit-native` is a second, independent backend described
in [`BACKENDS.md`](BACKENDS.md); it covers a documented subset of AIR and refuses the rest with a source
position.
Warnings go to stdout/stderr and never change the exit status of a successful emit. The wrapper
`scripts/pie-exe.sh` forwards both stages' output; `BACKEND=… scripts/pie-exe.sh FILE.pie --emit-exe -O2` is the
whole chain.

### PEAR 2 aggregate ABI boundary (current implementation)

PEAR 2 lowers plain, non-generic, non-packed, single-constructor product declarations as LLVM named structs. AIR `record` construction and `field` projection are supported for those declarations; sum types, constructor patterns, and record patterns are not implied by that support. External by-value aggregates are limited to non-empty tuples and these plain records whose fields have C-compatible LLVM representations. AIR `bool` and `unit` fields are rejected in external aggregates, as are unsupported declaration attributes and aggregate shapes. Native interoperability is verified with the checked-in C fixture on x86-64 Linux/LLVM 23 only; LLVM's `ccc` lowering is not a promise of cross-target C ABI compatibility. `letrec` groups whose members are non-capturing lambdas are lowered: each member becomes an internal function taking a hidden environment pointer, a group member may name itself and its siblings, and such a call in return position is emitted with LLVM's `tail` marker. A member that captures an enclosing binding, a non-lambda initializer, a duplicate binder, or a member whose result type cannot be inferred is an unsupported form and must fail with exit 3, name the rule and the source position, and publish no artifact; so must any other unsupported AIR form.

### PEAR 2 AIR 3 low-profile globals and memory

The bounded AIR 3 low-profile slice lowers typed globals with constant initializers, mutability, alignment, `extern`, and explicit `link "symbol"` names. String and byte literals used as pointer constants are pooled as private unnamed-address LLVM constants with a trailing NUL for strings; pointer decay and constant GEP are emitted explicitly. Typed `alloca`, `malloc`, `free`, typed `load`/`store`, constant typed GEP, and **one dynamic GEP step per GEP** are supported for types with known size/alignment and tracked provenance. A dynamic step computes its address unchecked (an out-of-range pointer is just a value) and every dereference through it is either proved from the tracked interval or emitted with a runtime bounds check that traps: `addr >= base && addr + size <= base + extent`. A checked access claims `align 1` because a dynamic index cannot promise the type's natural alignment; atomics therefore remain restricted to constant addresses. The promise is attached to the *access*, so a chain of GEPs whose last step is dynamic (`p[i][j]`) is supported: the final dereference checks its own address against the allocation the chain came from. Two dynamic indices inside a single GEP are refused. A heap object's size may also be a register: `malloc(n)` for a computed `n` is accepted, and the object's extent becomes a runtime value (`M1EXTENT_RUNTIME` in `provenance.extent`, with `extent_value` naming the `i64` count). Every proof that would have compared against the constant then compares against that register, so the guarantee is unchanged and only its timing moves; the check also adds `base != null`, because a failed allocation must not look like a zero-sized object. `realloc(p, n)` is modelled rather than treated as an opaque call: the old object is marked freed (its aliases fail closed from then on), the cells inside it are dropped, and the result carries the requested size, literal or register. A **call is otherwise a hole in the analysis**: a callee can write through any pointer it is given, so the cells inside those objects are dropped after the call. Whether a callee can write is decided by scanning its body when it is defined in this file (a store, an atomic, a syscall, an asm block, or a call that itself can write) and answered *yes* for external symbols, indirect calls and bodies past the scan budget. A `free` must receive the live base pointer of a known heap allocation; stores through immutable globals, out-of-bounds or misaligned accesses, stale/freed pointers, unknown provenance, two dynamic indices in one GEP, and zero-sized constant allocations fail closed with exit 3 and a source-located diagnostic. Pointer-cell stores/loads retain the provenance of the stored pointer, and freeing an allocation invalidates its tracked aliases. The fixture-backed acceptance cases are `tests/pear2/global_string_main.air`, `tests/pear2/typed_memory_main.air`, `tests/pear2/typed_pointer_cell_main.air`, `tests/pear2/dynamic_index_main.air`, `tests/pear2/dynamic_grid_main.air`, and `tests/pear2/dynamic_malloc_main.air`; negative provenance, lifetime, and dynamic-form checks live beside them under `tests/pear2/reject_*.air`.

## 2 Obligations

1. **Strict input.** Reject, do not recover from: unknown keywords, other versions, over-limit counts, trailing text.
   (`air_read.c3` is the reference; `airtool check` is the oracle — a file it rejects you must reject, and a file it
   accepts you must parse. `airtool fmt` of a valid file must equal what your printer would write, if you have one.)
2. **No silent miscompiles.** For every form in AIR.md §7 marked *emitted*, *never produced*, or *unsupported*, and for
   every V1–V3 violation (an unbound variable that is not an N1 module-path root), emit a diagnostic naming the form and
   the definition and exit 3. Reaching `main` through such a form must not produce a runnable program.
3. **Claims are candidates.** Re-screen `facts`/`readonly`/`nocapture` (AIR.md §9) or drop them. Never turn a text
   claim into an LLVM attribute or an optimisation without proving it yourself.
4. **Duplicates:** the first definition of a top-level name wins; report the later ones.
5. **Conventions:** implement R1, H1, J1, T1, L1, A1, N1, D1, E1 of AIR.md §8 (or refuse the file with exit 3 and say which).
6. **Determinism:** the same `.air` and `-On` give the same artifact bytes (the legacy backend does; tests rely on it).

## 3 Behavioural reference

* `tests/exec/*.pie` and `tests/exec/pear/*.pie` carry the expectation in the source: `-- EXPECT: <stdout>` and/or
  `-- EXIT: <code>`. `tests/exec/run.sh` compiles each through the chain, runs it, and compares.
* Today (legacy backend, `-O2`): exec suite **43 pass / 0 fail / 49 expected failures**; PEAR smoke **35 / 0 / 1**;
  identical at -O0..-O3. The 49 are mostly one front-end defect (`syscall` operands, AIR.md §11.1) and are listed with
  reasons in `tests/exec/XFAIL.tsv`.
* PEAR 2 need not reproduce PEAR 1's machine code. It must reproduce the **observable result** (exit status and stdout)
  on every case PEAR 1 passes, and may pass more.
* Differential check against PEAR 1: build both, run a case, compare exit status and stdout
  (`scripts/pie-exe.sh` with `BACKEND` unset vs set). Executables produced by the legacy path through `.air` are
  byte-identical to the old direct path (that is how the split was validated), so PEAR 1 is a stable oracle.

## 4 What PEAR 1 does (so you can tell a requirement from an accident)

Requirements — observable in the passing suites:

* a scalar is a 64-bit integer unless an annotation says `i8/i16/i32/u8/u16/u32`/`bool`/pointer; pointers are carried as
  64-bit integers and cast at use;
* `index(i; n)` reads element `i` of size `n` bytes (1/2/4/8), `store(v; n)` writes `n` bytes and delivers `0`;
* `field f #i` addresses the `i`-th 64-bit slot of a record (all fields are 8 bytes);
* `main`'s return value is the exit status; `extern declare malloc/free/write` bind to libc.

Accidents — do **not** copy:

* the clamping of element sizes above 8 to 8, the sign-extension of 2- and 4-byte loads and zero-extension of 1-byte loads
  (a front-end type should decide signedness);
* recognising `%kN`/`%ret`/`·`/`_xN` by spelling inside the code generator, and the "narrow recovery" special case for
  `binder[literal]` returned to `%ret`;
* continuing after a free variable or an `syscall` without operands.

## 5 Front-end follow-ups that unblock backend work

These are tracked in the ledger and are **not** backend problems: `syscall` operands (AIR.md §11.1), dropped statements
(§11.3), unbound variables (§11.2), resolved types instead of `infer` (§12.5), explicit joins (§12.2). Each is measured by
`tests/air/VERIFY_KNOWN.tsv` or the exec XFAIL list, so progress is visible without trusting a report.
