# Brief for an AI writing a Pride program

Paste this whole file into another model as the task preamble. It is
self-contained: it states the language, the subset that actually runs, the
program shape required, and the rules that keep a large program debuggable.

---

## Your task

Write a **Pride** (`.pie`) program. Pride is a statically typed systems language
in the ML/C family: expression-oriented, indentation-sensitive (braces also
allowed), with `struct`/`enum`/`match`, generics, closures, and raw pointers.

Produce **one self-contained file**. It will be compiled by `pfrontc`, lowered to
AIR, and built by an LLVM consumer. It must print its results to stdout using
`syscall` and return an exit status from `main`.

Do not use any library. Do not assume a `print` function exists. Do not use the
standard library.

---

## 1. Minimum viable program

```pride
-- EXIT: 0
fn main : () -> i64
  | () ->
      syscall(1, 1, "hello\n" as i64, 6)
      0
```

* `fn name : PARAMS -> RESULT` followed by `| pattern -> body` clauses.
* No parameters: type is `()`, clause is `| () ->`.
* Layout style: the body is indented; the last expression is the result.
* `main` returning `i64` sets the process exit status.
* `syscall(1, 1, ptr as i64, len)` writes `len` bytes at `ptr` to stdout.
* `syscall(231, code)` exits immediately if you need to.

---

## 2. Types you may use

```
i8 i16 i32 i64      u8 u16 u32 u64      usz isz      f32 f64      bool
()                  *T                  [T; N]       [T]          (A, B)
fn(A) -> B          struct              enum         ptr
```

* `*T` is a pointer; `&x` takes an address; `*p` reads through it.
* `[T; N]` is a fixed array; `[T]` is a slice `{ptr, len}` with `.len`.
* `(A, B)` is a tuple; fields are `.0`, `.1`.
* `ptr` is untyped — cast with `as`.

**No implicit numeric conversion.** `x as i64` is required when widths differ.
Literals may carry a suffix: `1i64`, `48u8`, `0.0f32`.

---

## 3. Statements

```pride
let x = 10                  let mut n : i64 = 0
x = x + 1                   n += 1
p.x = 5                     a[i] = v        *p = 42

if cond                     while i < n                for i in 0..n
  body                        body                       body

match v                     struct Pt                  enum E
  | 0 -> a                    x : i64                    A(i64)
  | _ -> b                    y : i64                    B

return expr                 break                      continue
```

`else if` chains are written inline:

```pride
let c = if n < 0 then -1 else if n > 100 then 10000 else n
```

`match` arms are indented under `match` and start with `|`. End with `| _ ->`
unless every case is covered.

---

## 4. Functions

```pride
fn add : (i64, i64) -> i64
  | (a, b) -> a + b

fn fib : i64 -> i64
  | 0 -> 0
  | 1 -> 1
  | n -> fib(n - 1) + fib(n - 2)

fn pick : (i64, i64) -> i64
  | (a, b) if a > b -> a
  | (a, _) -> 0
```

Multiple clauses dispatch on the pattern in order; guards are `| pat if cond ->`.

Brace style is also legal and may be easier for long bodies:

```pride
fn choose(n: i64) -> i64 {
  if n == 0 { return 10; }
  return 99;
}
```

Do not mix the two conventions inside one function.

---

## 5. The full set of allowed features

Use these, and only these:

* functions, recursion, multi-clause dispatch, guards
* `if`/`else`, `while`, `for i in a..b`, `for x in array_or_slice`, `break`, `continue`
* `match` on integers and on enum constructors
* `let`, `let mut`, assignment, compound assignment
* `struct` with fields; struct literals `Pt { x: 1i64, y: 2i64 }`; field access and assignment
* `enum` with payloads
* fixed arrays, array literals `[1, 2, 3]`, fills `[0; 100]`
* slices and slicing `a[lo..hi]`, `a[lo..=hi]`, `.len`
* pointers, `alloc [T; n]`, `free p`, `&x`, `*p`, `p as *T`, `p as ptr`
* tuples and tuple destructuring
* generics `<T>` and `interface`/`impl` method calls
* closures `fn (x: i64) -> i64 { … }` and function-typed values
* globals: `let NAME : T = literal_or_struct_literal`
* `sizeof(T)`, `alignof(T)`, `syscall`, atomics, `comptime`, `assert`

---

## 6. Forbidden — do not write these

| Do not | Do instead |
|---|---|
| call `print`, `println`, `format!`, `write` | `syscall(1, 1, "text\n" as i64, 6)` |
| `use vec`, `use fmt`, `use str`, any `use` | write the code yourself |
| growable `Vec`/`HashMap`/`String` | fixed arrays sized at compile time, or `alloc` + manual growth |
| `defer` for cleanup | `free` explicitly at the end |
| resuming effect handlers | pass state explicitly |
| tensors, PGL, `quote`/`splice`, `rewrite`, `macro`, IRDL | ordinary functions |
| `ub`, `unreachable` | real code paths |
| threads | single-threaded |
| float printing | print `(x * 1000.0) as i64` and place the decimal yourself |
| string methods, `+` on strings, `.len` on a literal | carry `(ptr, len)` pairs or `[u8]` slices |
| implicit integer widening | `as i64` |
| storing a whole struct into an element (`xs[0] = Item { … }`) | assign fields: `xs[0].key = 1i64` |
| `&x` where a `*T` parameter is expected, without the cast used in the corpus | `&xs[0] as *Item` |

Do not use any keyword as a name. A binder must be a plain identifier, so
`let tail = 0`, `| tail ->` and a parameter called `handle` do not parse. The
words most likely to tempt you are `macro quote splice stage reify pattern pgen
rewrite rule dialect graph region freeze generate eval lower meta node edge
opcode constexpr fixpoint tail with by newtype poison runtime irdl unquote
unchecked` — all reserved. Declaration names and struct field names are more
forgiving than binders (`fn tail` parses), which is exactly why relying on it is a
trap: the name works in one position and fails in the next.

---

## 7. Required program shape

```pride
-- EXIT: 0                       (a comment stating the expected exit status)
-- one line describing what the program does

-- helpers first: output, then data types, then algorithms

fn self_test : () -> i64
  | () ->
      -- return 0 if every internal check passes,
      -- otherwise the number of the first failing check
      0

fn main : () -> i64
  | () ->
      let t = self_test()
      if t != 0
        syscall(1, 1, "self test failed\n" as i64, 17)
        t
      else
        -- real work
        0
```

Every program must have `self_test`. It is the only test harness the language
has: the exit status is checked, and nothing else is.

---

## 8. Output helper — copy this verbatim

There is no print. This is the proven decimal printer:

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

To print a literal string, state its byte length — `"hello\n"` is 6:

```pride
syscall(1, 1, "hello\n" as i64, 6)
```

The `! [IO, Alloc]` suffix is the effect row. It is documentation, never
enforced (`pfront_effectinfer.c3:16`), and it does not change code generation —
write it on helpers that call `syscall` or `alloc`, or leave it off.

To print a `[u8]` slice, print it byte by byte:

```pride
fn print_slice : ([u8]) -> ()
  | s ->
      let mut i : i64 = 0
      while i < s.len
        syscall(1, 1, (&s[i]) as i64, 1)
        i = i + 1
```

If any helper above fails to compile, do not invent syntax. Reduce it to the
simplest shape that compiles — a plain `fn f : i64 -> i64 | n -> n` — and add one
piece at a time. Invented syntax costs more turns than a slow build-up.

---

## 9. Rules that keep a large program debuggable

1. **Annotate every parameter and return type.** Inferred types from unsuffixed
   literals adapt to first use, which is a feature in small code and a trap in
   large code.
2. **Keep functions under ~40 lines.**
3. **Nest at most 3 levels deep.** The layout parser handles continuation, but
   deep nesting is where its edge cases live.
4. **Use at most 4 parameters.** Beyond that, pass a struct.
5. **Print progress.** A trap with no output tells you nothing:
   `syscall(1, 1, "phase 3\n" as i64, 8)` before each phase.
6. **Prefer a fixed array over a pointer.** `[T; N]` carries its own storage;
   `*T` needs `alloc`, a matching `free` on every path, and a size you got right.
   Reach for the pointer only when the data must outlive the frame or is too big
   for the stack.
7. **Bounds-check yourself.** Nothing checks an index. `a[i]` with `i >= len` is
   undefined behaviour, not a trapped error, so write `if i >= 0 && i < n` before
   indexing. The same applies to `.len` on a slice: it is a stored field, not a
   guarantee that the pointer behind it is valid.
8. **One file.** No modules.
9. **Watch frame size before recursing.** Recursion itself is ordinary and
   tested (`fib`), but a function whose locals include a `[i64; 1024]` costs 8 KB
   per frame; a few hundred recursive calls then overflow the stack and the
   program dies with no diagnostic. Iterate when the local state is large.
10. **Declare numbers with the width you mean** (`0i64`, not `0`) in struct
    literals and globals, where context is weakest.

---

## 10. Skeleton to start from

This is the shape that compiles most reliably: layout style, no brace blocks, no
whole-struct stores, tests that accumulate a failure code.

```pride
-- EXIT: 0
-- <what this program does, one line>

struct Item
  key : i64
  val : i64

enum Kind
  Int(i64)
  Add
  End

fn print_i64_nl : i64 -> () ! [IO, Alloc]
  | n ->
      -- paste the helper from section 8 here
      0

fn classify : i64 -> Kind
  | k ->
      if k == 0 then Kind.End
      else if k == 1 then Kind.Add
      else Kind.Int(k)

fn label : Kind -> i64
  | k ->
      match k
        | Int(v) -> v
        | Add -> 1
        | End -> 0

fn score : (*Item, i64) -> i64
  | (xs, n) ->
      let mut s : i64 = 0
      let mut i : i64 = 0
      while i < n
        s = s + xs[i].key * xs[i].val
        i = i + 1
      s

fn build : () -> [Item; 3]
  | () ->
      let mut xs : [Item; 3] = [Item { key: 0i64, val: 0i64 }; 3]
      xs[0].key = 2i64
      xs[0].val = 10i64
      xs[1].key = 3i64
      xs[1].val = 20i64
      xs[2].key = 4i64
      xs[2].val = 30i64
      xs

fn self_test : () -> i64
  | () ->
      let mut fails : i64 = 0
      if label(classify(7)) != 7
        fails = fails + 1
      let xs = build()
      if score(&xs[0] as *Item, 3) != 200
        fails = fails + 1000
      fails

fn main : () -> i64 ! [IO, Alloc]
  | () ->
      let t = self_test()
      let mut rc : i64 = 0
      if t != 0
        syscall(1, 1, "self test failed\n" as i64, 17)
        rc = t
      else
        print_i64_nl(200)
      rc
```

---

## 11. Checklist before returning the program

* [ ] One file, no `use`, no library calls.
* [ ] `fn main : () -> i64` exists and returns an exit status.
* [ ] `self_test` exists and returns 0 when everything passes.
* [ ] Every string printed through `syscall` has an explicit byte length.
* [ ] Every array index is guarded by a bounds check.
* [ ] No `print`, `format`, `Vec`, `String`, `defer`, threads, or `ub`.
* [ ] Every parameter and return type is written out.
* [ ] Every integer literal that lands in a typed context carries a suffix
      (`0i64`, `48u8`).
* [ ] No identifier collides with a reserved word (§6).
* [ ] The file starts with `-- EXIT: 0` and a one-line description.
