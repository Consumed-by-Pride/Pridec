# Is the `.bc` backend complete?

Short answer: **complete with respect to what the front end produces, and not
complete in the two senses that matter more.**

This page is written so the claim can be audited rather than believed. Every
number below was produced by a script over the tree, and the commands to
reproduce them are at the end.

## Three meanings of "complete"

1. **Covering.** Every form the producer can emit is either lowered or refused
   with a reason. This is measurable, and it is *yes*.
2. **Failing closed.** Every form that is not lowered is refused rather than
   silently mis-compiled, at a source position, before any artifact is written.
   This is *yes*, and the tests pin it.
3. **Verified.** Every claim above has been observed on a running binary. This is
   *no*: this workspace has no LLVM and no working C3 code generator, so nothing
   in `pear2/` has ever executed. `make check-pear2` proves the tree type-checks;
   `make probe-pear2` and `make test-pear2` need a machine that can link LLVM.

Only (1) and (2) can be argued here. (3) is open, and is recorded as such in
`QUALITY_CHECKLIST.md` rather than described as passing.

## 1. Covering: measured against the producer

`pear2c` reads the **AIR 3.0 low profile** produced by
`pfront/pear_ir/air_low.c3` (not the untyped AIR 2.x of `air_lower.c3`, which
PEAR 1 consumes). Counting the tags that pass can actually reach — direct
assignments plus the constructors it calls, transitively, with comments stripped
— gives the surface the backend has to cover:

| enum | tags the low profile can emit | handled by `pear2c` |
|---|---|---|
| `AirTypTag` | 10 of 49 | 10 (two are intercepted upstream) |
| `AirPrdTag` | 16 of 34 | 16 |
| `AirCmdTag` | 9 of 34 | 9 |
| `AirCnsTag` | 1 of 20 | 1 |

Two caveats, both in the backend's favour:

- `ATYP_STR` and `ATYP_BYTES` appear in the low profile only as a guard: `Low.ty`
  intercepts the names `str` and `ptr` and desugars slices and strings into
  `{ptr, len}` records named `str` / `slice.<mangled>`. They are therefore never
  produced, and the record path lowers them.
- `pear2c` handles **more** than the current producer emits: 24 of 49 type tags,
  28 of 34 producer tags, 32 of 34 command tags, and all 20 consumer tags. The
  surplus is deliberate — `match`, `while`, `if`, closures, effects, atomics,
  `syscall` and `asm` are all lowerable even though today's lowering pass turns
  control flow into labels and jumps and does not emit them. When the producer
  grows, the backend is not the thing that has to change first.

The unhandled tags are, in every case, unreachable from the producer *and* have no
sensible lowering in this model: `ATYP_REF`/`ATYP_REF_MUT` (`air_lower` mentions
them only in a defensive guard), `APRD_OFFSETOF`, `APRD_INL`/`APRD_INR`,
`APRD_POISON`, `APRD_UNREACHABLE_VAL`, `ACMD_DEFER`, `ACMD_INVALID`. A refusal
there is a fail-closed path, not a silent one.

## 2. Failing closed: what the model proves

The backend's actual product is not code, it is **claims about memory**. What it
can prove, and what it refuses, is the honest measure of completeness:

- Three answers for an access, in order of strength: **exact** (offset is a
  constant; bounds and alignment proved at compile time), **interval** (offset is
  a tight range inside the object), **runtime** (a check is emitted that traps
  unless `addr >= base && addr + size <= end`). There is no fourth answer: a
  pointer with no provenance is refused.
- Chained dynamic indices (`p[i][j]`) work because the promise is attached to the
  *access*, not the GEP. Two dynamic indices inside one GEP are refused.
- Heap objects may be sized at run time (`malloc(n)`, `realloc(p, n)`): the
  extent moves into a register and the same comparison is emitted against it. The
  check adds `base != null` so a failed allocation cannot look like an empty one.
- Calls are not invisible: a callee that can write through a pointer invalidates
  the pointer cells inside that object. "Can write" is a body scan for callees in
  the file, and *yes* for external symbols and indirect calls — so the rule is
  fail-closed, and read-only helpers keep cells alive.
- `memcpy`, `memmove` and `memset` are bounds-checked as byte ranges, with the
  length taken from a literal or a register.
- Pointer cells are per function; the cells that must outlive a body (a pointer
  already inside a global) live in their own table.
- Two dynamic indices in one GEP, out-of-bounds constants, misaligned accesses,
  stores through immutable globals, freed and interior pointers, null function
  pointers, oversized constant copies, and unrecognised AIR forms all fail closed
  with `file:line:col`, exit 3, and no artifact written.

That is the whole of the model: **an access is allowed only when it can be proved
or checked, and a program that cannot be lowered is refused with a position.**

## 3. What is *not* complete

| gap | state | why it is not this backend's next step |
|---|---|---|
| execution evidence | none here | needs LLVM or a C3 code generator; every claim above is review-only until then |
| debug info | absent on every path | a `.bc` with no DI is valid and optimises; it is a real gap for a 10k-line program, and unverifiable without a linker |
| stdlib | 260 modules exist, never lowered | needs the front end to pick them up first |
| generics *library* | monomorphised by the lowering pass, so the backend sees concrete records (`Vec.i64`) — it is not blocked | writing the library is a source-level job |
| growable strings | literal arrays only | a library, not a lowering |
| writes inside libc other than the three bulk operations | cells are dropped (sound), bytes are not checked | the compiler cannot bound a library's internal writes |
| resuming effect handlers | one-shot, non-resuming handlers only | multi-shot continuations need a runtime, not an emitter |
| ref types | no producer | unreachable from the front end |

## Reproducing the numbers

```sh
# the tree type-checks (works without LLVM)
make check-pear2 C3C=/path/to/c3c C3C_LIB=/path/to/c3/lib/std

# how much of the corpus this backend can actually lower (needs a pear2c linkable
# against LLVM; creates no LLVM context at run time)
make probe-pear2

# the full behavioural suite: builds, links and runs every fixture (needs LLVM)
make test-pear2
```

The tag-coverage table comes from a script that parses `pfront/pear_ir/air_ir.c3`
for the four tag enums, collects the tags reachable from `air_low.c3` (direct
assignments plus the `air_ir` constructors it calls, transitively, comments
stripped), and greps `pear2/*.c3` for `tag ==` comparisons and `case` arms. It is
a coverage measurement, not a proof; the prose in `CONTRACT.md` is the contract,
and `GAPS.md` is the list of what that contract does not cover.
