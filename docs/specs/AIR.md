# AIR 2.1 — the `.air` text format

**Status: normative and implemented.** `pfrontc FILE.pie --emit-air` writes it, `airtool` and the legacy
backend `pear1c` read it, and `tests/air/run.sh` checks it. Where this document and the code disagree the
**code is wrong or this document is**: open a ticket, do not guess. The executable forms of this spec are
`pfront/pear_ir/air_text.c3` (vocabulary), `air_write.c3` (the one canonical printer), `air_read.c3` (the
strict parser) and `air_verify.c3` (validity rules).

AIR is Pride's intermediate representation, a sequent-calculus (λ̄μμ̃) term language. `pfrontc` ends at `.air`;
everything after it — PEAR 1 (legacy, `legacy/pear1/`), PEAR 2 (new) — is a *backend* that starts from the
file. This document is the whole interface between the two sides. The earlier design text is kept as
[`AIR-1.0-vision.md`](AIR-1.0-vision.md); it is aspirational and does not describe what is emitted.

Contents: 1 Why 2.x · 2 What a file is · 3 Lexical · 4 Grammar · 5 Names and scope · 6 Types · 7 Meaning of each
form · 8 Conventions a consumer must implement · 9 Claims (`facts`) · 10 Validity (V1–V4) · 11 What the producer
gets wrong today · 12 Path to a strict calculus · 13 Tools and tests

---

## 1 Why 2.x

AIR 1.0 (`AIR-1.0-vision.md`) was a design. The emitter printed a different, lossy notation (`μ̃%ret_2. <p|[0]·%ret_2>`,
`; air facts:` comments, only the entry module) that no parser could read back, and PEAR consumed the in-memory
graph, never the text. AIR 2.0 changes that contract:

* The text is **the** interface. A backend reads the file; it has no other access to the front end.
* The text is **lossless**: every field of the in-memory IR that any backend could read is printed, and
  `pfrontc --air-roundtrip` proves it by write → read → structural fingerprint (structure identical for all 216 programs of the exec, PEAR, pfront and examples suites that compile — the other 58 of the 274
  sources have front-end errors and by design emit no `.air`; before the split the
  LLVM bitcode of the original module and of the one read back from text was also byte-identical for the 180 programs the legacy
  backend could compile, and the legacy executables built through `.air` are byte-identical to the old direct path at -O0..-O3).
* The text is **canonical**: one printer, so `airtool fmt` of any producer output is byte-identical to the input.
* The text is **honest** about what the producer does *not* guarantee (§8, §10, §11) instead of describing an
  ideal calculus the compiler does not produce.

## 2 What a file is

One `.air` file is **one whole program**: every module the entry file loaded (including `prelude` and the
standard library), in load order, as a flat sequence of declarations. The entry module comes first.

```
// comment to end of line
air 2.2 Main "tests/exec/p03_fib.pie";    // header: format version, entry-module name, source path (or nil)

extern declare malloc(_ : i64) : ptr(u8); // declaration without a body (provided by the host / libc)

def fib(n : i64) : i64 =                  // definition
  mu~ %ret_2.
    ...;

module prelude;                           // marks where the next loaded module's declarations begin
def id_i64(x : infer) : infer = ...;
```

Rules:

* The header is mandatory and must be `air 2.2` (a reader also accepts `air 2.1` and `air 2.0` files, except that a 2.0 `syscall P(args)` is not
  accepted: 2.1 spells it `syscall(P, args) · k`; `asm`/`atomic` without `· k` are read as discarding in 2.0, and `perform` without `· k`
  is read as discarding in 2.0/2.1 — see §7a/§7b). Any other version is **rejected** (no best-effort).
* `module NAME;` is a marker only; it opens no scope. All names live in **one flat top-level namespace**.
* **Duplicate top-level names:** the *first* definition wins and later ones are ignored. The producer emits such
  duplicates today (e.g. `getpid` is defined by two library modules); backend 1 reports them and keeps the first.
  A consumer must do the same, not fail and not take the last.
* Entry point: the def named `main`. Its result is the process exit status (low 8 bits). Backend 1 links a fixed
  `_start` that calls `main` and exits with the result.
* Limits (enforced by the reader; exceeding one is an error with file:line:col): 4096 declarations, 16 binders per
  list, 16 operands per tuple/call/syscall/asm, 64 branches/constructors/destructors/fields, 8 type arguments.

## 3 Lexical structure

| token | form |
|---|---|
| whitespace | space, tab, CR, LF (insignificant) |
| comment | `//` to end of line |
| identifier | `[A-Za-z_%][A-Za-z0-9_%]*` that is not a reserved word; `%` is an ordinary identifier character (`%ret_2`, `%k17`) |
| quoted identifier | `` `any bytes` `` with escapes; used for reserved words and names with other characters (`` `ptr` ``, `` `\xc2\xb7` `` is the hole) |
| integer | `-?[0-9]+`, decimal, must fit `i64` |
| float | `-?[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?` with a `.` or exponent; written with `%.17g` so it round-trips |
| string | `"…"` — bytes, escapes `\\ \" \n \t \xHH`; no raw newline |
| bytes | `b"…"` — same escapes; a byte-string literal (no terminating NUL implied) |
| `·` | U+00B7 (UTF-8 `C2 B7`): the **stack separator** in consumers |
| `->` | arrow token |
| punctuation | `# ( ) { } [ ] < > \| , ; : . =` |
| `mu` / `mu~` | the ASCII words; the reader also accepts `μ` and `μ̃` (UTF-8) but the printer always writes ASCII |

A name that is a reserved word is always printed quoted. The reserved words are the keywords of the grammar below
plus the type keywords; the exact list is `air_text::is_reserved`. `nil` stands for an absent name/type/string.

## 4 Grammar

`X*` zero or more, `X,*` comma-separated, `[X]` optional. Terminals are in `monospace`. The grammar is the
language of `air_read`; `air_write` prints exactly it.

```
file      ::= header decl*
header    ::= air (2.0 | 2.1) NAME (STRING | nil) ;
NAME      ::= identifier | quoted-identifier | nil

decl      ::= module NAME ;
            | import (STRING | nil) [as NAME] [glob] ;
            | fn
            | data | codata | effect
fn        ::= [pub] [extern] [fastcc] [varargs] [link (STRING|nil)] [facts (ast_final|air_checked)] [readonly]
              (def | defco | declare) NAME [ "[" binder,* "]" ] "(" binder,* ")" [: type] [= cmd] ;
              -- `declare` has no body; `def`/`defco` have one (V4)
data      ::= [pub] data NAME [lin|aff] [ "[" binder,* "]" ] "{" ctor* "}" ;
ctor      ::= ctor NAME "(" field,* ")" [: type] ;
codata    ::= [pub] codata NAME [lin|aff] [ "[" binder,* "]" ] "{" ( op NAME "(" field,* ")" [: type] ; )* "}" ;
effect    ::= [pub] effect NAME "{" ( op NAME : type ; )* "}" ;
field     ::= [mut] [lin|aff] NAME : type
binder    ::= [mut] [nocapture] [lin | aff | exact "(" INT ")"] NAME [: type]

type      ::= nil | TYPEKW [NAME] [# INT] [ "(" type,* ")" ] [tail "(" type ")"]
              -- NAME only for nominal path tvar forall exists generic
              -- "# INT" only for array (length), effrow, refine
              -- TYPEKW ∈ i8 i16 i32 i64 i128 isz u8 u16 u32 u64 u128 usz f16 f32 f64 f128 bool char str bytes
              --          unit bottom infer self nominal path tvar arrow tuple array slice ptr ref refmut sum union
              --          intersect neg forall exists bang query effrow typeof refine generic

cmd       ::= nil
            | "<" prd "|" cns ">"                                  -- cut: the only way a value meets a continuation
            | mu NAME . cmd | mu~ NAME . cmd                       -- bind a covariable / a variable to "the rest"
            | seq "{" cmd ; cmd "}"                                -- do the first, then the second
            | let NAME = prd in cmd
            | letrec "(" binder = prd ,* ")" in cmd
            | if prd then cmd else cmd
            | while prd do "{" cmd "}"  |  for NAME in prd do "{" cmd "}"
            | match [dense] prd "{" branch* "}"
            | handle "{" cmd "}" "{" branch* "}"  |  perform NAME "(" prd ")" result  |  resume "(" prd ")"
            | label NAME "(" binder,* ")" . cmd  |  jump NAME "(" NAME,* ")"  |  break NAME  |  continue NAME
            | (block|unsafe|unchecked|comptime|defer) "{" cmd "}"
            | (assert|assume|ret) "(" prd ")"  |  ub (STRING|nil)  |  trap  |  nop
            | syscall "(" prd,+ ")" result  |  asm [intel|att] (STRING|nil) "(" prd,* ")" result
            | atomic ATOMICOP ORDER "(" prd,+ ")" result  |  fence ORDER
result    ::= "·" cns          -- syscall/asm/atomic: required since 2.1 (2.0: absent, discarded); perform: required since 2.2
branch    ::= pat [guard "{" cmd "}"] -> cmd ;
ORDER     ::= relaxed | acquire | release | acq_rel | seq_cst
ATOMICOP  ::= load store xchg add sub and or xor nand max min umax umin

prd       ::= nil | prdcore [: type]                                -- `: type` = the type the front end resolved
prdcore   ::= NAME                                                  -- variable
            | INT | FLOAT | true | false | char "(" INT ")" | STRING | BYTES | unit | null
            | con NAME [ "(" prd,* ")" ] | tuple "(" prd,* ")" | array "(" prd,* ")"
            | record "{" (NAME = prd),* "}"
            | inl "[" type "]" "(" prd ")"  |  inr "[" type "]" "(" prd ")"
            | lam "(" binder,* ")" . cmd  |  cometa "(" binder,* ")" . cmd  |  mu NAME . cmd
            | "(" BINOP prd prd ")"  |  "(" UNOP prd ")"
            | coerce "(" prd , type ")" | sizeof "(" type ")" | alignof "(" type ")" | offsetof "(" type , NAME ")"
            | reify cmd | quote cmd | eval "(" prd ")" | splice "(" prd ")"
            | poison "(" type ")" | unreachable
            -- `: type` is printed inside the form (not as a suffix) for coerce sizeof alignof offsetof poison
BINOP     ::= add sub mul div mod and or xor shl shr land lor eq neq lt gt le ge pipe
UNOP      ::= neg not bitnot deref ref addr comult

cns       ::= nil
            | NAME                                                  -- covariable: a continuation / a return point
            | prd · cns                                             -- stack: supply an argument, continue
            | (fst|snd|deref|default|share|erase|call) · cns
            | proj INT · cns
            | field NAME # INT · cns
            | index "(" prd ; INT ")" · cns  |  store "(" prd ; INT ")" · cns
            | as "(" type ")" · cns
            | case [dense] "{" branch* "}"
            | cocase "{" ( . NAME "(" NAME,* ")" -> cmd ; )* "}"
            | comu NAME . cmd                                       -- bind the delivered value, continue with cmd

pat       ::= nil | _ | bind NAME | INT | true | false | char "(" INT ")" | STRING | FLOAT
            | tuple "(" pat,* ")" | array "(" pat,* ")" | record "{" NAME,* "}"
            | ctor NAME [ "(" pat,* ")" ] | as "(" pat , NAME ")" | or "(" pat , pat ")" | ref "(" pat ")" | rest
```

Layout (indentation, line breaks) is produced by the canonical printer and carries no meaning. **Do not
hand-edit canonical files; run `airtool fmt`.**

## 5 Names and scope

Names are plain strings. Variables and covariables share one lexical alphabet but are used in different
positions: a *variable* in a producer, a *covariable* as a consumer.

**What the producer actually guarantees** (checked by `airtool verify`, §10) is weaker than lexical nesting:

1. A function body is `mu~ %ret_N. c` (see §8): `%ret_N` is its return continuation.
2. `seq { a ; b }` is not a scope boundary. A binder introduced by a `comu x.` (or `let`) inside `a` — in
   particular `comu x. <unit | ·>` used as *assignment/definition* — is **visible in `b`** and in the rest of the
   enclosing sequence. Binders are unique per function in practice (`_x17`, `base`, `a_1`) but **mutable variables are
   rebound by repeating the binder** (`comu base. …` assigns `base`).
3. A `label L(…). c` defines a block. `L` is visible in its own body (loop back-edge) and in the **second half of
   the `seq` whose first half is the `label`** (the jump that enters it).
4. A variable that is not bound in the function and not a top-level declaration, constructor or effect operation is
   only legal as the *receiver of a `field` chain* (module-path root, §8 N1). Any other free variable is a producer
   defect (§11).

A consumer must therefore resolve names by **function-wide flat scope with definition-before-use in sequence
order**, not by lexical nesting. Section 12 describes the plan to remove this gap.

## 6 Types

Types are **hints from a front end that does not finish type inference**. Today most function signatures print
`infer`; integer literals carry `: infer` unless the source annotated them. Nothing in the pipeline checks AIR
types, and the legacy backend treats every scalar as 64-bit (`i8/i16/i32/u8/u16/u32` select narrower LLVM integers,
`bool` is `i1`, `ptr/ref/refmut` are pointers held as 64-bit integers, `unit/bottom` are void, everything else
including `infer` is `i64`). A new backend may be stricter but must not *rely* on a type being present or exact.

`: T` after a producer is the type recorded for that node; it is part of the contract (backends size integer
literals from it). `as(T) · k` is an ascription/cast of the delivered value to `T`.

## 7 Meaning of each form

"Executable" = the legacy backend runs it correctly in the exec suites; "emitted" = the front end produces it but no
backend runs it correctly yet. Frequencies of every form in real output: [`docs/pear2/COVERAGE.md`](../pear2/COVERAGE.md).

**The cut** `<p | k>` delivers the value of producer `p` to consumer `k`. All control flow is cuts.

| form | meaning | status |
|---|---|---|
| `mu~ x. c` | run `c` with `x` bound to the incoming value (as a function body: the argument pattern, with `x` the return continuation) | executable |
| `mu k. c` (producer) | evaluate `c`; a cut to `k` inside produces this producer's value | executable |
| `comu x. c` (consumer) | receive the delivered value as `x`, continue with `c`; `x` may be `_` or `·` to discard | executable |
| `seq { a ; b }` | run `a`, then `b` | executable |
| `let x = p in c` | evaluate `p`, bind `x`, run `c` | executable |
| `if p then a else b` | `p` is a boolean (comparison or `bool` value) | executable |
| `match p { pat -> c; … }` / `case { … }` | first matching branch; patterns left to right; `guard {c}` extra condition; `dense` = the producer asserts a dense integer switch | executable for scalar, wildcard, bool and int patterns; tuple/constructor/record patterns only partly (see `tests/exec/XFAIL.tsv`) |
| `call · a · b · k` | call the delivered function value with args `a b`, deliver the result to `k` | executable for direct calls by top-level name; calls through function values are not exercised by the passing suites |
| `field f # i · k` | field `f` of the delivered record; `i` is its declaration slot (negative = unresolved) | executable (every field is one 64-bit slot) |
| `index(i ; n) · k` | element `i` of the delivered pointer, element size `n` bytes | executable (sizes 1, 2, 4, 8) |
| `store(v ; n) · k` | store `v` (truncated to `n` bytes) at the delivered address, then continue with `0` | executable |
| `as(T) · k` | convert/ascribe to `T` | executable as used by the passing suites (integer and pointer widths) |
| `fst`, `snd`, `proj i`, `deref`, `default`, `share`, `erase` | pair/tuple projection, dereference, multiplicity operations | emitted for fst/snd/proj; the rest never produced |
| `label L(x…). c` / `jump L(a…)` | block definition / transfer to it (loops are label + jump) | executable |
| `(op a b)` | binary operation; `div`/`mod` division by zero is **not** modelled (no trap) | executable |
| `syscall(n, a…) · k` | Linux syscall number `n` with arguments; the result is delivered to the consumer `k` | emitted with operands and result since 2.1; PEAR 1 calls libc `syscall` (variadic) |
| `asm "t"(a…) · k`, `atomic op ord(p, v…) · k` | inline assembly / atomic read-modify-write; result delivered to `k` | emitted since 2.1 when written in source; **PEAR 1 rejects them with a diagnostic** (it used to compile them to nothing) |
| `perform Eff.op(p) · k`, `handle`, `resume` | algebraic effects (§7b) | emitted since 2.2 with the operation name, payload, resumed-value consumer and handler binders; **PEAR 1 has no handler runtime and now says so** (ledger P04–P06) |
| `quote`, `reify`, `eval`, `splice` | staging | emitted as free variables (§11); unsupported |
| `ub "msg"`, `trap`, `poison(T)`, `unreachable` | undefined behaviour made explicit | emitted; not exercised by a passing suite |
| `fence`, `while`, `for`, `letrec`, `break`, `continue`, `ret`, `con`, `inl`, `inr`, `cometa`, `cocase`, `defco` | defined by the grammar | **never produced** today (loops are label/jump; see COVERAGE.md) |

Integer arithmetic is two's-complement at the width of the operands (64-bit when `infer`). Signedness comes from the
type annotation; `infer` is treated as signed.

### 7a Primitives with results (2.1)

`syscall`, `asm` and `atomic` produce a value. In 2.0 the text had no place for it: the producer printed
`syscall nil();` for `let n = syscall(39, …)`, dropping both the operands and the result. 2.1 follows the rule used
everywhere else in the calculus — **a command that yields a value ends in a consumer**:

```
syscall(1 : i64, 1 : i64, _x2, 14 : i64) · comu _x1.      -- write(1, buf, 14); the byte count is _x1
  syscall(231 : i64, 0 : i64) · %ret_2
```

Operands are evaluated left to right; a non-trivial operand is bound first (`<e | comu _xN. …>`), so the operand list
holds only producers. The syscall number is the first element of the list (so `syscall(n)` has one element and a
typed literal number never abuts `(`). A 2.1 reader **fails** on a primitive without `· k`; a 2.0 file keeps parsing
and the result consumer is null (discarded).

String and byte-string literals carry the **decoded bytes** (quotes stripped, `\\ \" \n \t \r \0 \xHH`
resolved). Before 2.1's producer the token's source text, quotes and escapes included, was emitted, so
`"Hello\n"` printed as `"Hello\n"` with the quotes.

### 7b Effects and guards (2.2)

*HOSE.* Three producer defects made handlers unreadable by any backend; 2.2 fixes the lowering and the one missing
piece of syntax:

```
handle { <worker | call · 5 : i64 · %ret_2> } {
  ctor `Ask.ask`(bind q, bind k) ->                  -- branch pattern = the operation, then payload binder(s), then the continuation
    <(mul q 10) | comu _x4. <k | call · _x4 · %ret_2>>;
}
perform `Ask.ask`(n) · comu _x3. let a = _x3 in …    -- `· k` receives the value the handler resumes with
```

* `perform Eff.op(p) · k` — operation names are qualified (`Eff.op`) everywhere; the call form `Eff.op(args)` on an effect name
  is a `perform`. Before 2.2 the result of a `perform` could not be consumed (`let a = Ask.ask(n)` lost `a`), and the call form
  was lowered as an ordinary method call through a field of the effect.
* A handler branch's pattern is the variant `Eff.op(payload…, k)`: the payload binders, then the continuation binder when the
  source names it. Before 2.2 the pattern was `_`, the binders vanished (V3 on `q`, `k`) and a spurious `<unit | %ret>` was
  sequenced before the arm body.
* `resume(p)` / `<p | %resume>` is unchanged (convention J2).
* **Guards:** `pat guard { c } -> body` — `c` is a command that cuts a boolean to the implicit covariable `%guard` (bound by the
  guard itself; the verifier scopes it). The branch is taken only when the pattern matches **and** the boolean is true; otherwise
  matching continues with the next branch. Clause guards (`| (a, b) if a > b -> …`) and match-arm guards (`| k, k > 0 -> …`) are
  produced; before 2.2 both were silently dropped, which made a guarded clause unconditional.

None of this executes today: PEAR 1 has no handler runtime and does not implement guarded branches (§7). What changed is that a
backend can now *see* the program.

## 8 Conventions a consumer must implement

These are properties of the *current producer*, relied on by the legacy backend by name. They are
counted, not hidden, by `airtool verify`. PEAR 2 must implement them or the producer must be changed (§12).

| id | convention |
|---|---|
| R1 | **Return**: a covariable named `%ret` or `%ret_N` is the function's return continuation; a cut to it returns. A function body is `mu~ %ret_N. c`. |
| H1 | **Hole**: the covariable `·` (quoted `` `\xc2\xb7` ``) in a cut `<p | ·>` means *evaluate `p` for its effect, discard the value, continue with the code that follows in the enclosing `seq`*. |
| J1 | **Implicit join**: a covariable `%kN` that no `mu` binds is a *join point*: `<p | %kN>` means "deliver `p` to the join and continue with the code that follows the cut in the enclosing sequence". A `mu %kN. …` that *does* bind it is an ordinary producer binder. (239 per program in the library alone.) |
| T1 | **Temporaries**: `_xN` names are single-assignment temporaries introduced by `comu _xN. …`. |
| L1 | **Loops**: `%loopN` / `%exitN` name labels of the loop's entry and exit blocks; `label %exitN(). <exit code>` followed in the enclosing `seq` by a `label %loopN(). <body>` and `jump %loopN()`. |
| A1 | **Assignment**: `<v | comu x. <unit | %kN>>` where `x` is already bound re-assigns the mutable `x`. |
| N1 | **Module-path root**: an unbound variable that is the receiver of a `field` chain (`<os | field linux #0 · field PROT_READ #0 · …>`) names a loaded module or a top-level constant of it; resolve it against the program. 414 per program in the library alone. |
| J2 | `%resume`: implicit resume continuation inside a handler clause. Unsupported (effects). |
| D1 | **Duplicates**: first definition of a top-level name wins (§2). |
| E1 | **Externs**: `extern declare` names are resolved by the platform linker (libc); backend 1 links libc dynamically. |

## 9 Claims (`facts`, `readonly`, `nocapture`)

The text may carry **qualifier claims** the front end derived: `facts air_checked`, `readonly` on a def (the
function reads memory only), `nocapture p` on a parameter (the callee does not retain the pointer). They are
**candidates, never facts**:

* the reader returns every claim as `ast_final` (never `air_checked`);
* the consumer **must re-screen** with the shared screen (`air_facts::validate_module`, or its own equivalent) before
  turning a claim into an optimisation attribute (LLVM `memory(read)`, `captures(none)`, `nofree`, …);
* a claim the screen cannot prove is **dropped**, so a forged or stale claim cannot authorise an attribute.

`tests/air/forged/claims.air` forges `readonly`/`nocapture` on a writer and a pointer-retaining function; the suite
asserts the claims vanish and a sound `nocapture` on an untouched parameter survives. The screen is conservative: it
proves *weak* properties and answers "unknown" otherwise (design: `docs/dev/THEORY_AIR_CONTRACTS.md`). Nothing here
is a formal-verification claim.

## 10 Validity

`airtool verify FILE.air` checks, per definition (rules are in `air_verify.c3`):

* **V1** every consumer covariable is `%ret`/`%ret_N`, the hole, bound by an enclosing `mu`/`mu~`/`comu`/`label`/cobranch
  — or is a counted convention (J1 `%kN`, J2 `%resume`);
* **V2** every `jump`/`break`/`continue` target is a visible `label` (§5.3);
* **V3** every variable is bound somewhere in the definition (parameter, `let`, `letrec`, `lam`, `comu`, `mu~`,
  pattern binder, label parameter) or is a top-level name/constructor/operation — or is a counted N1 root;
* **V4** `def` has a body, `declare` has none, declarations have names.

Output: `verify: N violation(s) V1=… V2=… V3=… V4=… | conventions: J1=… N1=… J2=…`; exit 0 only for N = 0. The
**corpus ledger** `tests/air/VERIFY_KNOWN.tsv` lists every program of the suites whose `.air` violates a rule; the
test requires an exact match in both directions, so it is a ratchet (§12).

## 11 What the producer gets wrong today

Measured on the real corpus (`tests/air/VERIFY_KNOWN.tsv` and `docs/pear2/COVERAGE.md`); each is a front-end defect,
none is a property of the source programs:

1. ~~**`syscall` loses its operands.**~~ Fixed in 2.1 (§7a). `syscall` programs now print: `01_hello` passes. The other
   exec cases in `tests/exec/XFAIL.tsv` that used to be masked by this are now individually listed with their real
   reason (front-end rejection, clause-style functions in PEAR 1, …).
2. **Unbound variables** (V3, 13 corpus programs, was 22): the staging builtins `quote`/`eval`/`reify`, session endpoints `tx`/`rx`,
   enum payload clauses (`{ A: a } -> a + 100`), and block-scope leaks. Fixed in 2.2 lowering: handler binders `q`/`k`, destructuring
   `let (a, b) = t`, rewrite-rule clauses (now classified compile-time-only and no longer lowered as garbage). A consumer must treat such a variable as **unsupported and diagnose it**; never as an external symbol.
3. **Dropped statements.** Lowering no longer drops any statement of an entry module (`scripts/air-audit.py`: 0 of ~13,000
   constructs unlowered, was 561 — see `docs/pear2/LOWERING.md`). One case remains, and it is not the lowering:
   `tests/pfront/45_opt_branch.pie` at -O2 (`let r = if … ; while 0 …; r`) reaches the lowering as `(block (ident r))` — the
   middle-end optimizer (with the theory layer on) deleted the `let` but kept the use, and its own pass report says
   "1 declaration(s) vanished with no pass claiming them". At -O0 and with `--no-theory` the `.air` is complete.
4. **Types are mostly `infer`** (§6), and effect/handler constructs do not execute (§7).
5. **Flat scoping and implicit joins** (§5, §8) — the representation relies on naming patterns.

## 12 Path to a strict calculus

The goal of "strict λ̄μμ̃" is a `.air` in which §5 and §8 collapse to ordinary lexical scoping with no conventions.
It is **not** reached by this format change and no document may claim it is. Plan (each step is measurable with the
verifier ratchet and a differential on the exec suites):

1. *Writer-side `seq` normalisation:* print `seq`/`let`/`comu` so a binder encloses exactly what it scopes (kills §5.2).
2. *Explicit joins:* lower `%kN` to `mu %kN. …` binders at the join point (kills J1) — the largest single change.
3. *Resolve module-path roots* in lowering to the constant they name (kills N1).
4. *Fix the lowering defects of §11* (syscall operands, dropped statements, unbound binders).
5. *Types:* carry resolved types instead of `infer`.

When V1–V3 and the conventions are all zero over the corpus, the verifier can be made strict and this document
bumps to AIR 3.0 (a reader that only knows 2.x keeps working for files with no conventions).

## 13 Tools and tests

| command | what |
|---|---|
| `pfrontc FILE.pie --emit-air` | write `FILE.air` (whole program; refused if the program has errors) |
| `pfrontc FILE.pie --emit-air-pretty` | old lossy human dump of the entry module (diagnostic only) |
| `pfrontc FILE.pie --air-roundtrip` | test: write → read → structural fingerprint, prints `roundtrip: structure identical (…)` |
| `airtool check FILE.air` | parse only |
| `airtool verify FILE.air` | parse + V1–V4 |
| `airtool fmt FILE.air [-o OUT]` | canonical re-print (re-screens claims) |
| `pear1c FILE.air [--emit-exe\|--emit-bc] [-O0..-O3]` | legacy backend |
| `scripts/pie-exe.sh FILE.pie …` | the whole chain, old `pfrontc --emit-exe` CLI |
| `make test-air` | `tests/air/run.sh`: good/bad/forged `.air`, corpus emit + canonical + verify ledger, round trip |
