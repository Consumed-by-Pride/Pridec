# AIR 1.0 — Abstractive Intermediate Representation
## (Text Syntax for the λ̄μμ̃-calculus, Pride PEAR frontend)

> *Writing code in Pride is a piece of cake... well, a piece of `.pie`.*
> *Emitting AIR is a piece of PEAR.*

AIR is Pride's primary intermediate representation. It is a classical sequent
calculus in the style of Curien–Herbelin's **λ̄μμ̃** (2000), extended with
(polarized) algebraic data/codata types, (co)pattern matching, explicit
binders for producers/consumers, a labelled jump/multi-cut construct for
control flow, and graded (linear/affine/unrestricted) multiplicity
annotations.

After pfront resolves, type-checks and analyzes a `.pie` module, the
`pfront/pear_ir` pass lowers the program to AIR text (`*.air`), one file
per compilation unit. AIR is later consumed by **PEAR** (Program Engine
for Abstractive Representations), which focusses, normalizes to **AxCut**
(Schuster/Müller/Ostermann/Brachthäuser 2025), and emits LLVM bitcode.

This document is the **only normative specification** of AIR's surface
syntax.  Anything the emitter produces that matches this grammar is valid
AIR; anything PEAR accepts must conform to it.

---

## 1. Lexical structure

### 1.1 Identifiers

```
<varid>  ::= <lower>  <alnum> '-' '_' '/'        // producer variables, type vars, fields
<covar>  ::= <alpha>  <alnum>*                  // co-variables / continuation names,
                                                 // leading character α β γ δ ε κ ρ σ τ φ ψ
                                                 // or a '%' sigil if non-Greek: %ret %k %exit
<conid>  ::= <upper>  <alnum>                    // data/ctype constructors, type names
<opid>   ::= [-+*/<>=!&|^~$#@.]+                 // operator symbols for infix consumers
<num>    ::= '-'? [0-9][0-9_]* ('.' [0-9][0-9_]*)? ('e' '-'? [0-9]+)?
<bits>   ::= 'i' [0-9]+ | 'u' [0-9]+ | 'f' [0-9]+        // fixed-width numeric types
<char>   ::= "'" (<any except \ or '> | '\' <esc>) "'"
<string> ::= '"' (<any except \ or "> | '\' <esc>)* '"'
<esc>    ::= '\' ['"?\\abfnrtv] | '\x' <hex> <hex>
```

Keywords (reserved):
```
prd cns cmd            // sort ascriptions
fn data codata         // top-level forms
def defco              // producer/consumer definitions
declare                // extern/import
module import          // module structure
μ mu μ̃ mu~ coμ comu    // μ/μ̃ binders (μ̃ can be written `mu~`)
cut < p | e >          // cuts  (syntactically a pair of angle brackets)
λ \ fun                // lambda (prd-side binder)
case of inl inr        // sums
fst snd                // product projections (cns-side)
proj #                 // projection (proj #n e   for tuples/records)
ret jump label         // multi-cut / labels
let in                 // non-recursive let (sugared μ/μ̃ pair)
rec                    // recursive let-group
if then else           // boolean conditionals (sugared case)
while for loop break continue defer   // control-flow sugar
handle perform resume  // algebraic effects (sugared μ/μ̃)
true false unit null   // constants
i8 i16 i32 i64 i128 isz
u8 u16 u32 u64 u128 usz
f16 f32 f64 f128       // fixed-width primitives
bool char str bytes    // primitive type names
unsafe comptime        // phase markers
lin aff unr            // multiplicity
not and or xor shl shr // primops
at exit                // defer/exit markers
_                      // wildcard
```

### 1.2 Comments

```
// line comment
{- block comment {- may nest -} -}
```

### 1.3 Layout

AIR is **whitespace-insensitive** (like LLVM); `;` optionally separates
sequential commands. Indentation is not significant. Curly braces
`{ }` group sequences; parentheses `( )` group expressions.

---

## 2. Programs and modules

```
<program> ::= (<toplevel>)*

<toplevel> ::= 'module' <conid> ('.' <conid>)* ';'
            |  'import' <qname> ('as' <conid>)? ('hiding' '(' <namelist> ')')? ';'
            |  'declare' <decl>         ; foreign declaration (no body)
            |  'data'    <datadecl>
            |  'codata'  <codatadecl>
            |  'def'     <def>          ; producer definition
            |  'defco'   <codef>        ; consumer definition
            |  ';'
```

### 2.1 Data types (algebraic, positive)

```
<datadecl> ::= <qconid> <typarams> <mult>? ('where' '{' <ctrdecl> (';' <ctrdecl>)* '}')?

<ctrdecl>  ::= <conid> '(' <fieldlist>? ')' ':' <typ>          // constructor is a producer
<fieldlist>::= <field> (',' <field>)*
<field>    ::= <mult>? <typ> <varid>?
<typarams> ::= ('[' <tyvar> (',' <tyvar>)* ']')?
<tyvar>    ::= <varid> (':' <kind>)?
<kind>     ::= '*' | '<kind>' '->' <kind> | '(' <kind> ')'
```

A `data` declaration introduces a **positive/inductive** type:
- Each `<ctrdecl>` binds a producer constructor `<conid>` which, when cut
  against a consumer of the enclosing type, fires the matching pattern.
- Producers are introduced (right-rule in the sequent calculus) by
  applying the constructor; consumers are eliminated (left-rule) by
  `case { C1 x1 -> c1; ... Cn xn -> cn }`.

### 2.2 Codata types (coinductive, negative)

```
<codatadecl>::= <qconid> <typarams> <mult>? ('where' '{' <dtordecl> (';' <dtordecl>)* '}')?

<dtordecl> ::= <varid> '(' <fieldlist>? ')' ':' <typ>          // destructor is a consumer
```

A `codata` declaration introduces a **negative/coinductive** type:
- Each `<dtordecl>` binds a consumer destructor `<varid>` (like a method
  or a field projection).
- Consumers are introduced by `comu { l1 x1 -> c1; ... ln xn -> cn }`
  (a co-case / object-style cobind), and producers are eliminated by
  projection (`proj #l e` or `.l`).

Records and objects are codata; `&T` references, slices and lazy
structures live here too.

### 2.3 Producer/consumer definitions

```
<def>  ::= <varid> <typarams> <arglist> (':' <typ>)? '=' <cmd>  ';'
<codef> ::= <covar> <typarams> <coarglist> (':' <typ>)? '=' <cmd> ';'

<arglist>   ::= '(' <binder> (',' <binder>)* ')'
<coarglist> ::= '[' <cobinder> (',' <cobinder)* ']'
<binder>    ::= <mult>? <typ>? <varid>
<cobinder>  ::= <mult>? <typ>? <covar>
```

- `def foo(x:i32, y:i32): i32 = < (+ x y) | %ret >;`
  binds a producer: invoking `foo` against any continuation `k` fires
  the cut `< (+ x y) | k >`.
- `defco %iterate[s](...) : List = < ... | s >` binds a consumer/
  continuation.

Top-level `def` is sugar for `μ %top. < λ(x,y). ... | %main >`
immediately cut against the entry continuation (see §6).

---

## 3. Types

Types are stratified into positive/negative and structural. Grammar:

```
<typ> ::= <qconid>                          // nominal type
       |  <typ> <tyargs>                    // type application (juxtaposition)
       |  <typ> '->' <typ>                  // function type (positive -> negative)
       |  '(' <typ> (',' <typ>)* ')'        // tuple/product type (positive)
       |  '{' <rfield> (',' <rfield>)* '}'  // record type (negative/codata)
       |  '[' <typ> ']'                     // array/slice (positive)
       |  '<' <typ> (',' <typ>)+ '>'        // sum type (positive, tagged union)
       |  '!' <typ>                         // unrestricted (bang) modality
       |  '?' <typ>                         // affine modality
       |  '<mult> <typ>                     // general graded modality
       |  '~' <typ>                         // negation / continuation
       |  '|' '{' <effrow> '}'              // effect row
       |  '_'                               // infer
       |  '(' <typ> ')'
<tyargs> ::= '[' <typ> (',' <typ>)* ']'
<rfield> ::= <varid> ':' <typ>
<effrow> ::= (<varid> (',' <varid>)* (',' '...')?)?
<mult> ::= 'unr' | 'lin' | 'aff' | <num>   // unrestricted / linear / affine
```

**Polarity convention** (for later PEAR focusing):
- **Positive types** (values/constructors): `data`, tuples, sums, arrays,
  numeric primitives, `!A`, `?A`.
- **Negative types** (computations/objects): codata, records, `A -> B`
  (functions), reference/pointer types.
- `μα.T` and `ν α.T` (iso-recursive types) are introduced by `data`/
  `codata` declarations where the type appears inside its own
  definition.
- Duality (`§4`): `(A × B)⊥ = A⊥ ⅋ B⊥`, `(A + B)⊥ = A⊥ & B⊥`,
  `(A → B)⊥ = A × B⊥`, `(!A)⊥ = ?A⊥`, `(μα.T)⊥ = να.T⊥`.

---

## 4. Commands, producers, consumers (three-sorted core)

The three syntactic categories are written with three judgements:
- **producers** `p : Γ ⊢ Δ | A`    (often written right of ⊢)
- **consumers** `e : Γ | A ⊢ Δ`    (often written left of ⊣)
- **commands**  `c : Γ ⊢ Δ`        (active cuts, no resulting type)

### 4.1 Cuts (commands)

```
<cmd> ::= '<' <prd> '|' <cns> '>'            // CUT: ⟨p | e⟩
       |  'μ'   <covar> '.' <cmd>            // μ-binder: producer-side activation
       |  'μ̃'   <varid> '.' <cmd>            // μ̃-binder (also `mu~` or `comu`)
       |  'jump' <label> '(' <arglist>? ')'   // labelled jump / multi-cut
       |  <cmd> ';' <cmd>                     // sequencing (let-like)
       |  '{' <cmd> (';' <cmd>)* '}'          // command block
       |  'let' <binder> '=' <prd> 'in' <cmd> // sugar for ⟨p | μ̃x.c⟩
       |  'letrec' <recbinds> 'in' <cmd>
       |  'if' <prd> 'then' <cmd> 'else' <cmd>
       |  'while' <prd> 'do' <cmd>
       |  'match' <prd> '{' <branches> '}'
       |  'handle' <cmd> '{' <hbranches> '}'
       |  'perform' <varid> <prdlist>         // effect operation (sugared μ)
       |  'resume' <prd>                      // delimited control resume
       |  'unsafe' <cmd>
       |  'comptime' <cmd>
       |  'assert' <prd>
       |  'assume' <prd>
       |  'ub!' <string>?
       |  'poison' <typ>
       |  'unreachable'
       |  'ret' <prd>                          // short for `<p | %ret>`
```

### 4.2 Producers (terms/prd)

```
<prd> ::= <varid>                            // variable
       |  <qconid> <tyargs>? <prdlist>?      // constructor application
       |  <num>                              // numeric literal
       |  <char> | <string> | 'true' | 'false' | 'unit' | 'null'
       |  <prd> <binop> <prd>                // infix application
       |  <unop> <prd>
       |  'λ' <binder> '.' <cmd>             // λ(x:T).c  (also `\x -> c`, `fn`)
       |  '(' <prd> ',' <prd> (',' <prd>)* ')' // tuple introduction
       |  '{' <fieldinit> (',' <fieldinit>)* '}' // record introduction
       |  'inl' '[' <typ> ']' <prd>          // left injection
       |  'inr' '[' <typ> ']' <prd>          // right injection
       |  '[' <prd> (',' <prd)* ']'           // array literal
       |  'μ'   <covar> '.' <cmd>            // also a producer! (μa.c)
       |  '(' <prd> ')'

<prdlist>   ::= '(' ( <prd> (',' <prd)* )? ')'
<fieldinit> ::= <varid> '=' <prd>
<binop>     ::= <opid>
<unop>      ::= 'not' | '-' | '!' | '*' | '&' | '~'
<recbinds>  ::= <recbind> ('and' <recbind>)*
<recbind>   ::= <varid> <arglist> (':' <typ>)? '=' <cmd>
```

### 4.3 Consumers (contexts/cns)

```
<cns> ::= <covar>                            // co-variable
       |  <covar> '=' <cmd>                  // label + return command (multi-cut arm)
       |  <prd> '·' <cns>                    // stack / call: p·e
       |  'fst' '·' <cns> | 'snd' '·' <cns>  // product elimination
       |  'proj' '#' <num> '·' <cns>         // n-ary projection (tuple index)
       |  '.' <varid> '·' <cns>              // record field projection
       |  '[' <typ> ']' <cns>                // type ascription consumer
       |  'case' '{' <branches> '}'          // sum elimination
       |  'cocase' '{' <cobranches> '}'      // record/codata observation
       |  'default' '·' <cns>                // default/fallthrough continuation
       |  'μ̃'  <varid> '.' <cmd>             // co-μ is also a consumer!
       |  'subst' '[' <substlist> ']' '·' <cns> // explicit parallel substitution (AxCut)
       |  '[' <cns> ']'                      // bracketed consumer

<branches>  ::= <branch> (';' <branch>)*
<branch>    ::= <pat> '→' <cmd>              // pattern ⇒ command
<cobranches>::= <cobranch> (';' <cobranch)*
<cobranch>  ::= <copat> '→' <cmd>            // copattern ⇒ command

<pat> ::= '_' | <varid> | <qconid> <patlist>
       |  '(' <pat> ',' <pat> (',' <pat>)* ')'
       |  '{' <ppat> (',' <ppat)* '}'
       |  <num> | <char> | <string> | 'true' | 'false'
       |  <pat> '@' <varid>                  // as-pattern
       |  <pat> 'as' <varid>
       |  '-' <pat>                          // negated numeric pattern
<patlist> ::= '(' ( <pat> (',' <pat>)* )? ')'
<ppat>    ::= <varid> '=' <pat>

<copat> ::= '_'
        |  '.' <varid> <cobindlist>           // record destructor copattern
        |  <varid> <cobindlist>               // destructor copattern
<cobindlist> ::= '(' ( <varid> (',' <varid>)* )? ')' <cocont>?
<cocont>  ::= '|' <covar>                     // covariable tail
```

### 4.4 The three key reductions (core equations)

```
⟨ V               | μ̃x.c              ⟩  →_βμ̃  c[V/x]           (call-by-value β)
⟨ μα.c            | E                ⟩  →_βμ   c[E/α]           (μ-reduction / control)
⟨ λx.c  (synonym: (μ̃f.⟨λx.⟨f|ret⟩|μret…⟩)) | V·E ⟩  →_β    c[V/x] cut E (β→)
```

Where:
- `V` ranges over VALUES (post-focussing producers): variables,
  constructors applied to values, literals, `λx.c`, tuples of values,
  `comu {…}` coblocks.
- `E` ranges over evaluation contexts (post-focussing consumers):
  co-variables, `V·E`, `fst·E`, `.l·E`, projections, subst-lists.

Administrative η-rules:
```
μα.⟨p|α⟩   = p      (α not free in p)
μ̃x.⟨x|e⟩   = e      (x not free in e)
```

---

## 5. Control flow, labels, multi-cuts

Classical sequent calculus easily expresses jumps but practical IRs
need multi-argument labels (like SSA blocks or join points). AIR adopts
**multi-cuts** (inspired by Accattoli's LJQ and Sequent Core join points):

```
label %loop(i:i32, acc:i32) { ... }        // defines a label consumer
jump %loop(n-1, acc*n);                    // jumps to it with args
```

Desugaring: a `label %k(xs).c` is a μ̃binder binding `%k` to a consumer
that receives a tuple; `jump %k(ps)` is the cut `< (ps) | %k >`. So
labels are SSA basic blocks "for free", which is why AxCut maps
directly to assembly.

`ret p` is a reserved covariable (`%ret`) that marks the exit
continuation of the enclosing function; `break %l`, `continue %l` are
just `jump %l(...)` sugar.

---

## 6. Sugar (what the pfront emitter may emit, and PEAR accepts)

The emitter is allowed to emit any of the syntactic sugar below; PEAR
desugars them before normalizing to AxCut.

| Surface Pride construct                | AIR sugar for                                                   |
|----------------------------------------|-----------------------------------------------------------------|
| `fn f(x) { body }`                     | `def f(x) = letres { body }` = `⟨ μ̃%ret. (body in <val\|%ret>) \| %top ⟩`  |
| `f(args)`                              | `< f \| args·%ret >`                                            |
| `x + y`                                | `< x \| add·(y·%ret) >`  or infix `x + y`                       |
| `let x = v; rest`                      | `⟨ v \| μ̃x. rest ⟩`                                             |
| `a.b`                                  | `< a \| .b·%ret >`                                              |
| `a[b]`                                 | `< a \| index·(b·%ret) >`                                       |
| `match e { Ci xi -> bi }`               | `< e \| case { Ci xi -> bi; ... } >`                            |
| `if c then t else e`                   | `< c \| case { true -> t; false -> e } >`                       |
| `while cond body`                      | `μ̃%exit. μ%loop.⟨cond \| case{ true ⇒ body;jump%loop(); false⇒⟨unit\|%exit⟩}⟩; jump %loop()` |
| `perform op v`                         | `⟨ (op,v) \| μ̃k.⟨k \| %eff ⟩ ⟩` via eff-row insertion          |
| `handle comp { op x k -> h }`          | `μ%k. ⟨ comp[ ] \| μ̃x. ... ⟩` (compositional, see theory_effcont) |
| `return v`                             | `⟨ v \| %ret ⟩`                                                  |
| `break l` / `continue l`               | `jump %l(...)`                                                   |
| `unsafe { b }`                         | wrapped in `unsafe b`; cuts inside carry unsafe flag             |
| `comptime { b }`                       | wrapped in `comptime b`; PEAR evaluates before lowering         |
| `assert p`, `assume p`                 | cuts against assertion/assumption continuations                 |
| `ub!`, `poison`, `unreachable`         | UB / poison / daimon (⊥) cuts                                    |
| `struct Foo { x: T }`                  | `codata Foo { x(self): T }` (a record is a codata with projections) |
| `enum E { A, B(i32) }`                 | `data E { A; B(i32) }`                                           |
| `&T`, `&mut T`                         | codata `Ref[T] { deref(): T; store(v:T): () }` etc.              |
| `[T; N]` arrays                        | `data Array[T]` (recursive positive)                             |
| `λ(x) expr`                            | `μ̃f.⟨λx.⟨expr\|fst·f⟩\|μret.⟨(snd ret)\| ret ⟩⟩` (one-arg continuation) |
| `defer`                                | `μ̃%oldtop. < cmd ; ⟨unit\|%oldtop⟩ \| %ret >`                   |

---

## 7. Multiplicities (linearity)

Every binder carries a multiplicity:
- `unr` (or `!` on type): may be used any number of times (including zero).
- `lin`: must be used exactly once along every control path.
- `aff`: may be used at most once.

The emitter reads the analysis from `theory_linearity.c3` and annotates
binders. PEAR inserts `SHARE`/`ERASE` (AxCut primitives) where linear
discipline is violated (with a warning unless `--strict-linear`).

---

## 8. Concrete textual form example

For the Pride program:
```
fn fact(n: i32) -> i32 {
    if n <= 1 { return 1; }
    return n * fact(n - 1);
}
```

AIR output (approximate):
```
module fact;

def fact(n : i32) : i32 =
  μ̃ %ret.
  < (<= n 1)
  | case {
      true  → < 1 | %ret >;
      false → < n | mul·( (<fact|(sub n 1)·μ̃r.<r|mul·(n·%ret)>>) · %exit ) >
    }
  >;
```

With let-sugar (recommended for readability; the emitter may choose either):
```
def fact(n : i32) : i32 =
  μ̃ %ret.
  if (<= n 1) then
    ret 1
  else
    let r = < fact | (sub n 1)·μ̃rf. ... wait → simpler:
    let r = fact(n - 1) in
    < (mul n r) | %ret >;
```

---

## 9. File format

- Extension: `.air`
- Encoding: UTF-8
- One file per Pride compilation unit; modules may import from
  other `.air` files (textual inclusion or binary `.abc` later).
- Files start with an optional magic line:
  `;; AIR <version> <module-name>`
  (version is `1.0` for this spec).
- The emitter MUST produce a stable output: running it twice on the
  same PNode produces byte-identical `.air` (important for diff-based
  build systems).

---

## 10. Normative references

1. **Curien, Herbelin** (2000). *The Duality of Computation*. ICFP'00.
2. **Wadler** (2003). *Call-by-Value is Dual to Call-by-Name*. ICFP'03.
3. **Downen, Maurer, Ariola, Peyton Jones** (2016). *Sequent Calculus
   as a Compiler Intermediate Language*. ICFP'16 (Sequent Core).
4. **Munch-Maccagnoni** (2009). *The Duality of Computation under Focus*.
5. **Curien, Munch-Maccagnoni** (2010). *The Duality of Computation under
   Focus* (focalised L).
6. **Schuster, Müller, Ostermann, Brachthäuser** (2025). *Compiling
   Classical Sequent Calculus to Stock Hardware: The Duality of
   Compilation*. OOPSLA'25 (AxCut).
7. **Binder, Tzschentke, Müller, Ostermann** (2024). *Grokking the Sequent
   Calculus (Functional Pearl)* (pedagogical introduction to λ̄μμ̃ as
   compiler IR).
