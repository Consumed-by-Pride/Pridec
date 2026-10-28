# The PEAR 2 native backend: `.air` to machine code without LLVM

This document describes the backend that turns AIR into an x86-64 ELF object
without passing through LLVM, an assembler, or any textual intermediate. It is
the reference for two things: what the pipeline guarantees today, and where the
next pass belongs when someone adds one.

```
  .air text ──parser──► AirDecl** ──pear2_cfg.c3──► PIR ──pear2_native.c3──► bytes
                                        (AIR→PIR)        │    (selection)
                                                         ├──pear2_x64.c3 (encoder)
                                                         └──pear2_elf.c3 (object)
```

## Why it exists

The LLVM path is correct and well tested, and it stays: `--emit-exe`, `--emit-obj`,
`--emit-asm`, `--emit-ll` and `--emit-bc` are unchanged. What the LLVM path
cannot be is *ours*: every program pays for printing a module, copying it into an
LLVM buffer, parsing it, verifying it twice, running a pass pipeline, and driving
a target machine. And every optimization PEAR invents has to be expressed as a
rewrite of LLVM IR.

The native path inverts both properties. There is no text, so nothing is printed,
lexed, or re-parsed; the encoder appends bytes to a buffer and the object is one
write. And the intermediate representation is PIR, which is a PEAR data structure
in a PEAR file, so a pass over it is an ordinary function in this repository.

## Stage 1 — PIR (`pear2_cfg.c3`)

PIR is a control-flow graph of basic blocks holding three-address instructions
over virtual registers, plus frame slots for the values AIR lets cross a block
boundary.

It is deliberately **not** SSA with phi nodes. AIR is CPS-shaped: a mutable local
is a label parameter, a `jump` passes it, and a loop re-enters its header. The
correct modelling of a join is a parallel copy into block parameter slots, and
the flattener emits exactly that: a jump reads every argument into a fresh
temporary first, then stores all of them, which is correct even on a self-edge
where an argument and a parameter are the same binding. Slots cost one store and
one load, and a later pass with dominance information can promote them away.

The instruction set is one flat enum (`PO_*`) so a pass can `switch` over
arithmetic without a visitor hierarchy, and instructions are contiguous in memory
so the linear passes stay cheap.

### What the flattener accepts, and what it refuses

Accepted: `let` (with its continuation), `seq`, direct calls, `if`, `match` over
literal integer/bool/char arms with a mandatory catch-all last, `while`, labels
and jumps with arguments, cuts to the return covariable, and `ret`.

Refused, with a positioned message rather than an approximation: indirect calls,
guards, record/tuple destructuring, cobranches, stores through pointers, globals,
floats, aggregates, closures, and more than six call arguments. The refusal is the
point: a wrong instruction is worse than a diagnostic.

### AIR's spine convention

`air_low.c3`'s `assemble()` emits every non-entry block as a label *prepended* to
the spine:

```
seq { label L1(p). body1 ; seq { label L2. body2 ; entry } }
```

Walking that inline would execute the label bodies first. The flattener therefore
peels labels into blocks with their own parameter slots before building the entry
body, and emits each label body afterwards with its own parameter scope. This is
the single most load-bearing detail in the stage: get it wrong and every function
with more than one block runs its blocks in the wrong order.

## Stage 2 — the encoder (`pear2_x64.c3`)

Pure byte emission with no knowledge of PIR: `x_mov_ri`, `x_alu_rr`, `x_imul_rr`,
`x_idiv`, `x_shift_cl`, `x_setcc`, `x_jcc`, `x_call`, and so on. Three details are
where hand-written encoders usually go wrong, and each is handled explicitly:

* REX is emitted only when required, including the SPL/BPL/SIL/DIL force case;
* ModRM/SIB with the RBP/R13 force-displacement rule and the RSP/R12 needs-SIB
  rule;
* `mov r64, imm64` versus `C7 /0 id` split at ±2³¹.

Fixups are recorded rather than resolved: a call records a `XF_REL32` entry
naming its symbol, and the ELF writer turns that into a relocation.

## Stage 3 — the object (`pear2_elf.c3`)

An ELF64 `ET_REL` object with a fixed eight-section layout: `.text`, `.rodata`,
`.data`, `.symtab`, `.strtab`, `.rela.text`, `.shstrtab`. Locals precede globals in
the symbol table through an explicit `order[]` map, `sh_info` names the first
global, and `r_info` is `order << 32 | type`. The write is three-phase — names,
then tables, then offsets — so no size changes after a section has been placed.

## Stage 4 — selection (`pear2_native.c3`)

Every virtual register owns a frame slot, which makes spilling always legal. A
register whose whole live range is inside one block competes for a scratch
register; RAX, RCX and RDX are excluded from that pool because division demands
RAX:RDX and a shift demands CL, and a value living there would have to be shuffled
around every such instruction. Before a call, every scratch register holding a
value that is still live is spilled — that single rule is the entire
calling-convention contract, and it is what keeps the allocator simple enough to
be obviously correct.

`nat_emit_start` writes the twelve bytes that make an object runnable with nothing
but `ld`: clear EDX, call `main`, move the low 32 bits of the result into EDI, put
60 in EAX, `syscall`.

## Using it

```
pear2c prog.air --emit-native --native-entry      # prog.o, with a _start
ld -static -o prog prog.o && ./prog              # runnable with no runtime
pear2c prog.air --emit-native                    # prog.o, library-style
```

`--emit-native` without `--native-entry` produces an object whose functions can be
linked into a C program or another PEAR module. With `--native-entry` the object
also carries `_start`, so a freestanding program needs no C library, no crt, and
no linker script.

Every mode keeps the shared front half: the same parser, the same AIR, the same
signature checks, the same diagnostics. The modes differ only after `main` has been
validated, which is why a program can be built by either backend and compared.

## Where the next pass goes

Each of these is a function over PIR data, in `pear2_cfg.c3` or a new file beside
it, and none of them can reach into LLVM:

| Pass | Input it needs | What it changes |
| --- | --- | --- |
| Slot promotion | def/last-use per vreg, per block | removes store/load pairs the flattener emits |
| CSE / GVN | value numbering over `PInst` | deletes redundant arithmetic |
| Loop rotation | block predecessors, back edges | turns a header test into a bottom test |
| Scheduling | per-instruction latency, no memory dependencies | reorders within a block |
| Register allocation across blocks | liveness over the CFG | replaces the spill-everything-before-call rule |

Adding a target means writing one selector beside `pear2_native.c3`; the encoder
and the object writer are already separate files, and PIR names no machine.
