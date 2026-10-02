# pear_ir — AIR λ̄μμ̃ bridge

## Files
| File | Purpose |
|---|---|
| `air.c3` | Public driver (module `air`). `emit_air_program` lowers every loaded module into one `AirModule` and writes the canonical `.air`; `emit_air` is the old pretty dump; `roundtrip_program` is the write/read fingerprint test. |
| `air_text.c3` | Shared vocabulary of the AIR 2.0 text (keywords, operator and type spellings, quoting). One copy, used by writer and reader. |
| `air_write.c3` | The canonical `.air` printer (+ `digest_module`, the structural fingerprint the round-trip test uses). |
| `air_read.c3` | Strict `.air` parser → `AirModule`. Claims (`facts`/`readonly`/`nocapture`) come back as candidates. |
| `air_verify.c3` | Validity rules V1–V4 and the counted conventions (`airtool verify`). |
| `air_facts.c3` | Effect/capture screen that decides which claims survive. |
| `air_ir.c3` | IR types (`AirTyp`, `AirPat`, `AirPrd`, `AirCns`, `AirCmd`, `AirDecl`, `AirBinder`, `AirField`, `AirBranch`, `AirCoBranch`, `AirFieldInit`, `AirCtorDecl`, `AirDtorDecl`, `AirEffectOp`, `AirModule`, `AirArena`) and smart constructors. Uses a 1MB slab bump allocator. |
| `air_scope.c3` | Name supply (`fresh_k_covar`, `fresh_x_var`, `fresh_label`), lexical scope stack with shadow-suffixing, return-covar stack (`push_ret`/`pop_ret`/`current_ret`) so `return` cuts to the innermost fn, loop-label stack. |
| `air_types.c3` | `PNode` → `AirTyp` translation; primitives (i8..i128/u8..u128/isz/usz/f16/f32/f64/f128/bool/char/str/bytes/unit/bottom/infer/ptr/ref/slice/array/tuple/sum/union/arrow/forall/exists/effrow); name resolution via interner. |
| `air_lower.c3` | PNode AST → AIR lowering. ~2.7k lines. Walks the post-theory PNode tree, builds an `AirModule` of λ̄μμ̃ terms. Key entry: `lr.module_body(root)`. |
| `air_emit.c3` | OLD lossy pretty-printer (`--emit-air-pretty`, diagnostic only; not the contract). `air_emit::emit_module(mod, lr, path)` prints clean, stubless AIR 1.0. Applies nop-elimination: `<()|μ̃x.c> → c`, dead-command elision after terminals, redundant unit-let suppression, and `<e|μ̃x.()>` detection for future `let x = e;` sugar. |

## Calculus recap (λ̄μμ̃, Curien & Herbelin 2000)
Three syntactic sorts:
- **Producers** (prd, `p`, `v`) — values/terms: variables, literals, tuples, sums, λ, μ-binders.
- **Consumers** (cns, `e`, `k`) — contexts/stacks: covariables, `·` stack-push, projections, field access, case/cocase, μ̃-binders.
- **Commands** (cmd, `c`) — cuts ⟨p\|e⟩ plus the two binders `μα.c` (producer-side activation) and `μ̃x.c` (consumer-side activation).

Key equations the lowerer implements:
```
call f(a,b,c;k)   ≡  <f | a·b·c·k>        (right-to-left argument push)
x.f               ≡  <x | .f·k>
return v          ≡  <v | %ret>            (cut to innermost fn's ret covar)
let x = e in rest ≡  <e | μ̃x.rest>
if p then t else e≡  <p | case{true→t; false→e}>
fn(x){b}          ≡  λx.<b|%ret>
def f(x) = b      ≡  f = μ̃%ret.(λx.<b|%ret>)
struct S {f:T}    ≡  codata S { .f(·) : T }
enum E {C(x)}     ≡  data E { C(x) }
```

## Design invariants
1. **Stubless**: no `*k*`, no `*dummy*`, no `<()|·>` admin nops, no leaked source spans in identifiers, no duplicated dead code after terminal commands.
2. **Right-to-left CPS**: compound subexpressions are bound in μ̃ *outside-in*, so evaluation order is respected and no continuation is dropped (every μ̃ body contains the rest of the computation — never `lr.nop()`).
3. **Terminal detection**: cuts to `%ret*`, jumps, traps, breaks, continues, and ub terminate; subsequent commands are dropped as dead code.
4. **Return stack**: each `fn`/`λ`/top-level def pushes its own `%ret_N` covariable; `return` always cuts to `lr.scope.current_ret()`.
5. **Arena dup**: every source-derived string that ends up in the IR is duplicated into the `AirArena` via `a.dup(s, len)` — raw `sptr` pointers into the PNode tree are only used transiently during lowering (except in narrow cases where sptr points directly at a leaf identifier).

## Build / test
```sh
~/c3bin/c3c compile --stdlib ~/c3lib \
  pfront/*.c3 pfront/pear_ir/*.c3 pfront/theory/*.c3 \
  pfront/theory/types/*.c3 pfront/theory/meta/*.c3 \
  pfront/theory/effects/*.c3 pfront/theory/rewrite/*.c3 \
  pfront/theory/lower/*.c3 pfront/theory/analysis/*.c3 -o pfrontc     # or: make   (no LLVM link any more)

./pfrontc path/to/prog.pie --emit-air       # writes path/to/prog.air (AIR 2.0, see docs/specs/AIR.md)
make airtool && tmp/airtool verify path/to/prog.air
```

Conformance test (`/tmp/everything.pie`): should emit `codata` for Expr/Hose/S/Node/Buffer/Ring plus `import mem;`. Remaining decls are collapsed by the theory pipeline *before* AIR sees them — this is upstream of the bridge, not a lowering bug.

## Debugging tips
- `AirLower` exposes counters (`lr.cuts`, `lr.mu`, `lr.mutilde`, `lr.jumps`, `lr.labels`, `lr.lets`, `lr.total_prd/cns/cmd/decl`, `lr.errors`) you can printf after `module_body()` for sanity checks.
- If you see source text in identifiers, look for a `node_text()` or `air_node_text()` caller that forgot to dup via the arena, or a type annotation whose `sptr` spans a multi-token construct (defensively fall back to `t_infer` in those cases).
- If you see `<()|μ̃x.()>`-style output, some `comu_cns` body is still `lr.nop()` instead of the actual continuation — use `bind_x_then`.
- C3 reminders (we all forget): no multi-pointer field decls (one per line); no reserved words (`cont`, `alias`, `bool`, `sz`, `any`, `err`, `mod`, `static`, `it`, `fn`, `var`, `module`); every `if/else` must wrap both branches in `{}`; methods on a struct are mutually visible without forward decls; arrays are `T[N] name`; no implicit narrowing casts (use `(long)` explicitly).
