# The two PEAR 2 backends

PEAR 2 has two output backends. They share everything up to the point where a
verified AIR module is in memory, and then diverge completely. One of them is
finished and one is not; this file states which is which, because "we have a
native backend" and "the native backend compiles your program" are different
claims.

| option | pipeline | artifact | status |
| --- | --- | --- | --- |
| `--emit-bc` | AIR → LLVM IR text → LLVM parse → verify → `default<On>` → verify → bitcode → **load back, verify, compare triple, check exports** | `.bc`, linkable by any LLVM 23 tool | **complete** (see §1) |
| `--verify-bc` | load → parse → verify → compare triple → report | nothing (checks an existing `.bc`) | complete |
| `--emit-native` | AIR → PIR → x86-64 bytes → ELF64 | `.o` relocatable, or runnable with `--native-entry` | **partial** (see §2) |
| `--emit-exe`, `--emit-obj`, `--emit-asm`, `--emit-ll` | the LLVM path | executable / object / listing / text | complete, unchanged |

The backend is chosen per invocation; nothing about one mode weakens another.

## 1. `--emit-bc`: complete

Bitcode is a publishable artifact, so it is treated as a claim that has to be
checked, not a file that has to be written.

**The pipeline.** The module is rendered into memory (no temporary `.ll`), parsed
by LLVM in this process, verified, optimized with `default<O1|O2|O3|Os>` through
`LLVMRunPasses` with a target machine and an inliner threshold of 250, verified
again, and written with `LLVMWriteBitcodeToFile`.

**The load-back check.** After the file exists, `m1_bitcode_roundtrip` opens it,
loads it with `LLVMCreateMemoryBufferWithContentsOfFile`, parses it with
`LLVMParseBitcodeInContext2`, verifies the module, and compares its triple with
the one that was requested. A file that fails any of those steps is deleted and
the compile exits 3. This is the difference between "the writer returned 0" and
"the artifact is bitcode".

**The interface check.** Optimisation may delete anything nobody outside the
module can observe. It may not delete something the module promised to export —
that is a link error for whoever links the published bitcode, surfacing far from
the compile that caused it. So `m1_abi_snapshot_begin` records every externally
linked definition *before* the optimizer runs, and `m1_abi_check` looks each one
up again in the module loaded back from the written file. A missing symbol is
exit 3 with its name. Internal definitions are deliberately excluded: deleting
those is exactly what internalising is for.

**Checking an artifact that is already on disk.** `--verify-bc FILE.bc` runs the
same load, parse, verify and triple comparison over a file this run did not
produce, and reports its shape:

```
$ pear2c prog.bc --verify-bc
pear2c: prog.bc is valid bitcode (1140 bytes, 3 functions defined, 2 declarations, 1 globals, triple x86_64-unknown-linux-gnu)
```

It writes nothing, and it runs before any output path is computed, because
`clear_stale_outputs` would otherwise delete the very file being inspected. It is
refused (exit 2) alongside an `--emit-*` mode rather than silently ignoring one of
them, and exit 3 covers unreadable, unparsable, unverifiable, and wrong-triple.
That makes the artifact checkable by a build system long after it was built.

The memory buffer is never disposed by the caller: `LLVMParseBitcodeInContext2`
takes ownership whether it succeeds or fails, so the size is read before the
parse and the buffer is left alone afterwards.

**Provenance and module flags.** Every module carries
`source_filename = "<input path>"` (escaped by `m1_ir_write_string`, so a quote or
a backslash in a path cannot produce unparsable IR), `!llvm.ident = !{!0}` naming
the compiler, the AIR profile it consumed and the target, and
`!llvm.module.flags` pinning `wchar_size` to 4 and declaring `uwtable` — the two
flags every clang-produced Linux module carries and some consumers read instead of
assuming. A `.bc` that has travelled away from the command line still says what
produced it and what it expects of the platform.

**The success line reports the artifact, not the writer's opinion.** A bitcode
compile prints the byte count read back from the file and the module's shape
(functions defined, declarations, globals), all measured after verification.

**Determinism.** The module identifier is the input path, no PID, timestamp, or
address reaches the module, and the symbol order is fixed. Two compiles of one
input in one directory are byte-identical, and `tests/pear2/run.sh` asserts it.

**Targets.** `--target=x86_64` (default) and `--target=wasm32-freestanding` both
work. Every target LLVM was built with is registered (`LLVMInitializeAllTargets`
and friends), so a wasm32 request gets a real target machine for the optimization
pipeline instead of falling back to generic cost decisions. The emitted bitcode
carries the requested triple and no other.

**Failure modes.** Exit 2 for a bad option or two conflicting modes, exit 1 for
invalid AIR, exit 3 for valid AIR outside the supported subset or for an artifact
that failed verification. Every failure removes a stale output.

## 2. `--emit-native`: partial, and honest about it

Documented in [`NATIVE_BACKEND.md`](NATIVE_BACKEND.md). Four files, one per stage:
AIR → PIR (`pear2_cfg.c3`), encoder (`pear2_x64.c3`), ELF writer (`pear2_elf.c3`),
selection and ABI (`pear2_native.c3`).

What works today: scalar integer/boolean values, direct calls with up to six
arguments, `let`, `seq`, `if`, literal `match` with a catch-all last arm, `while`,
labels and jumps with parallel-copy edges, and returns. Everything else is refused
with a source position rather than mistranslated.

What is missing: memory (loads, stores through pointers, globals, strings),
floats, aggregates, closures, indirect calls, and any register allocation that
crosses a basic block. `tests/pear2/native.sh` exists and is wired into
`make test-pear2`, but it has not been executed anywhere yet — there is no C3
compiler and no linker in the workspace where it was written.

## 3. Why both exist

The LLVM path is the one that compiles real programs today: it inherits LLVM's
code generation, its optimization pipeline, and its target support. Nothing here
is a plan to remove it.

The native path exists for the things LLVM cannot give PEAR: a compile that does
not pay for printing, parsing, and re-verifying a textual module; an intermediate
representation PEAR owns; and the freedom to add a pass that is a function in this
repository rather than a rewrite of somebody else's IR. It is a second backend,
not a replacement, and its coverage is stated plainly in §2 so nobody discovers
the boundary by hitting it.
