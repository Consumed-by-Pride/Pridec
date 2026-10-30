# The two PEAR 2 backends

PEAR 2 has two output backends. They share everything up to the point where a
verified AIR module is in memory, and then diverge completely. One of them is
finished and one is not; this file states which is which, because "we have a
native backend" and "the native backend compiles your program" are different
claims.

| option | pipeline | artifact | status |
| --- | --- | --- | --- |
| `--emit-bc` | whole file + N × AIR merged → LLVM IR text (+ linked `.bc` inputs) → parse → verify → pipeline → verify → bitcode → **load back, verify, compare triple, check exports** | `.bc`, linkable by any LLVM 23 tool | **complete for the documented subset** (see §1 and §3) |
| `--verify-bc` | load → parse → verify → compare triple → report | nothing (checks an existing `.bc`) | complete |
| `--emit-native` | AIR → PIR → x86-64 bytes → ELF64 | `.o` relocatable, or runnable with `--native-entry` | **partial** (see §2) |
| `--emit-exe`, `--emit-obj`, `--emit-asm`, `--emit-ll` | the LLVM path | executable / object / listing / text | complete, unchanged |

The backend is chosen per invocation; nothing about one mode weakens another.

## 1. `--emit-bc`: complete for the documented subset

"Complete" here means: every AIR form the backend claims to support is lowered,
and every form it does not support is refused with a position instead of being
approximated. It does **not** mean "Pride can build arbitrary software" — §3 is
the honest measurement of what is still missing for that, and it is a longer list.

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

**Verifying several artifacts at once.** `--verify-bc a.bc b.bc` checks each file
and then answers the question that actually matters for a pair: whether they can be
linked. Two artifacts that both *define* a symbol cannot be, and finding that out
from the linker after a long build is the wrong time.

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

### 1.0 The whole file is the program

`root_decl_count` used to stop at the first `module` record, so the emitter
lowered the entry module and **silently dropped every declaration after it**. A
program that imported anything therefore emitted a *call* to each imported
function and no body for any of them: the link failed later with an undefined
symbol that named neither the import nor the compile that lost it. Emitting the
whole file is what makes "compile a program that uses a library" mean what it
says.

Merging a whole file introduces the one thing a single module cannot have — two
declarations of the same name — so both cases are refused with both positions
instead of reaching LLVM as a redefinition with no file attached:

* two bodies for one symbol (`def`/`defco`/`global`);
* two `data`/`codata`/`effect` types with one name (one identified struct each;
  LLVM does not unique two same-named structs, so the module would not parse).

### 1.1 Several inputs become one module

`pear2c a.air b.air --emit-bc` parses both files and merges their declarations
into **one** module before anything else runs, so the AIR optimiser and LLVM both
see the whole program: a call from `a` into `b` is an ordinary direct call and can
be inlined across the unit boundary.

The rules are stated rather than implied:

* a symbol **defined** twice is refused (exit 3) with the symbol and the input
  that repeats it — not by LLVM as a redefinition with no file attached. A
  definition here means `def`, a coterm `defco`, or a `global`: all three occupy
  a symbol;
* a **type** declared by two inputs is refused too. The emitter writes one
  identified struct per record, and LLVM does not unique two same-named structs,
  so a merged module carrying both would simply fail to parse — with an error
  naming `%point` and not the two files;
* an external **declaration** or an `import` is merged once by name; the first input to declare
  a symbol fixes its signature, and every unit carries the same three prelude
  declarations for libc, so they collapse instead of colliding;
* each unit is verified on its own first, so invalid AIR is reported against the
  file it came from;
* the first `.air` input names the output and the `source_filename`.

`.bc` inputs are not parsed as AIR at all: each is loaded, its triple compared
with the requested one, and linked into the module with `LLVMLinkModules2`. That
is what makes "compile this and link that prebuilt library" one command. Mixing
targets is refused *before* the link, because a wasm module linked into an x86 one
produces a module LLVM will verify and no backend will emit. `--emit-native`
refuses `.bc` inputs outright rather than silently ignoring them.

### 1.2 Target tuning travels with the module

`--cpu=NAME|native`, `--features=LIST|native`, `--reloc=static|pic|dynamic-no-pic|default`
and `-fPIC` reach the target machine — before this, they were hardcoded to an empty
CPU and a static relocation model, which means the optimiser assumed a generic
baseline and never used an instruction the machine actually has.

Relocation is recorded the same way: a `-fPIC` build emits
`!{i32 8, !"PIC Level", i32 2}` in `!llvm.module.flags`, with **Min** behavior
because that is what `Module::setPICLevel` uses — a non-PIC object and a PIC object
can only be used together as non-PIC, so the merge rule has to keep the lesser
claim rather than the louder one.

Tuning is also written *into* the module as an attribute group:

```llvm
define i64 @f(i64 %a0) #0 {
...
attributes #0 = { "target-cpu"="x86-64-v3" "target-features"="+sse4.2" }
```

because a `.bc` that leaves this process is linked somewhere else, possibly by a
tool that has never heard of `--cpu`, and the tuning is part of what the code
means. `--cpu=native` and `--features=native` are resolved through LLVM's own
`LLVMGetHostCPUName`/`LLVMGetHostCPUFeatures` rather than a second implementation
of host detection.

### 1.3 The pipeline is inspectable and cannot lose verification

`--print-pipeline` prints exactly what would run — pipeline, target, CPU,
features, relocation model, inliner threshold, input count — and writes no
artifact:

```
$ pear2c --print-pipeline -Oz --cpu=native
pear2c: pipeline=default<Oz> target=x86_64-unknown-linux-gnu cpu=znver4 features=... reloc=static inline-threshold=250 inputs=0
```

`--check` is the same gate without the work after it: parse, merge, verify the
AIR, print a verdict, touch nothing. A CI gate that has to build a `.bc` to learn
whether a file is valid cannot be run on a file that is being edited, and a gate
that deletes the last good artifact to report a failure is worse than none — so
`--check` skips `clear_stale_outputs` as well as emission.

`--passes=PIPELINE` replaces the `-On` default. Whatever it says, `verify` is
appended when it is not already present: "I asked for `mem2reg`" is not a reason
to publish a module nobody checked. `-Oz` joins `-Os` as a real tier
(`default<Oz>`), and `--inline-threshold=N` overrides the inliner threshold that
shared PEAR 2's default of 250.

### 1.4 Two gates that need no LLVM: `--check` and `--probe`

`--check` stops after the AIR verifier: is this program valid?

`--probe` stops after the *emitter*: can this backend lower it? It runs the real
IR emitter over every function, reports one positioned line per refusal, and
prints a count:

```
$ pear2c prog.air --probe
prog.air:12:5: pear2c: cannot lower `f`: unsupported function body
pear2c: prog.air: 9 function(s), 8 lower, 1 refuse
```

Neither mode creates an LLVM context, so neither needs libLLVM. That matters more
than it looks: `--probe` is the capability gate that can run anywhere, and it is
the only measurement of "can this backend compile this program" that does not
depend on having a toolchain to build the compiler that has the toolchain.

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

## 3. What "real software" still needs

The corpus this backend has ever been asked to compile is `tests/exec/pear/*.pie`
— 48 programs, 517 lines total, largest 37 lines. A multi-thousand-line program
is 100× past that, and the gap is not one missing feature but a list. Measured
against the tree, not estimated:

| need | state | why it blocks a real program |
|---|---|---|
| generics / parametric types | the lowering pass monomorphises, so this backend only ever sees a concrete `data` record named for its arguments (`Vec.i64`); its type rules do not exclude one. A declaration that *keeps* `typaram_count != 0` is still refused | what a container library needs next is the library, not the lowering — and that is unverified end to end |
| slices | the AIR `slice` type was desugared by `air_low` into a `{ptr, len}` record, which the record path already lowers; the blocker was the **dynamic index** that reading `s[i]` needs, and that is now bounds-checked (`§1.1` of GAPS) rather than refused | `tests/exec/XFAIL.tsv` pins `p127`/`p128`, which also depend on front-end fixes |
| strings | literal arrays only, no growable string | any program that builds text |
| heap data structures | `malloc`/`realloc`/`free` via the C ABI, indexed through checked addresses, with the object's **extent allowed to be a register** (`malloc(n)`, `realloc(p, n)`: the bound check compares against that register), and with pointer cells invalidated by any call that can write through its arguments | no `Vec`/`HashMap`/`String` equivalents exist in the language yet — the growable shape is now lowerable, the library is not written |
| stdlib | 260 modules exist; `pear2c` has never been asked to emit them | calling one is an undefined symbol today |
| aggregates in non-C ABIs | conservative subset, fails closed | trait objects, wide signatures |
| debug info | **absent** on every path (no DI/DWARF) | a 10k-line program is undebuggable |
| execution evidence | **none**: no C3 compiler and no LLVM in the sandbox this was written in | every claim here is review-only until `make test-pear2` runs |

The ladder that would settle "is it complete", in order, each runnable:

1. `make check-pear2` clean. **Now true** — see §3.1.
2. `pear2c --probe` clean on all 48 `tests/exec/pear` programs.
3. One program of ≥ 5,000 lines compiles and runs (exercises the 4096-declaration
   cap, the 1 MiB alloca bound, per-function limits).
4. The 260 stdlib modules compile through `pear2c` (forces generics, slices, dyn).
5. Native backend reaches parity with `.bc` on 1–4.

### 3.1 The build gate, and how it was checked

Until this round the tree did not compile at all: ~80 errors across
`pear2_cfg.c3`, `pear2_native.c3`, `pear2_elf.c3`, `pear2_x64.c3`,
`pear2_opt.c3` and `pear2c_main.c3` (`fn` used as an identifier, `u8` as a type
where C3 has `char`, C-style array declarations, `->`, function prototypes with
no body, an enum cast, a `AirCmd*`/`AirCns*` confusion, and `cobranch_count` on
the wrong node). Those are fixed, and the gate was run for real with a `c3c`
built from source at the pinned tag:

```
c3c compile -C --no-entry --stdlib <c3lib> --max-stack-object-size 262144     <AIR_CORE> pear2/*.c3          # exits 0
```

`-C` is check-only, so this proves the whole backend and the drivers type-check
together; it does not execute them (a check-only compiler emits nothing).

`make check-pear2` is that gate, and it runs green. The capability gate next to it,
`make probe-pear2`, asks the *emitter* which functions it can lower over all 131
`tests/pear2` fixtures and fails if a fixture that used to lower stops lowering —
that measurement needs no LLVM at run time, which is why it can be the gate that
survives a machine without a toolchain (`§1.4`).

## 4. Why both exist

The LLVM path is the one that compiles real programs today: it inherits LLVM's
code generation, its optimization pipeline, and its target support. Nothing here
is a plan to remove it.

The native path exists for the things LLVM cannot give PEAR: a compile that does
not pay for printing, parsing, and re-verifying a textual module; an intermediate
representation PEAR owns; and the freedom to add a pass that is a function in this
repository rather than a rewrite of somebody else's IR. It is a second backend,
not a replacement, and its coverage is stated plainly in §2 so nobody discovers
the boundary by hitting it.
