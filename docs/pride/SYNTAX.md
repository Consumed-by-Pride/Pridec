# The Pride Syntax Book

A reference for writing Pride source (`.pie`), derived from the implementation in
this repository — the lexer (`pfront/pfront_lex.c3`), the parser
(`pfront/pfront_parse.c3`), and the programs under `tests/` that are known to
compile and run.

**Read `EXECUTABLE_SUBSET.md` before writing anything meant to run.** This file
describes the *language*; that file describes the *part of the language a program
can currently be built from*. They are not the same, and the difference matters.

Everything here is stated as the implementation behaves. Where a construct is
implemented but not yet reachable through the execution pipeline, it is marked
**[parse-only]**. Where it is reachable, the proving test is named.

---

## Contents

1. [Lexical structure](#1-lexical-structure)
2. [Types](#2-types)
3. [Declarations](#3-declarations)
4. [Statements](#4-statements)
5. [Expressions](#5-expressions)
6. [Operators and precedence](#6-operators-and-precedence)
7. [Patterns and `match`](#7-patterns-and-match)
8. [Builtins](#8-builtins)
9. [Program shape: entry, exit, output](#9-program-shape-entry-exit-output)
10. [Modules](#10-modules)
11. [Grammar summary](#11-grammar-summary)
12. [Keyword list](#12-keyword-list)

---

## 1. Lexical structure

### 1.1 Comments

```pride
-- a line comment
fn main : () -> i64 | () -> 0    -- trailing comment
```

`--` to end of line. There is no block comment. `---` is not special; it is a
line comment whose text starts with `-`.

### 1.2 Layout

Pride is **layout-sensitive**: an indented line begins a block, and dedenting ends
it. Braces are also accepted and behave as in C. Both styles may appear in the
same file — the corpus mixes them freely.

```pride
-- layout style                     -- brace style
fn f : i64 -> i64                    fn f(x: i64) -> i64 {
  | n ->                               return x + 1;
      let m = n + 1                    }
      m
```

Newlines end statements **in layout style only**. Inside braces, `;` separates
statements and newlines are not significant. Do not mix the two conventions
inside one block.

A trailing operator continues an expression onto the next line:

```pride
let ok = a && b ||
         c && d
```

A line that *begins* with `*`, `&`, `-` or `+` at the same indentation as the
statement is a new statement using the prefix form (`*p` deref, `&x` address-of),
not a continuation.

### 1.3 Identifiers

`[A-Za-z_][A-Za-z0-9_]*`. `_` alone is the wildcard and is never a binding. A
leading `_` is an ordinary character (`_unused` is a normal name).

Names may contain `.` when they come from a module (`os.linux.open`); the parser
resolves those against `use` declarations.

### 1.4 Integer literals

```pride
42          0xFF        0xDEAD_BEEF     0b1010_1100     0o755
42i64       7u8         300i32          -1i64
```

Decimal, hex (`0x`), binary (`0b`), octal (`0o`). `_` is allowed between digits.
An optional suffix names the type: `i8 i16 i32 i64 u8 u16 u32 u64 usz isz`.

An **unsuffixed** literal has no type of its own: it takes the type of its first
typed use, and a top-level `let base = 3` is a polymorphic constant that adapts at
each use (`tests/air3/prog/li01_literal_vars.pie`). This is why
`let mut total = 0` followed by `total = total + i` works for any integer width.

### 1.5 Float literals

```pride
3.14     1e10     1.5e-3     0.0     2.5f32
```

Suffixes `f32`, `f64`. No implicit float/integer conversion — use `as`.

### 1.6 String literals

```pride
"hello\n"      "tab\there"      "quote\"inside"      "backslash\\"      "\x41"
```

Escapes: `\n \r \t \\ \" \0` and `\xNN` (hex). A string literal is an array of
bytes; in value position where a pointer is wanted it decays to `*u8`
(`"hi"` used as a `*u8` struct field initialiser, `gl01_const_globals.pie`).
To pass one to `syscall` you cast it: `"text" as i64`.

There is **no length operator on a string literal** that a program can rely on in
the executable subset; carry the byte count yourself (see §9.3).

### 1.7 Character literals

`'a'`, `'\n'`, `'\x41'` — a single byte. The lexer produces a dedicated
character token (`TOKEN_LIT_CHAR`); in arithmetic a character behaves as its byte
value, and `as u8` / `as i64` make the width explicit.

### 1.8 Booleans and null

`true`, `false`, `null` / `nullptr` (both spellings are keywords).

---

## 2. Types

### 2.1 Primitive types

| Category | Types |
|---|---|
| Signed integers | `i8` `i16` `i32` `i64` |
| Unsigned integers | `u8` `u16` `u32` `u64` |
| Target-sized integers | `isz` (signed), `usz` (unsigned) |
| Floats | `f32` `f64` |
| Boolean | `bool` |
| Unit | `()` |
| Raw pointer | `ptr` |
| Byte | `u8` (there is no separate `char` type) |

`usz`/`isz` and the length stored in a slice are as wide as a pointer of the
target (`pw01_target_width.pie`).

### 2.2 Compound types

```pride
*i64                    -- pointer to i64
*u8                     -- byte pointer
**i64                   -- pointer to pointer
ptr                     -- untyped pointer; cast to use
[i64; 8]                -- fixed array of 8
[i64]                   -- slice: { pointer, length }
(i64, bool)             -- tuple
()                      -- unit
fn(i64) -> i64          -- function type
fn(i64, i64) -> i64     -- multi-parameter function type
```

Pointer types are written prefix: `*T`. `ptr` is the untyped/void pointer and is
the type used to store a function address (`f as ptr`) and to erase a concrete
pointer (`&x as ptr`), recovering it with `p as *T`
(`dy01_static_vtable.pie`).

### 2.3 Named types

`struct`, `enum`, and `type Name = …` aliases introduce nominal types. Generic
parameters are declared with `<…>` and bounded with `: Interface`:

```pride
type Six<A, B, C, D, E, F> = struct
  a : A
  f : F

struct Pt
  x : i64
  y : i64

enum Option
  None
  Some(i64)

enum E
  A(i64)
  B
```

`Self` is available inside an `impl` block.

### 2.4 Function types

`fn(A, B) -> C` is a value you can store, pass and call. A function name used
where a `fn(…) -> …` is expected becomes a callable value; `f as ptr` yields its
address as data (`cc01_fn_value.pie`, `fp01_raw_fnptr.pie`).

---

## 3. Declarations

### 3.1 Functions — clause style

The characteristic Pride form. The signature gives parameter and result types;
each `|` introduces a clause whose left side is a **pattern** and whose right side
is the body.

```pride
fn fib : i64 -> i64
  | 0 -> 0
  | 1 -> 1
  | n -> fib(n - 1) + fib(n - 2)
```

* One parameter: written bare (`i64 -> i64`).
* Several parameters: parenthesised, and the clause pattern is a tuple.

```pride
fn pick : (i64, i64) -> i64
  | (a, b) -> a * 10 + b
```

* Guards are allowed on a clause: `| (a, b) if a > b -> a`
  (`tests/lowering/c08_match_guard.pie`).
* Zero-parameter: the type is `() -> R` and the clause is `| () -> …`.
* Clauses may be indented with either two spaces or four; the body is an
  indented block, and its **last expression is the result** (no `return` needed).

### 3.2 Functions — brace style

```pride
fn choose(n: i64) -> i64 {
  if n == 0 { return 10; }
  return 99;
}
```

Parameters are `name: Type`. `return expr;` exits. The result type follows
`->`. This form is common in the older corpus and is fully supported.

### 3.3 Return type, effects

```pride
fn print_i64_nl : i64 -> () ! [IO, Alloc]
```

The `! [Effect, …]` suffix is the effect row. It is *recorded*, not enforced:
`pfront_effectinfer.c3:16` states that "no pass ever rejects code based on
effects", and the row does not change code generation. Writing it is optional and
harmless; the corpus writes `! [IO, Alloc]` on functions that call `syscall` or
`alloc`, and that is worth copying as documentation of intent.

### 3.4 Generic functions and bounds

```pride
fn identity<T> : T -> T
  | x -> x

fn twice<T: Shape> : (T, T) -> i64
  | (a, b) -> a.area() + b.area()

fn pick<A, B, C, D, E, F> : (Six<A, B, C, D, E, F>, A, B, C, D, E, F) -> F
  | (s, a, b, c, d, e, f) -> s.f
```

Up to **8** type parameters (`gn01_six_type_params.pie` proves six). Generic
functions are monomorphised by the lowering pass, so the backend sees concrete
instances.

### 3.5 Structs

```pride
struct Pt
  x : i64
  y : i64

struct Sq { s: i64; }              -- brace form, semicolons inside

struct Box
  f : fn(i64) -> i64
```

Construction uses the type name and field names:

```pride
let p = Pt { x: 3i64, y: 4i64 }
let q = Sq { s: 1 }
```

Field access is `.name`; field assignment is `p.x = 5` for a `mut` binding.
Declaration attributes precede the type: `#packed`, `#align(64)`
(`at02_decl_attrs.pie`).

### 3.6 Enums

```pride
enum E
  A(i64)
  B

enum Option
  None,
  Some(i64),
```

Commas after arms are optional. Construct: `E.A(41)`, `Option.None`.
Destruct: `match` (§7).

### 3.7 Interfaces and impls

```pride
interface Shape
  fn area : Self -> i64
  fn scale : (Self, i64) -> Self

impl Shape for Sq
  fn area : Self -> i64 | q -> q.s * q.s
  fn scale : (Self, i64) -> Self | (q, k) -> Sq { s: q.s * k }
```

Methods are called `v.area()` or, when unambiguous, `area(v)`
(`if02_bare_method_call.pie`). Dispatch is resolved at compile time — an
`impl` is not a runtime dictionary.

### 3.8 Globals

```pride
let ORIGIN : Pt = Pt { x: 3i64, y: 4i64 }     -- immutable global
const N : i64 = 100                            -- compile-time constant
let mut COUNTER : i64 = 0i64                   -- mutable global
static VQ : VT = VT { area: sq_area as ptr }   -- static storage
```

Global initialisers must be constants: literals, struct/tuple/array literals,
and the address of a function (`gl01_const_globals.pie`, `dy01_static_vtable.pie`).

### 3.9 Type aliases

```pride
type Big = struct
  f0 : i64
  f1 : i64

type Six<A, B> = struct
  a : A
  b : B

type Ints = [i64; 8]
```

`type X = struct` followed by indented fields declares a struct under an alias
(`ag01_wide_struct.pie`).

### 3.10 Effects

```pride
effect St
  get : () -> i64
  put : i64 -> i64
```

Performed as `St.get()`, handled with `handle expr` and one arm per operation
(§4.7).

### 3.11 Modules

```pride
mod tests.exec.test_44_hybrid_scoped_effects
use pride.effects
use vec
```

See §10.

---

## 4. Statements

A function body is a sequence of statements. In layout style each is a line; the
value of the last statement is the function's result.

### 4.1 `let`

```pride
let x = 10                       -- immutable binding, type inferred
let y : i64 = 10                 -- with a type annotation
let mut n : i64 = 0              -- mutable
let mut (a, b) = pair            -- tuple destructuring
let (a, b) = pair                -- immutable destructuring
let _ = side_effect()            -- discard
```

A `let` may take an indented block as its initialiser:

```pride
let n =
  let a = 1
  a + 2
```

### 4.2 Assignment

```pride
x = x + 1
p.x = 5                          -- field
a[i] = v                         -- array element
*p = 42                          -- through a pointer
```

Compound assignment: `+=  -=  *=  /=  %=  &=  |=  ^=  <<=  >>=`
(`c02_compound_assign.pie`).

### 4.3 `if`

Statement form:

```pride
if x < 0
  buf[pos] = 45u8
  pos = pos + 1
  x = 0 - x
if x == 0
  buf[pos] = 48u8
else
  ...
```

There is no `elif`; chains are written `else if …`:

```pride
if n < 0 then -1
else if n > 100 then 10000
else n
```

Brace form `if c { … } else { … }` is also accepted.

### 4.4 `while`

```pride
let mut i = 0
while i < n
  s = s + a[i]
  i = i + 1
```

`break` and `continue` work, with an optional label in the loop form.

### 4.5 `for`

```pride
for i in 0..10          -- exclusive range
for i in 0..=10         -- inclusive range
for x in xs             -- over an array or a slice
for x in [100, 7, 5]    -- over an array literal
```

`break` and `continue` are supported inside `for` (`fe01_for_each.pie`).

### 4.6 `do … while`

```pride
do
  i = i + 1
while i < 10
```

Also `do { … }` as a plain block. Post-test loops are parsed and lowered; they
are rare in the corpus, so prefer `while`.

### 4.7 `match`

```pride
match e
  | A(a2) -> a2 + 1
  | B -> 0
```

`match` is an expression. Arms are indented under it; each begins with `|`.
Details in §7.

### 4.8 `handle`

```pride
handle counter(10)
  | St.get u k -> k cell
  | St.put v k ->
      cell = v
      k(v)
```

One arm per operation; `k` is the continuation.

### 4.9 `defer`

```pride
defer free buf
```

Runs at function exit, in reverse order of declaration. **In the executable
subset, `defer` is function-scoped and its interaction with early `return` is
pinned by `tests/lowering/c17_defer.pie` (`-- LOW-EXIT: 1`).** Prefer explicit
`free` at the end of straight-line code.

### 4.10 `return`, `break`, `continue`

`return expr` exits the function; in brace style it takes a terminating `;`.
The last expression of a layout-style block is the result — `return` is optional
there and using it is a matter of style.

### 4.11 Expression statement

Any expression may stand alone as a statement; its value is discarded
(`syscall(231, 0)`).

---

## 5. Expressions

### 5.1 Literals, names, and calls

```pride
42     3.5     "text"    true    null
x      p.x     a[i]      a[lo..hi]
f(a, b)         v.method(arg)      obj.field.method()
```

### 5.2 `if` as an expression

```pride
let y = if x > 2 { 9 } else { 1 }
let c = if CFG.on then PAIR.0 else 0i64
```

`if … then … else …` is the single-line expression form; `if … { } else { }` and
the layout form are also expressions when used in value position.

### 5.3 `match` as an expression

```pride
let v = match o
  | Some(x) -> x
  | None -> 0
```

### 5.4 Blocks as expressions

An indented block in value position evaluates to its last expression.

### 5.5 Closures

```pride
fn (x: i64) -> i64 { x + n }
fn (d: i64) -> i64 { c = c + d; c }
```

A closure captures by value; capturing a `mut` binding gives the closure its own
copy (`cl01_escaping_closure.pie`). Closures may be returned, stored in structs,
and called through function-typed fields.

### 5.6 Struct, tuple, and array literals

```pride
Pt { x: 3i64, y: 4i64 }
(3i64, 4i64)
[1, 2, 3, 4]
[0; 100]              -- 100 zeros
[3i64; 100]
```

`[v; n]` fills an array with `n` copies of `v`.

### 5.7 Indexing and slicing

```pride
a[i]            -- element
a[1..4]         -- slice, half-open
a[2..=3]        -- slice, inclusive
a[0i64..2i64]
b[1..3]         -- a slice of a slice
s.len           -- a slice's length
```

Slicing an array yields a slice `[T]` that views the array; writing through the
sub-slice writes the array (`sl01_subslices.pie`).

### 5.8 Casts

`expr as Type`, binding tighter than any binary operator:

```pride
x as u8         y as i64        p as *Sq        f as ptr        "text" as i64
```

Numeric casts truncate or extend as named: `300 as u8` is `44`
(`c20_cast_widths.pie`). There is **no implicit numeric promotion** — mixing
`i64` and `i32` in one operation is an error, so write the cast.

### 5.9 Builtin forms

`alloc [T; n]`, `free p`, `sizeof(T)`, `static`/`volatile` access, `comptime e`,
`syscall(n, …)`, `atomic_*(…)`, `assert(c)`, `ub`, `unreachable`. See §8.

---

## 6. Operators and precedence

Highest binds tightest (the implementation's table, `infix_prec` in
`pfront/pfront_parse.c3`):

| Level | Operators | Notes |
|---|---|---|
| 14 | `as` | cast |
| 13 | `*` `/` `%` `*?` `*%` `*\|` `@` | `@` is matrix/vector product |
| 12 | `+` `-` `+?` `-?` `+%` `-%` `+\|` `-\|` | |
| 11 | `..` `..=` | range |
| 10 | `<<` `>>` | |
| 9 | `&` | bitwise and |
| 8 | `^` | bitwise xor |
| 7 | `\|` | bitwise or |
| 6 | `<` `<=` `>` `>=` `∈` | comparison |
| 5 | `==` `!=` `≠` | equality |
| 4 | `&&` / `and` | short-circuit |
| 3 | `\|\|` / `or` | short-circuit |
| 2 | `\|>` | pipeline |
| 1 | `++` | rewrite-rule composition |

Prefix (unary) operators bind tighter than all of the above:
`-` `!` `not` `~` `&` (address-of) `*` (deref).

Suffix operations — call `(…)`, index `[…]`, field `.f`, method `.f(…)` — bind
tightest of all and associate left.

Wrapping versus checked arithmetic is spelled in the operator, not by a flag:

```pride
a + b      -- plain (may trap on overflow under the UB model)
a +% b     -- wrapping
a +? b     -- checked
```

`|` is ambiguous inside a clause or `match` arm: a `|` that introduces another
arm wins over bitwise-or when an `->` follows within the lookahead window. Wrap a
genuine bitwise-or in parentheses in that position.

---

## 7. Patterns and `match`

### 7.1 Pattern forms

```pride
_                      -- wildcard
x                      -- binding
0    42    true        -- literal
(a, b)                 -- tuple
[fst, snd]             -- array (fixed arity)
Pt { x, y }            -- struct, fields by name
E.A(v)   A(v)          -- enum constructor with payload
B                      -- nullary constructor
(a, b) if a > b        -- guarded (clauses and match arms)
```

### 7.2 `match`

```pride
match e
  | A(a2) -> a2 + 1
  | B -> 0
```

```pride
match n
  | 0 -> 10
  | 1 -> 21
  | _ -> 99
```

* Arms are `| pattern -> expression` (or an indented block).
* Constructor names may be qualified (`E.A(…)`) or bare (`A(…)`).
* A guard is `| pattern if cond -> …`.
* Matching must be exhaustive: end with a wildcard arm unless every constructor
  is covered.
* Arms are checked in order for literal patterns; constructor patterns are
  compiled to a tag switch.

### 7.3 Destructuring `let`

```pride
let (a, b) = t
let mut (a, b) = (1i64, 2i64)
```

---

## 8. Builtins

These are keywords or recognised calls, not library functions. All are
implemented in the parser/lowering, not the stdlib.

| Form | Meaning |
|---|---|
| `alloc [T; n]` | allocate `n` elements of `T` on the heap; result `*T` |
| `free p` | release an allocation obtained from `alloc` |
| `sizeof(T)` | size in bytes, as `usz` |
| `alignof(T)` | alignment in bytes |
| `offsetof(T, field)` | **[parse-only]** field offset |
| `syscall(n, args…)` | raw Linux syscall; up to 6 integer/pointer args |
| `atomic_load/store/add/sub/and/or/xor/xchg/cmpxchg/min/max/umin/umax/nand(p, …)` | atomics |
| `fence("acquire"\|"release"\|"acq_rel"\|"seq_cst")` | memory fence |
| `volatile *p = v` / `volatile *p` | volatile store / load |
| `comptime e` | evaluate at compile time |
| `assert(c)` | trap if false |
| `assume(c)` | tell the optimiser `c` holds |
| `unreachable` | mark unreachable |
| `ub` | explicit undefined behaviour **[avoid]** |
| `asm("…", …)` | inline assembly |

Atomics and syscalls take an optional memory-order string argument
(`at01_atomics.pie`, `c13_syscall_exit.pie`).

---

## 9. Program shape: entry, exit, output

### 9.1 Entry point

```pride
fn main : () -> i64 | () -> 42
```

The value of `main` becomes the process exit status on the executable pipeline;
`tests/air3/prog/*.pie` are checked exactly this way (`-- EXIT: 42`).

`main` may also return `()`, in which case the program exits through a syscall:

```pride
fn main : () -> () ! [IO]
  | () ->
      syscall(1, 1, "Hello, World!\n" as i64, 14)
      syscall(231, 0)
```

An `i32` return is also accepted (`tests/air3/prog/li01_literal_vars.pie`
returns `i32`); other widths are untested as a `main` result type.

### 9.2 Exit

`syscall(231, code)` is `exit_group` on x86-64 Linux. Returning from `main`
does the same thing.

### 9.3 Output

There is **no `print` builtin**. Output is written with the `write` syscall:

The call is `syscall(number, arg0, arg1, arg2, …)`, so `write(fd, buf, count)`
is `syscall(1, fd, buf, count)`:

```pride
syscall(1, 1, "hello\n" as i64, 6)      -- write(1, buf, 6)
```

The buffer argument is a pointer and `syscall` takes integers, so the cast
`as i64` is required. The corpus idiom, used by most printing programs:

```pride
fn print_i64_nl : i64 -> () ! [IO, Alloc]
  | n ->
      let buf : *u8 = alloc [u8; 25]
      let mut pos : i64 = 0
      let mut x : i64 = n
      if x < 0
        buf[pos] = 45u8
        pos = pos + 1
        x = 0 - x
      if x == 0
        buf[pos] = 48u8
        pos = pos + 1
      else
        let tmp : *u8 = alloc [u8; 21]
        let mut tlen : i64 = 0
        while x > 0
          tmp[tlen] = (x % 10 + 48) as u8
          x = x / 10
          tlen = tlen + 1
        let mut k : i64 = tlen - 1
        while k >= 0
          buf[pos] = tmp[k]
          pos = pos + 1
          k = k - 1
        free tmp
      buf[pos] = 10u8
      syscall(1, 1, buf as i64, pos + 1)
      free buf
```

A string literal is written with its length stated literally:

```pride
syscall(1, 1, "hello\n" as i64, 6)
```

There is no run-time length for a literal, so a helper that prints an arbitrary
string must be given the length by the caller. The simplest container for that is
a slice `[u8]`, which does carry `.len`.

---

## 10. Modules

```pride
mod vec                      -- declares this unit's module path
use vec.raw                  -- brings names in
use pride.effects            -- a builtin module
```

Resolution is by file name (`print_usage` in `pfront/pfront_main.c3`): for
`use a.b.c` the loader tries `<root>/a/b/c.pie`, `<root>/a/b/c/mod.pie`,
`<root>/a/b/c`, and the last-segment form, for each root given with `-I`.

The compiler is invoked on **one** source file; other units are pulled in by
`use`. A single-file program needs no `mod`.

---

## 11. Grammar summary

A compact sketch. `?` = optional, `*` = zero or more, `|` = alternative.
Layout blocks are shown as `INDENT … DEDENT`.

```ebnf
program      = { decl } ;
decl         = fn_decl | struct_decl | enum_decl | interface_decl | impl_decl
             | global_decl | type_alias | effect_decl | use_decl | mod_decl ;

fn_decl      = "fn" ident [ generic ] ":" type "->" type [ effects ]
                 { "|" pattern [ "if" expr ] "->" block }
             | "fn" ident "(" [ params ] ")" "->" type block ;
params       = param { "," param } ;
param        = ident ":" type ;
generic      = "<" ident [ ":" ident ] { "," ident [ ":" ident ] } ">" ;
effects      = "!" "[" ident { "," ident } "]" ;

struct_decl  = [ attrs ] ( "struct" | "type" ident "=" "struct" ) ident [ generic ]
                 ( "{" { field ";" } "}" | INDENT { field } DEDENT ) ;
field        = ident ":" type ;
enum_decl    = "enum" ident INDENT { ident [ "(" type { "," type } ")" ] [ "," ] } DEDENT ;

impl_decl    = "impl" ident "for" type INDENT { fn_decl } DEDENT ;
interface_decl = "interface" ident INDENT { fn_sig } DEDENT ;

global_decl  = ( "let" [ "mut" ] | "const" | "static" [ "mut" ] ) ident
                 [ ":" type ] "=" expr ;

stmt         = let_stmt | assign | if_stmt | while_stmt | for_stmt
             | match_stmt | return_stmt | break_stmt | continue_stmt
             | defer_stmt | handle_stmt | expr_stmt ;
let_stmt     = "let" [ "mut" ] pattern [ ":" type ] "=" ( expr | block ) ;
assign       = expr ( "=" | "+=" | "-=" | "*=" | "/=" | "%=" | "&=" | "|="
                    | "^=" | "<<=" | ">>=" ) expr ;
if_stmt      = "if" expr block [ "else" ( if_stmt | block ) ] ;
while_stmt   = "while" expr block ;
for_stmt     = "for" pattern "in" expr block ;
match_stmt   = "match" expr INDENT { arm } DEDENT ;
arm          = "|" pattern [ "if" expr ] "->" expr ;
defer_stmt   = "defer" expr | "defer" block ;

expr         = unary { infix_op expr } ;
unary        = ( "-" | "!" | "not" | "~" | "&" | "*" ) unary | postfix ;
postfix      = primary { "." ident | "." ident "(" args ")" | "[" expr "]"
                       | "[" expr ".." expr "]" | "(" args ")" } ;
primary      = literal | ident | "(" expr ")" | tuple | array | struct_lit
             | "if" expr "then" expr "else" expr | "match" expr INDENT arms DEDENT
             | "fn" "(" params ")" "->" type "{" body "}"
             | "comptime" expr | builtin ;

pattern      = "_" | ident | literal | tuple_pat | array_pat | struct_pat
             | ident "." ident [ "(" patterns ")" ] ;
```

---

## 12. Keyword list

The lexer recognises 113 keywords (`span_eq` table in `pfront/pfront_lex.c3`).
Those that matter for ordinary programs:

```
as        assert     atomic*      break      comptime   const      continue
defer     do         effect       else       enum       export     extern
false     fence      fn           for        free       handle     if
impl      in         inline       interface  let        match      mod
mut       naked      noinline     null       nullptr    pure       quote
return    self       sizeof       static     struct     syscall    thread_local
transmute trap       true         type       typeof     union      unsafe
unreachable use      volatile     where      while      with       alloc
align     alignof    and          not        or         packed     offsetof
```

Keywords reserved for features outside the executable subset (metaprogramming,
IRDL, tensor algebra) still **cannot be used as identifiers**: `macro`, `quote`,
`splice`, `stage`, `reify`, `pattern`, `pgen`, `rewrite`, `rule`, `dialect`,
`graph`, `hyperedge`, `invariant`, `region`, `freeze`, `generate`, `eval`,
`lower`, `meta`, `node`, `edge`, `opcode`, `constexpr`, `fixpoint`, `tail`,
`with`, `by`, `newtype`, `poison`, `runtime`, `irdl`, `unquote`, `unchecked`.

Avoid all of them as variable or function names.

---

## See also

* `EXECUTABLE_SUBSET.md` — what a program meant to *run* may use.
* `AI_BRIEF.md` — a compact, paste-ready brief built from this file.
* `docs/reference/v.md` — the long-form language design reference (aspirational
  in places; this file is the implementation-grounded one).
* `examples/pride/` — complete programs.
