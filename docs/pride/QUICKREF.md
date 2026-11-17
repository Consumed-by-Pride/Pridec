# Pride — Quick Reference

One page. Full detail: `SYNTAX.md` (grammar, types, what is refused) and
`PROGRAMMING.md` (how to write a real program). ✅ runs · ⚠️ caveat · ❌ refused.

---

## Shape of a file

```
-- comment          --- doc comment          --[ block
comment, nestable ]--
fn name : (i64, i64) -> i64          -- signature (form A)
  | (a, b) ->                        -- clause: | pattern -> body
      a + b                          -- body is an expression / indented block

fn other(n: i64) -> i64 {            -- form C, C-like
  return n * 2;
}

fn main : () -> i64
  | () -> 0                          -- exit status = returned i64
```

Layout: indentation defines blocks; `{ }` also works; layout is suppressed inside
`( [ {` and `--[ ]--`. One statement per line, or `;` inside braces.

---

## Lexical ✅

| thing | form |
|---|---|
| line comment | `-- ...` to end of line |
| doc comment | `--- ...` |
| block comment | `--[ ... ]--`, nestable — **not** `/* */` |
| identifiers | letters, digits, `_`; not starting with a digit |
| int literal | `42`, `0x2a`, `0b1010`, `0o52`, with `_` separators; suffix `42i64`, `7u8`, `1usz` |
| float literal | `1.5`, `1e9`, `2.5f32` |
| char | `'a'`, `'\n'`, `'\''` |
| string | `"text"`, `"\n\t\\\"\0"`, `"\u{1F600}"` |
| bool | `true`, `false` |
| unit | `()` |
| null | `null` |

Integer literal suffixes: `i8 i16 i32 i64 i128 u8 u16 u32 u64 u128 usz isz`.
**Integers never convert implicitly**: `i32 + i64` is an error. Use `i64`.

---

## Types ✅ / ❌

| type | meaning |
|---|---|
| `i8 i16 i32 i64 i128` | signed integers |
| `u8 u16 u32 u64 u128` | unsigned integers |
| `f32 f64` | floats |
| `bool` | `true` / `false` |
| `char` | unsigned byte (`ichar` signed) |
| `str` / `Str` | string literal type; use a literal where `*u8` is expected, do not read `.len`/`.ptr` at runtime |
| `usz isz` | machine-word sized |
| `()` / `unit` | no value |
| `never` | no return |
| `*T` | pointer (the only pointer type) |
| `[T; N]` | fixed array, `N` constant |
| `(T, U)` | tuple |
| `struct { ... }` | record |
| `enum` | tagged union, payloads are `i64` |
| `fn` signature | function value |

❌ no references (`&T`/`&mut T`), no `u8`/`i8` aliases in C3 terms (`u8` is
`char`-sized here), no generic enums, no interfaces on values at runtime, no
`[T]` unsized array type as a declaration.

---

## Operators, tightest first ✅

| prec | operators |
|---|---|
| 14 | `as` |
| 13 | `* / %` |
| 12 | `+ -` |
| 11 | `.. ..=` |
| 10 | `<< >>` |
| 9 | `&` |
| 8 | `^` |
| 7 | `\|` |
| 6 | `== != < <= > >=` |
| 5 | `and &&` |
| 4 | `or \|\|` |
| 3 | `\|>` |
| 2 | `++` |

Assignment is statement-level (`= += -= *= /= %= &= \|= ^= <<= >>=`), not an
operator. No right-associative operators.

---

## Declarations ✅

```
fn f : (i64, i64) -> i64          | (a, b) -> a + b
fn g<T> : (T, T) -> T             | (a, b) -> a
fn h(n: i64) -> i64 { return n; }              -- C-like
extern fn puts(s: *u8) -> i64                  -- C ABI, no body
extern fn malloc(size: i64) -> *u8

struct Pt
  x : i64
  y : i64

type Pair = struct                 -- same thing, `type` form
  a : i64
  b : i64

enum Option
  None,
  Some(i64)                        -- payload is i64

interface Shape
  fn area : Self -> i64

impl Shape for Sq
  fn area : Self -> i64 | q -> q.s * q.s

import std.io                      -- module import (see SYNTAX.md §11)
```

`#packed`, `#align(N)`, `#export("name")`, `#noinline`, `#inline`, `#naked`,
`#section("x")`, `#used`, `#callconv("fast")` on a declaration.

---

## Statements ✅

```
let x = 3
let y : i64 = 3
let mut z : i64 = 0
let mut (a, b) = (1, 2)            -- destructuring
z = z + 1
z += 1
return z
return
if c { ... } else { ... }
while c { ... }
for i in 0..n { ... }              -- 0..n-1; 0..=n inclusive
for x in array { ... }
loop { ... }
match e { | P -> ... }
break        continue              -- also labelled
defer expr                         -- ⚠️ function-scoped, max 16
unsafe { ... }                     -- ✅ no effect
```

---

## Expressions ✅

```
a + b * c            (a + b) * c        a as u8
p[i]                 p[i] = v           p[i].field
s.field              s.field = v
f(a, b)              v.method(args)
[1, 2, 3]            [0; 16]            (1, 2)
T { x: 1, y: 2 }     if c then a else b
sizeof(T) sizeof(e)  alignof(T)
```

`if` and `match` and `{ ... }` blocks are expressions when every branch produces a
value. `assert c`, `assume c`, `trap`, `unreachable`, `ub!`.

---

## Patterns and `match` ✅

```
match e
  | A(x) -> x
  | B -> 0
  | (p, q) -> 1          -- tuple
  | [a, b] -> 2          -- fixed array
  | [x, ..] -> 3         -- rest
  | 0 -> 4 | _ -> 5      -- literal, wildcard

let (lo, hi) = pair
```
❌ range patterns (`0..=9` in a pattern), guards inside the pattern list. Put the
condition in the arm body. `match` as a value needs a value from every arm.

---

## Memory ✅ / ❌

```
let a : [i64; 4] = [1, 2, 3, 4]     -- stack, N constant
let z : [u8; 64] = [0; 64]          -- zero fill
let p : *i64 = alloc [i64; n]       -- heap, n may be runtime  ✅
let r : *Node = alloc Node          -- one object                ✅
p[i]  p[i] = v      r.field = v
free p                               -- the base pointer, once
```

❌ `&x`, `*p = v` on an untracked pointer, `p + 1`, `(i as *u8)` then deref,
returning a `*T` from a function and indexing it, freeing an interior pointer,
two runtime indices in one GEP on a flat buffer (flatten with `i * cols + j`).

✅ **A pointer parameter is trusted**: `fn f(a: *i64, n: i64)` may index `a[i]`
for any runtime `i`, unchecked, because the caller promised the buffer. That is
the one place the model trusts rather than proves; `free`, atomics and loaded
pointers stay checked.

---

## Builtins ✅

| builtin | form |
|---|---|
| `syscall` | `syscall(n, a, b, ...)` ≤ 6 args → `i64` |
| `write` | `syscall(1, 1, buf as i64, len)` |
| `read` | `syscall(0, 0, buf as i64, cap)` |
| `exit` | `syscall(231, code)` |
| `memcpy` | `extern fn memcpy(dst: *u8, src: *u8, n: i64) -> *u8` |
| `memset` | `extern fn memset(dst: *u8, c: i64, n: i64) -> *u8` |
| `asm` | `asm { "..." : outs : ins : clobbers }` ⚠️ |
| `atomic` | `atomic load/store/cmpxchg` — constant address only ⚠️ |
| `fence` | `fence(acq_rel)` ⚠️ |
| `assert` / `assume` | `assert cond` / `assume cond` |
| `trap` | `trap`, type `never` |
| `sizeof` / `alignof` | compile-time constants, result `usz` (cast to `i64`) |

---

## A complete minimal program ✅

```
fn write_bytes : (*u8, i64) -> ()
  | (buf, n) ->
      if n > 0
        syscall(1, 1, buf as i64, n)

fn main : () -> i64
  | () ->
      write_bytes("hello\n", 6)
      0
```

```
./pfrontc hello.pie --emit-air-low      # hello.low.air
./pear2/pear2c hello.low.air            # hello.low
./hello.low; echo $?                    # hello / 0
```

`pear2c` has **no `-o`**: input `hello.low.air` → output `hello.low`.
`--emit-ll` writes `hello.low.ll`; `--probe` only type-checks the AIR.

---

## Hard limits ✅

≤ 64 function params (63 usable) · ≤ 8 type params · ≤ 32 enum variants · ≤ 8
variant/union fields · ≤ 16 `defer` per function · ≤ 16 closure captures · ≤ 1024
array-literal elements · ≤ 4096 functions, 1024 globals, 8192 blocks/locals ·
≤ 6 syscall args · ≤ 8 asm outputs / 16 inputs.

---

## Top refusals and the fix

| refused | write instead |
|---|---|
| `&x` / `p + 1` / `(i as *u8)` | index a buffer you allocated |
| returning `*T` and indexing it | pass the buffer in, return a length |
| pointer field written by another function | pass `(ptr, n)` as arguments |
| growable array | two passes: count, then allocate and fill |
| `i32` mixed with `i64` | `i64` everywhere |
| `let x : i64` | initialise it |
| `x = ...` on a `let x` | `let mut x` |
| range pattern `0..=9` | `| x -> if ...` |
| `do { } while` | `loop` + `break` |
| closure in a loop | hoist it, or pass an `i64` selector |
| `for x in some_struct` | `for i in 0..n` |
| generic enum / `Vec<T>` library | `i64`-specialised arrays |
| effects with handlers | an enum and `match` |

---

## Checklist

`i64` everywhere · every `let` initialised · `mut` before reassignment · no `&`,
no pointer arithmetic, no int→pointer · allocate at point of use · free every
base once on every path · buffers passed as `(ptr, n)` · no pointer fields ·
`match` exhaustive · `main` returns `i64` · document exit codes · a `selftest`.
