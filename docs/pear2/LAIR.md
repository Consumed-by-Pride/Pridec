# LAIR — Low-level AIR (design)

> AIR is λ̄μμ̃ with compound terms. LAIR is λ̄μμ̃ after the compound terms are
> gone — three normalizations, the three sorts kept, the μ-structure reified as
> a control-flow graph. `.air` → LAIR → `.ll` / `.bc`.

## 0. Why

The LLVM path today has no middle stage. `pear2/pear2c_main.c3` (8.1k lines)
walks the AIR tree and prints LLVM IR in the same breath: labels, provenance
cells, slots, closure lifting and type decisions are all made *while* the
`fprintf` stream advances. `air_ll.c3` (the reference consumer) has the same
shape at 1.2k lines. Every bug is simultaneously a lowering bug and a printing
bug, and there is no artifact between "the AIR" and "the text LLVM parses" to
inspect, verify, or diff.

The native path already shows the right shape: `pear2_cfg.c3` lowers AIR →
**PIR** (an explicit CFG), and `pear2_x64.c3` mechanically encodes it. LAIR
gives the LLVM path the same stage separation — but it is *not* PIR with a new
name; it is the repo's own calculus carried down one level (§1).

This document is the contract for the slice: what LAIR is, what the first
backend accepts, how each form prints, and which rung of the ladder is next.

## 1. The calculus story

AIR implements λ̄μμ̃ (Curien–Herbelin 2000, see `pfront/pear_ir/README.md`):
producers `p`, consumers `e`, commands `c` — cuts `⟨p | e⟩`, `μα.c`,
`μ̃x.c`. Producers nest (`add 40 (mul 2 1)`), consumers nest
(`call · 2 · comu r. …`), commands nest through binders. A backend must
flatten this; the question is whether the flattening *remembers what it
flattened*. LAIR says yes: it is the result of exactly three normalizations,
each one an equation already present in the docs.

### N1 — producer atomicity (ANF of the producer sort)

Every producer that is not an atom is let-bound through a cut:

```
⟨add 40 (mul 2 1) | κ⟩   ≡   ⟨mul 2 1 | μ̃t₁. ⟨add 40 t₁ | κ⟩⟩
```

After N1 the producer sort of LAIR is **atoms only** — names and literals —
and every non-trivial computation is an *instruction*: a cut of an atomic
operator application into a fresh μ̃-binder, written

```
%t₁ = cut mul(2, 1) : i64
```

The `%t₁ = …` line *is* the cut `⟨mul(2,1) | μ̃t₁⟩`; the surrounding command
is the rest of the block. Instructions therefore never nest.

### N2 — stack elimination (the consumer sort loses `·`)

The push-stack disappears. Each push becomes one instruction feeding the next
slot, and the stack's head consumer is applied atomically:

```
⟨f | a·b·c·κ⟩   ≡   ⟨a | μ̃x. ⟨b | μ̃y. ⟨c | μ̃z. ⟨call f(x,y,z) | κ⟩⟩⟩⟩
```

Projections go the same way: `⟨x | .f·k⟩` becomes a `gep`/`load` step plus
`⟨… | k⟩` (memory forms: phase 2). What survives of the consumer sort is
**closed and finite** — the atomic consumers:

| atomic consumer | LAIR terminator | calculus reading |
|---|---|---|
| covariable application `κ(ā)` | `jump κ(ā)` | cut to a reified μ̃/μ binder |
| the exit covariable | `ret a` | `⟨a \| %ret⟩`, one per cut site |
| boolean case | `br c, ^b₁, ^b₂` | `⟨c \| case{true→…; false→…}⟩` |
| trap / ub | `trap` | `ACMD_TRAP` / `ACMD_UB` |

### N3 — continuation reification (the μ-structure *is* the CFG)

A covariable binder (the `mu~ %ret.`, a `label L(…).`, a continuation
synthesized for a join) becomes a **block with parameters** exactly when its
code must exist in more than one place — i.e. when it is the target of cuts
from multiple sites, or from a back edge. A binder consumed once stays where
it is: no block, no phi, the code just continues.

* `⟨v | %ret⟩` with one site in a function prints as `ret v` directly; with
  three sites it is three `jump %ret(v)` edges into one `%ret(x): ret %x`
  block — **or** three `ret v` instructions, because the exit is the one
  covariable whose reification is never required: N3 materializes joins, and
  an exit is not a join. The lowering picks the single-`ret` form and the
  verifier checks the choice is consistent.
* `label done(). body` with `jump done()` sites is a block `done(params):`
  with the jumps as edges — **edge arguments are the label parameters**, and
  because every edge argument is already an atom (N1), the parallel-copy
  semantics of AIR jumps are preserved by construction: the printer turns
  edge arguments into `phi` inputs.
* A straight-line `let` / `comu` binder is *not* a join: it is an ordinary
  μ̃ whose body continues in the same block — N3 does not fire, and the
  binder is just an atom name.

The invariant: **every CFG edge of LAIR is a cut to a covariable, and every
LAIR block is a covariable binding.** The graph is not derived from the
calculus; it is the calculus with N1–N3 applied.

### What LAIR is not

* **Not PIR** (`pear2_cfg.c3`): PIR is machine-flavored — slots, vregs,
  widths-as-integers, no producer/consumer sorts, no block parameters (label
  params are slots reloaded on entry). LAIR keeps the sorts and block
  parameters; whether the two ever converge is a later question, not a
  requirement of this slice.
* **Not LLVM IR**: no register SSA is constructed during lowering; phis appear
  only at print time, derived from block parameters (§3).
* **Not AIR 3.0's low profile**: that is a *restriction of AIR* (`docs/specs/
  AIR3.md`). LAIR is a different language with a different grammar (§2),
  derived from any canonical AIR 2.x file.

## 2. Grammar and data structures

```
LModule   ::= header  Decl*
Decl      ::= Extern | Def
Extern    ::= "extern" Ident "(" Type,* ")" "->" Type
Def       ::= "def" Ident "(" Param,* ")" "->" Type Block+
Block     ::= Label ":" Instr* Terminator
Label     ::= Ident | "%ret" | "^" digits          ; covariable identity
Param     ::= Ident ":" Type
Instr     ::= Ident "=" "cut" Op "(" Atom,* ")" ":" Type
            | Ident "=" "cut" Atom ":" Type         ; alias (μ̃ inline)
Terminator::= "ret" Atom
            | "jump" Label "(" Atom,* ")"
            | "br" Atom "," Label "," Label
            | "trap"
Atom      ::= Ident | IntLit | true | false | unit
Type      ::= i1 | i8 | i16 | i32 | i64 | u8 | … | u64 | f32 | f64 | ptr | unit
```

The header line mirrors AIR: `lair 0.1 <Module> "<source>";`.

In memory (`lair/lair_ir.c3`): `LModule → LFunc → LBlock → (LInstr, LTerm)`,
atoms as a small `LAtom` record, a 1 MiB slab arena in the AIR tradition.
Flat records, one enum per node class — same rationale as PIR's instruction
set (`pear2_cfg.c3` §"PIR instruction set").

## 3. Printing to LLVM (`.ll`)

The printer (`lair/lair_ll.c3`) is deliberately dumb; every decision was made
by the lowerer:

* **Atoms** are `%names` (block params, instruction results, function params)
  or literals. LLVM's typed-SSA is reconstructed, not maintained: within a
  block each `cut` prints as one instruction with one destination.
* **Block parameters → phis.** For block `κ(x, y)` with predecessors `p₁…pₙ`
  and edge arguments `(a₁,b₁)…(aₙ,bₙ)` the printer emits
  `x = phi T [a₁, p₁], …` — one phi per parameter, inputs taken from the
  edges. Because N1 guarantees edge arguments are atoms that dominate the
  edge, no parallel-copy hazard exists. This is the *only* place phis appear.
* **Terminators** map one-to-one: `ret`/`jump`/`br`/`trap`
  (`call void @llvm.trap()` + `unreachable`, matching pear2c and `air_ll`).
* **Declarations**: externs print as `declare`; `main` keeps its AIR signature
  (`define i64 @main()` — `scripts/ll-exe.py` links with gcc, and crt1 takes
  the low 32 bits of `rax` as the exit status, which is what the test harness
  observes).
* Provenance (`source_filename`, `!llvm.ident`, `!llvm.module.flags`) is
  copied from the pear2c conventions: a `.ll` that travels still says what
  produced it.

Anything the printer cannot print must have been refused by the verifier
(§4) with a position — the printer never invents.

## 4. Verifier (`lair/lair_verify.c3`)

LAIR is checked before it is printed, with the same philosophy as
`air_verify` — a backend refuses *its own* broken output loudly, because a
LAIR bug that reaches LLVM is a LLVM diagnostic with no file attached:

| rule | statement |
|---|---|
| L1 | every `jump`/`br` target exists; block arity = edge-argument count |
| L2 | every atom is bound before use (function params + block params dominate; instruction results dominate their uses inside the block) |
| L3 | every block has exactly one terminator; terminators are legal per §2 |
| L4 | edge argument types = target block parameter types; `ret` atom type = function return type |
| L5 | phi completeness: every block parameter has one incoming value per predecessor |

L2/L5 are checked with a trivial dominator walk over the LAIR CFG itself —
the verifier is also the first real test of the IR's shape.

## 5. The slice (what this round implements)

**Driver**: `lairc` — a *new, standalone* backend. The existing paths
(`pear2c`, `airtool emit-ll`, PEAR 1) are untouched; the later integration is
a flag (`pear2c --emit-bc=lair` style A/B), not a replacement, and is out of
scope here.

```
lairc FILE.air --check        # parse AIR → lower → verify LAIR; write nothing
lairc FILE.air --emit-lair    # write FILE.lair
lairc FILE.air --emit-ll      # write FILE.ll
lairc FILE.air --emit-bc      # NOT part of lairc: see below
```

The slice deliberately does **not** link LLVM: `lairc` is built from the AIR
reader slice plus its own sources only. Bitcode production therefore lives in a
companion script that loads `libLLVM-23` through `ctypes`, the same library
`pear2c` links: `scripts/ll-bc.py FILE.ll [-o FILE.bc]` — parse, `VerifyModule`,
`LLVMWriteBitcodeToFile`, then re-read the `.bc` through the parser as a
round-trip check. (A native `--emit-bc` is ladder phase 3; nothing in the IR
itself depends on LLVM.)

**Accepted AIR subset** (everything else fails closed with a position, per
`docs/pear2/CONTRACT.md` §2):

* declarations: `def`, `extern declare` (scalars only);
* producers: integer/bool/char/float/unit literals, variable references,
  `binop`, `unop`, `coerce` (integer width/signedness, bool↔int);
* commands: `mu~` (function exit binding), `let`, `seq`, block sugar,
  `if`, `while` (no carried label params yet), `match` with
  bind/wildcard/tuple-unit/integer/boolean/char arms, `nop`, `trap`;
* consumers: cut to covariable (`⟨v | %ret⟩`), direct/extern calls through
  `call · … · comu x. …` chains, `comu` value bindings;
* types: `i1/i8/i16/i32/i64`, `u8…u64`, `bool`, `char`, `unit`, `f32`, `f64`.

**Explicitly out of the slice** (phase 2+): labels/jumps/`break`/`continue`
(edge-argument machinery exists in the grammar from day one and is verified,
but the lowerer does not synthesize them yet), closures/`letrec`/`lambda`,
memory (`alloca`/`load`/`store`/`gep`), aggregates, strings, atomics/`asm`/
`syscall`, globals, multi-input merge.

**Fixtures**: the arithmetic/control subset of `tests/pear2/*.air` — ten of
them: `arithmetic_main`, `bindings_main`, `integer_let_chain`,
`if_compare_main`, `direct_call`, `bool_function_main`, `while_main`,
`char_main`, `coerce_integer_main`, `assert_trap_main` — driven by
`tests/lair/gate.sh`:

* `--check` on every fixture (parse → lower → verify, no LLVM needed);
* fail-closed negatives with exit codes and source positions per
  `CONTRACT.md` §2: exit 3 for AIR outside the slice (labels, closures,
  letrec), exit 1 for AIR the reader itself rejects;
* `--emit-lair` / `--emit-ll` shape assertions on one fixture;
* default mode: `.ll` → `scripts/ll-exe.py -O1` → run → exit status compared
  against the same expectation pear2's gate uses, then `scripts/ll-bc.py`
  for a valid, re-loadable `.bc`.

`opt_while_false_main.air` is excluded from the gate: the AIR reader rejects
its `while (false : bool)` form and `pear2c`/`airtool` reject it too — a
reader bug outside this slice, to be reconciled separately.

## 6. Ladder

1. **(this slice)** `make check-lair` green: lower + verify the subset above;
   `make test-lair` green: `.ll` executes with the right exit status.
2. Labels/jumps/break/continue through the edge-argument path; `phi` fixtures
   (`phi_while_carried`, `phi_nested_while`) run.
3. Bitcode from `scripts/ll-bc.py` A/B-compared against `pear2c --emit-bc`
   on the shared subset (behind the future `--emit-bc=lair` flag; identical
   *behavior* first, identical bytes only where deterministic).
4. Memory forms + aggregates; the coverage ladder of `BACKENDS.md` §3
   re-run with `lairc` as a third row.
5. The 48 `tests/exec/pear` fixtures at parity, then stdlib.

## 7. Layout

```
lair/
  lair_ir.c3        # LModule/LFunc/LBlock/LInstr/LTerm/LAtom + arena
  lair_lower.c3     # AirModule → LModule (N1–N3)
  lair_verify.c3    # L1–L5
  lair_write.c3     # .lair text
  lair_ll.c3        # LAIR → LLVM .ll text
  lairc_main.c3     # driver
docs/pear2/LAIR.md  # this file
tests/lair/gate.sh  # fixtures + expectations
scripts/ll-bc.py    # .ll → .bc via ctypes + libLLVM-23 (companion, not lairc)
```

`lairc` links only the AIR reader slice (`AIR_CORE` + `air_read`) plus its own
sources — no theory layer, no `pear2/`, and no LLVM at all: `--check`,
`--emit-lair` and `--emit-ll` never touch it. Only `scripts/ll-bc.py` loads
`libLLVM-23` (through `ctypes`, exactly the library `pear2c` links), and the
gate tolerates its absence in `--check` mode.
