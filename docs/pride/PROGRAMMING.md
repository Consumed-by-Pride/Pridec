# Pride — Programming Guide

**Read `SYNTAX.md` first.** That book is the grammar and the type rules. This one
is the *practice*: what a program that actually compiles and runs looks like, and
what to write instead when the compiler says no.

This guide is for someone (or some model) writing a **large** Pride program —
thousands of lines — with no working compiler to experiment against. Every rule
here exists because the alternative is refused at a source position, and each rule
comes with the reason, so you can judge when it applies.

Marks are the same as in `SYNTAX.md`: ✅ compiles and runs, ⚠️ works with caveats,
❌ refused.

---

## 0. The one-paragraph summary

Pride is a **monomorphic, i64-everywhere, no-implicit-conversion** language with
Lisp-like clause syntax, C-like types, and an explicitly checked memory model.
Write C in Pride syntax, not Rust in Pride syntax. There are no references, no
growable library types, no exceptions, no pointer arithmetic, and **no pointer
that outlives the function that allocated it**. There are structs, tagged enums,
`match`, arrays, slices, heap allocation, raw syscalls, generics (monomorphised),
and function values.

A 3,000-line program is a realistic target. It will be built out of **flat `i64`
arrays, `i64` indices, and functions that take `(buffer, length)`** — §7 is the
whole standard library you get, so design around it.

---

## 1. What the toolchain does with your file

```
prog.pie  --pfrontc-->  prog.low.air  --pear2c-->  prog.low   (ELF, x86-64 Linux)
```

`pfrontc` parses, resolves, type-checks and lowers to typed AIR; `pear2c` turns
that into machine code and links it. Two consequences shape everything below:

1. **The front end is strict about types; the backend is strict about memory.** A
   program can type-check and still be refused by `pear2c` because of a pointer it
   cannot track — with a source line and a reason.
2. **The backend never guesses.** `memory access with unknown/out-of-bounds/
   misaligned provenance` means it lost the history of that pointer. §5 and §9
   are about never letting it lose history.

Effect rows (`! [IO, Alloc]`) in a signature are optional and this guide omits
them; the front end accepts both. Omit them and there is one less thing to get
right.

---

## 2. Twelve rules that decide whether it compiles

| # | Rule | Why |
|---|---|---|
| 1 | **`i64` for every integer that is not a byte.** | No implicit conversions: `i32 + i64` is an error. One width, no cast noise. |
| 2 | **Initialise every `let`.** | `let x : i64` is refused; there is no uninitialised binding. |
| 3 | **`let mut` before you reassign.** | Assigning to a non-`mut` binding is an error. |
| 4 | **No `&`, no references, no pointer arithmetic.** | There is no address-of operator and no `p + n`. Buffers are indexed. |
| 5 | **Never cast an integer to a pointer, and never cast between pointer types you will dereference.** | The result has no provenance, so every access through it is refused. |
| 6 | **Allocate where you use it.** A pointer returned from a function has no extent; only `alloc` (and `malloc`) results do. | The backend tracks an allocation from the instruction that made it. A call's pointer result is opaque. |
| 7 | **Pass buffers as `*T` plus a separate `i64` length — never return one.** | A pointer parameter is trusted (see §9.4.1 of `SYNTAX.md`); a returned pointer is not. |
| 8 | **No pointer fields in structs, except `str` literals used in the same function.** | A pointer stored in memory is a tracked *cell*; cells populated by one function are not visible to another. |
| 9 | **Size every array up front. Do two passes instead of growing.** | Growing needs a new allocation plus a copy, and the copy needs a returned pointer. |
| 10 | **One file, one module, one `main`.** | `mod`/`use` parse, but a single file removes multi-module linking from the list of things that can fail. |
| 11 | **No effects; no `defer` in loops; no closures in loops.** | Effects need the fiber runtime, `defer` is function-scoped (16 max), closures capturing loop variables are refused by name. |
| 12 | **`free` exactly once, on every path, using the base pointer.** | No interior frees, no double frees. |

If you retain nothing else: **flat `i64` arrays, `i64` indices, `while` loops,
`if`/`else`, `match` on enums, and functions that take `(*T, n)`.**

---

## 3. The prelude — copy this verbatim ✅

No libc wrapper, no `printf`, no allocator beyond `alloc`. This is the runtime.

```
-- ── output ────────────────────────────────────────────────────────────────
-- write(2) straight to stdout: the bytes are already in memory, so there is
-- nothing to format.
fn write_bytes : (*u8, i64) -> ()
  | (buf, n) ->
      if n > 0
        syscall(1, 1, buf as i64, n)

-- ── numbers ───────────────────────────────────────────────────────────────
-- Decimal i64 into `buf` (needs 21 bytes); returns the number of bytes used.
-- Negative values are handled by keeping the sign in a flag: negating the most
-- negative i64 would overflow, so the digits are collected while still signed.
fn fmt_i64 : (*u8, i64) -> i64
  | (buf, n) ->
      let mut x : i64 = n
      let mut neg : i64 = 0
      if x < 0
        neg = 1
      let mut i : i64 = 0
      if x == 0
        buf[0] = 48u8
        i = 1
      else
        let tmp : *u8 = alloc [u8; 24]
        let mut t : i64 = 0
        while x != 0
          let d : i64 = x % 10
          if d < 0
            tmp[t] = (0 - d + 48) as u8
          else
            tmp[t] = (d + 48) as u8
          x = x / 10
          t = t + 1
        if neg == 1
          tmp[t] = 45u8
          t = t + 1
        let mut k : i64 = t - 1
        while k >= 0
          buf[i] = tmp[k]
          i = i + 1
          k = k - 1
        free tmp
      i

fn print_i64 : i64 -> ()
  | n ->
      let buf : *u8 = alloc [u8; 24]
      let len : i64 = fmt_i64(buf, n)
      write_bytes(buf, len)
      free buf

fn print_i64_nl : i64 -> ()
  | n ->
      print_i64(n)
      write_bytes("\n", 1)

-- ── exit ──────────────────────────────────────────────────────────────────
-- exit_group. Typed as returning i64 so it can be the last expression of a
-- function; `return exit_now(1)` is the idiomatic early exit.
fn exit_now : i64 -> i64
  | code -> syscall(231, code)
```

- `syscall(1, 1, buf as i64, n)` is `write(1, buf, n)`, exactly as
  `tests/exec/03_primes_sieve.pie` does it. Casting the pointer to `i64` is fine:
  the integer goes to the kernel and is never dereferenced.
- `alloc` per print is correct but wasteful. In a hot loop, allocate one buffer in
  `main`, pass it down, and format into it (§7.7).
- `write_bytes("\n", 1)`: a string literal is accepted where a pointer is
  expected, and **its length is yours to state** — count the bytes, the compiler
  will not (§10.1).

---

## 4. Integers, casts, comparisons

### 4.1 One width ✅

```
let n : i64 = 0
let mut total : i64 = 0
let byte : u8 = 65u8
let ok : bool = total < n
```

The type is fixed at the binding and never changes. A literal adopts the type it
is assigned to, compared with, or passed as, so `total = total + 1` and
`buf[i] = 48u8` are fine. What is not fine:

```
let a : i32 = 1
let b : i64 = 2
a + b              -- ❌ operands have different types
```

There is no implicit conversion in either direction, including widening. Use
`i64` for everything and `u8` only for bytes.

### 4.2 Casts ✅

```
let x : i64 = 300
let b : u8 = x as u8            -- truncates (44)
let back : i64 = b as i64       -- zero-extends (44); u8 is unsigned
let addr : i64 = buf as i64     -- pointer to integer, for syscall
let c : f64 = 1.5
let i : i64 = c as i64          -- truncates toward zero
```

`char` is the unsigned byte type, `ichar` is signed, `str` decays to `*u8`.
Integer-to-integer and pointer-to-integer casts are free and safe. **An
integer-to-pointer cast is refused at the first dereference**, and a pointer-to-
pointer cast produces a value with no provenance — see rule 5.

### 4.3 Arithmetic ✅

`+ - * / %` on matching types; `<< >>` shifts; `& | ^` bitwise. Division and
remainder truncate toward zero, so `-7 / 2 == -3` and `-7 % 2 == -1` — **a
negative remainder is negative** (this is why `fmt_i64` above writes `0 - d`).

Signed `i64` overflow is undefined in the IR; there is no wrapping operator in
this subset. Keep values in range, or do the arithmetic in `u64` via casts.

### 4.4 Comparisons and logic ✅

```
a == b    a != b    a < b    a <= b    a > b    a >= b
p and q   p or q    !p          -- `&&` / `||` are the same operators
```

`and`/`or` short-circuit. A condition must be `bool`: `if x` with `x : i64` is
refused — write `if x != 0`.

**Signedness decides whether a loop terminates.** Counting down needs `i64`:
`let mut k : i64 = n - 1` with `while k >= 0`. The same loop with `u64` never
ends, because `0 - 1` is a huge positive number.

---

## 5. Memory: the five things you can do

### 5.1 Stack ✅

```
let a : [i64; 4] = [1, 2, 3, 4]
let zeros : [u8; 64] = [0; 64]            -- fill form
let grid : [[i64; 3]; 3] = [[0; 3]; 3]
```

A `let` of an array is stack storage of exactly `N` elements; `N` is a constant.
This is the cheapest memory in the language: index it with a constant or a runtime
`i64` and the backend proves or checks the bound.

### 5.2 Heap ✅

```
let p : *u8 = alloc [u8; n]         -- n bytes, n may be runtime
let q : *i64 = alloc [i64; n]       -- n elements
let r : *Node = alloc Node          -- one object
free p
```

`alloc` is the only allocator. It compiles to `malloc`, so `n` may be a runtime
`i64`. Each `alloc` is one object; `free` takes exactly the base pointer `alloc`
returned.

**`alloc` happens where the pointer is used.** If you `return` that pointer, the
caller's value has no extent and indexing it is refused (rule 6). That is not a
style preference — it is how the model works, and it is why §7 passes lengths and
destination buffers instead of returning arrays.

### 5.3 Index, field, call ✅

```
p[i]              -- load element i
p[i] = v          -- store element i
s.field           -- load field
s.field = v       -- store field
q.field[3].x      -- chain freely; each step is checked
```

### 5.4 Refused ❌

| you wrote | why |
|---|---|
| `p + 1`, `p - 1` | no pointer arithmetic |
| `(addr as *u8)` | an integer is not a tracked pointer |
| `let q = f()` then `q[0]`, where `f` returns `*i64` | a call's pointer result has no extent |
| `s.buf = alloc [...]` then reading `s.buf` elsewhere | pointer cell written in another function is not visible |
| `free p[i]` / `free q` where `q` is interior | `free` needs a live base |
| `p[i][j]` with two runtime indices and no bound | flatten to `p[i * cols + j]` |

On that last row: `grid[i][j]` on a **stack** `[[i64; 3]; 3]` is fine, because
each step has a known bound. On a flat heap buffer, do the arithmetic yourself —
one dynamic index against a known extent, which is checked once and is fast.

### 5.5 Freeing ✅

```
fn work : (i64) -> i64
  | n ->
      let a : *i64 = alloc [i64; n]
      let b : *i64 = alloc [i64; n]
      let r : i64 = compute(a, b, n)
      free a
      free b
      r
```

Free in reverse order of allocation. Never `return` before the frees unless you
repeat them on that path. A leak is invisible to the compiler; a double free and
an interior free are errors.

---

## 6. Control flow you will actually use ✅

```
let mut i : i64 = 0
while i < n
  if a[i] == target
    break
  i = i + 1

for i in 0..n          -- 0 .. n-1
  total = total + a[i]

for i in 0..=n         -- inclusive

if n == 0
  return 0

match res
  | Ok(v) -> v
  | Err(code) -> 0 - code
```

`break`/`continue` work, with and without labels. Bodies are indentation blocks or
`{ }` blocks; pick one style per file. There is no `switch`, no `goto`, no
exceptions, and no `do-while` — a failure is an enum value (§8.2).

---

## 7. Collections you must write yourself

There is no `Vec`, `String` or `HashMap` in the executable subset. This section is
that library. Every recipe is **flat, sized up front, index-based, and returns
lengths instead of pointers**.

### 7.1 The workhorse: a flat array and a length ✅

```
fn fill_i64 : (*i64, i64, i64) -> ()
  | (a, n, v) ->
      let mut i : i64 = 0
      while i < n
        a[i] = v
        i = i + 1

fn sum_i64 : (*i64, i64) -> i64
  | (a, n) ->
      let mut s : i64 = 0
      let mut i : i64 = 0
      while i < n
        s = s + a[i]
        i = i + 1
      s

fn main : () -> i64
  | () ->
      let n : i64 = 1000
      let a : *i64 = alloc [i64; n]
      fill_i64(a, n, 7)
      let s : i64 = sum_i64(a, n)
      free a
      print_i64_nl(s)
      0
```

That is the whole idiom: **allocate here, pass `(ptr, n)` down, free here.**

If you want a "push" without growth, keep `len` and `cap` as two locals and return
the new length:

```
fn push_i64 : (*i64, i64, i64, i64) -> i64    -- (a, len, cap, v) -> new len
  | (a, len, cap, v) ->
      if len >= cap
        len
      else
        a[len] = v
        len + 1
```

### 7.2 Two-pass sizing instead of growth ✅

The pattern that replaces every growable array:

```
fn count_lines : (*u8, i64) -> i64
  | (text, n) ->
      let mut count : i64 = 0
      let mut i : i64 = 0
      while i < n
        if text[i] == 10u8
          count = count + 1
        i = i + 1
      count

fn line_starts : (*u8, i64, *i64, i64) -> i64   -- (text, n, out, outcap) -> lines
  | (text, n, out, outcap) ->
      let mut count : i64 = 0
      if outcap > 0
        out[0] = 0
        count = 1
        let mut i : i64 = 0
        while i < n
          if text[i] == 10u8 and count < outcap
            out[count] = i + 1
            count = count + 1
          i = i + 1
      count

fn main : () -> i64
  | () ->
      let cap : i64 = 1048576
      let buf : *u8 = alloc [u8; cap]
      let n : i64 = syscall(0, 0, buf as i64, cap)
      if n <= 0
        free buf
        return 1
      let lines : i64 = count_lines(buf, n)
      let starts : *i64 = alloc [i64; lines + 1]
      let got : i64 = line_starts(buf, n, starts, lines + 1)
      free starts
      free buf
      got
```

Two passes over a buffer is cheaper than the tracking problems a growable array
creates. **Treat this as the default for every collection: count, allocate, fill.**

### 7.3 Strings: bytes plus a length ✅

You build strings in a buffer you own; you never get one back from a function.

```
fn str_copy : (*u8, *u8, i64) -> i64     -- (dst, src, n) -> n
  | (dst, src, n) ->
      let mut i : i64 = 0
      while i < n
        dst[i] = src[i]
        i = i + 1
      n

fn str_eq : (*u8, *u8, i64) -> bool
  | (a, b, n) ->
      let mut i : i64 = 0
      let mut same : bool = true
      while i < n
        if a[i] != b[i]
          same = false
          break
        i = i + 1
      same

fn str_len : (*u8) -> i64                -- NUL-terminated, for literals
  | s ->
      let mut i : i64 = 0
      while s[i] != 0u8
        i = i + 1
      i
```

`str` (also spelled `Str`) is the type of a string *literal*. Use literals where
a pointer is expected (`write_bytes("hi", 2)`) and do not build on them: reading
`.len` or `.ptr` off a `str` or a slice is a projection the current backend does
not emit, so a runtime string is a `*u8` plus an `i64` that you carry alongside
it.

### 7.4 A hash map over `i64` keys ✅

Open addressing, power-of-two capacity, `-1` as the empty marker (so keys must be
non-negative; if they are not, add a `used : *u8` array instead).

```
fn hash_i64 : (i64, i64) -> i64
  | (k, cap) ->
      let mut h : i64 = k * 2654435761
      h = h ^ (h >> 13)
      h & (cap - 1)                     -- cap is a power of two: mask, not mod

fn map_clear : (*i64, i64) -> ()
  | (keys, cap) ->
      let mut i : i64 = 0
      while i < cap
        keys[i] = 0 - 1
        i = i + 1

-- Returns the slot for `k` (creating it if absent), or -1 when full.
fn map_slot : (*i64, i64, i64) -> i64
  | (keys, cap, k) ->
      let mut i : i64 = hash_i64(k, cap)
      let mut probes : i64 = 0
      let mut found : i64 = 0 - 1
      while probes < cap
        if keys[i] == k
          found = i
          break
        if keys[i] == 0 - 1
          keys[i] = k
          found = i
          break
        i = (i + 1) & (cap - 1)
        probes = probes + 1
      found

fn map_put : (*i64, *i64, i64, i64, i64) -> i64   -- -> slot or -1
  | (keys, vals, cap, k, v) ->
      let s : i64 = map_slot(keys, cap, k)
      if s < 0
        0 - 1
      else
        vals[s] = v
        s

fn map_get : (*i64, *i64, i64, i64) -> i64       -- -> value or -1
  | (keys, vals, cap, k) ->
      let mut i : i64 = hash_i64(k, cap)
      let mut probes : i64 = 0
      let mut out : i64 = 0 - 1
      let mut done : i64 = 0
      while probes < cap and done == 0
        if keys[i] == k
          out = vals[i]
          done = 1
        else if keys[i] == 0 - 1
          done = 1
        else
          i = (i + 1) & (cap - 1)
          probes = probes + 1
      out
```

Caller:

```
      let cap : i64 = 1024
      let keys : *i64 = alloc [i64; cap]
      let vals : *i64 = alloc [i64; cap]
      map_clear(keys, cap)
      map_put(keys, vals, cap, 42, 7)
      let v : i64 = map_get(keys, vals, cap, 42)
      free keys
      free vals
```

Size at `2 * expected`, rounded up to a power of two. Two arrays, two frees. No
deletion: rebuild into fresh arrays and re-insert the live keys.

### 7.5 Bitset, stack, queue, matrix ✅

```
-- bitset: 8 bits per byte. No shifts with a computed count: multiply instead,
-- so both operands of the operation are the same type.
fn bit_mask : (i64) -> u8
  | (k) ->
      let mut m : u8 = 1u8
      let mut j : i64 = 0
      while j < k
        m = m * 2u8
        j = j + 1
      m

fn bit_set : (*u8, i64) -> ()
  | (bits, i) -> bits[i >> 3] = bits[i >> 3] | bit_mask(i & 7)

fn bit_test : (*u8, i64) -> bool
  | (bits, i) -> (bits[i >> 3] & bit_mask(i & 7)) != 0u8

-- stack: an array plus a top index. Push is a store and `top = top + 1`.
-- queue: an array plus head/tail; the ring form, head = (head + 1) % cap,
--        never moves elements and never grows.
-- matrix: row-major flat, m[i * cols + j]. Nested [N][M] only for constants.
```

### 7.6 Sorting and searching ✅

```
fn sort_i64 : (*i64, i64) -> ()
  | (a, n) ->
      let mut i : i64 = 1
      while i < n
        let v : i64 = a[i]
        let mut j : i64 = i - 1
        while j >= 0 and a[j] > v
          a[j + 1] = a[j]
          j = j - 1
        a[j + 1] = v
        i = i + 1

-- In-place quicksort: no allocation, pivot is a value, recursion is on indices.
fn qsort_i64 : (*i64, i64, i64) -> ()
  | (a, lo, hi) ->
      if lo < hi
        let pivot : i64 = a[(lo + hi) / 2]
        let mut i : i64 = lo
        let mut j : i64 = hi
        while i <= j
          while a[i] < pivot
            i = i + 1
          while a[j] > pivot
            j = j - 1
          if i <= j
            let t : i64 = a[i]
            a[i] = a[j]
            a[j] = t
            i = i + 1
            j = j - 1
        qsort_i64(a, lo, j)
        qsort_i64(a, i, hi)

fn bsearch_i64 : (*i64, i64, i64) -> i64      -- -> index or -1
  | (a, n, key) ->
      let mut lo : i64 = 0
      let mut hi : i64 = n - 1
      let mut found : i64 = 0 - 1
      while lo <= hi
        let mid : i64 = lo + (hi - lo) / 2
        if a[mid] == key
          found = mid
          break
        else if a[mid] < key
          lo = mid + 1
        else
          hi = mid - 1
      found
```

`qsort_i64` recurses with the buffer it was handed — allowed, because a pointer
*parameter* is trusted (§9.4.1 of `SYNTAX.md`). That is why the recipes take
`(ptr, n)`: trust flows down the call chain, never up.

### 7.7 Output buffering ⚠️

For anything that prints more than a few hundred values, format into one buffer:

```
fn out_bytes : (*u8, *i64, *u8, i64) -> ()     -- (out, outn, src, n)
  | (out, outn, src, n) ->
      let mut i : i64 = 0
      while i < n
        out[outn] = src[i]
        outn = outn + 1
        i = i + 1

fn out_i64 : (*u8, *i64, i64) -> ()
  | (out, outn, v) ->
      let tmp : *u8 = alloc [u8; 24]
      let len : i64 = fmt_i64(tmp, v)
      out_bytes(out, outn, tmp, len)
      free tmp

fn out_nl : (*u8, *i64) -> ()
  | (out, outn) -> out_bytes(out, outn, "\n", 1)
```

`outn` is `*i64` (a pointer to your local counter) so the helpers can advance it
without returning a pointer. That is the one place a "slot pointer" is worth it,
and it is safe because the slot is a **stack local of the caller**, allocated and
used in the same function.

---

## 8. Data modelling

### 8.1 Structs are values ✅

```
type Pt = struct
  x : i64
  y : i64

let p : Pt = Pt { x: 3, y: 4 }
let q : Pt = p                    -- copies both fields
```

Structs are copied on assignment, argument passing, and return. Fields hold
scalars: `i64`, `u8`, `bool`, `f64`, nested structs, fixed arrays. **No pointer
fields**, with one exception: a `str` field assigned a literal and read in the
same function (`tests/exec/24_str_fields.pie` does exactly that).

Arrays of structs on the heap are fine and cheap:

```
let pts : *Pt = alloc [Pt; n]
let mut i : i64 = 0
while i < n
  pts[i].x = i
  pts[i].y = i * 2
  i = i + 1
```

If a dynamic index into an array of structs is ever refused, the fallback is
parallel arrays (`xs : *i64`, `ys : *i64`): same code shape, no field GEP, always
accepted. Design so that this fallback is a local change — do not let a module
depend on nested field access.

### 8.2 Errors are enums ✅

No exceptions, no `Result` type — declare one:

```
enum Res
  Ok(i64)
  Err(i64)

fn parse_u64 : (*u8, i64) -> Res
  | (s, n) ->
      if n == 0
        Res.Err(1)
      else
        let mut v : i64 = 0
        let mut i : i64 = 0
        let mut bad : i64 = 0
        while i < n
          let c : i64 = s[i] as i64
          if c < 48 or c > 57
            bad = 1
            break
          v = v * 10 + (c - 48)
          i = i + 1
        if bad == 1
          Res.Err(2)
        else
          Res.Ok(v)
```

```
match parse_u64(tok, len)
  | Ok(v) -> use(v)
  | Err(code) -> report(code)
```

**Enum payloads are `i64`.** To carry anything richer, carry an index into an
array.

### 8.3 `match` discipline ✅

- Arms are `| Pattern -> expr`, tried in order; order is not control flow
  (discriminant tests, not fall-through).
- Patterns: `_`, a binding, a literal, `Variant`, `Variant(pat)`, `(p1, p2)`,
  `[p1, p2]` for fixed arrays, and `..` as a rest inside a tuple or array.
- **No range patterns** (`0..=9` is not a pattern) and no guards inside the
  pattern list — put the condition in the arm body.
- `match` used as a value needs a value from every arm; add `| _ ->` when you do
  not want exhaustiveness to be a compile error later.

### 8.4 Generics — use them rarely ⚠️

```
fn max_of<T> : (T, T) -> T
  | (a, b) ->
      if a > b
        a
      else
        b
```

Monomorphised at compile time; fine for `i64`. Do **not** build a container
library out of generics: a `Vec<T>` needs a generic struct with a pointer field,
which breaks rules 6 and 8, and generic enums are refused. Write `i64`-specialised
code — it is what the compiler emits anyway.

---

## 9. Functions, recursion, buffers across calls

### 9.1 Recursion ✅

Direct recursion is fine. Use it for trees, quicksort and parsing; do not recurse
once per element of a million-element array, and do not recurse deeper than a few
thousand frames (8 MB stack). Mutual recursion works when both functions are in
the same file.

### 9.2 Passing buffers ✅

```
fn fill_range : (*i64, i64, i64) -> ()      -- (a, n, base)
  | (a, n, base) ->
      let mut i : i64 = 0
      while i < n
        a[i] = base + i
        i = i + 1
```

A pointer parameter is a **trusted base with unknown extent**: `a[i]` for a
runtime `i` is allowed and **not** bounds-checked, because the callee has no
length to check against. The caller promises the buffer and the length; the callee
trusts them. Everything outside that promise stays checked — full list in §9.4.1
of `SYNTAX.md`.

Two consequences:

1. **Keep the length truthful.** The compiler cannot catch an off-by-one inside a
   callee. Write the test (§13).
2. **The trust is one-way.** Inside `fill_range` you cannot `free a` (not a heap
   base), cannot use `a` in an atomic, and cannot dereference a pointer you load
   out of `a[i]` unless the program stored a tracked pointer there.

### 9.3 Returning more than one value ✅

A tuple of scalars is fine:

```
fn minmax : (*i64, i64) -> (i64, i64)
  | (a, n) ->
      let mut lo : i64 = a[0]
      let mut hi : i64 = a[0]
      let mut i : i64 = 1
      while i < n
        if a[i] < lo
          lo = a[i]
        if a[i] > hi
          hi = a[i]
        i = i + 1
      (lo, hi)

let (lo, hi) = minmax(a, n)
```

A tuple containing a **pointer** is a record with a pointer in memory — the same
`call result` problem as rule 6. Return "how many" as an `i64`, pass the
destination buffer in, and let the caller keep the buffer.

### 9.4 Function values ⚠️

```
let f : (i64) -> i64 = double
let y = f(21)
```

A function is a value of its signature as long as nothing is captured. Closures
may capture up to 16 values but are **refused inside loops**, so do not build a
callback-heavy design on them. When you want "a function plus its environment",
pass an `i64` selector and `match`:

```
fn apply_op : (i64, i64, i64) -> i64
  | (op, a, b) ->
      match op
        | 0 -> a + b
        | 1 -> a - b
        | 2 -> a * b
        | _ -> 0
```

### 9.5 `defer` ⚠️

`defer expr` runs at the **end of the function**, not the end of the block, and at
most 16 per function. It is useful in a straight-line function with one exit:

```
fn load : (i64) -> i64
  | n ->
      let buf : *i64 = alloc [i64; n]
      defer print_i64(n)
      sum_i64(buf, n)          -- the buffer is NOT freed by defer: `defer free buf`
```

Do not use it for block-scoped cleanup, and do not put it in a loop expecting one
cleanup per iteration.

---

## 10. Text and parsing

### 10.1 `sizeof`, `alignof`, and literal lengths ✅

```
let w : i64 = sizeof(i64) as i64          -- 8; sizeof returns usz, so cast
let z : [u8; 64] = [0; 64]
let s : i64 = sizeof([u8; 64]) as i64     -- 64
```

`sizeof(T)` returns `usz`, which is **not** `i64` — cast it. `sizeof` and
`alignof` are compile-time constants, so they can size a stack array.

**A literal's length is not a `sizeof`.** `write_bytes("id,name\n", 7)` writes
seven bytes because you counted them; `sizeof` of a string literal measures the
literal object (NUL included), which is not what `write` wants. Count the bytes,
or store the literal in a `[u8; N]` you can `sizeof`. A wrong count is the most
common output bug in this language, and nothing catches it.

### 10.2 Tokenising a buffer ✅

The pattern for every parser here — walk bytes, keep `i`, do not allocate while
scanning:

```
fn skip_ws : (*u8, i64, i64) -> i64
  | (s, n, from) ->
      let mut i : i64 = from
      while i < n and (s[i] == 32u8 or s[i] == 9u8 or s[i] == 10u8 or s[i] == 13u8)
        i = i + 1
      i

fn word_end : (*u8, i64, i64) -> i64
  | (s, n, from) ->
      let mut i : i64 = from
      while i < n and s[i] != 32u8 and s[i] != 9u8 and s[i] != 10u8 and s[i] != 13u8
        i = i + 1
      i
```

### 10.3 Byte classification ✅

```
fn is_digit : (u8) -> bool
  | (c) -> c >= 48u8 and c <= 57u8

fn is_alpha : (u8) -> bool
  | (c) -> (c >= 65u8 and c <= 90u8) or (c >= 97u8 and c <= 122u8)

fn is_space : (u8) -> bool
  | (c) -> c == 32u8 or c == 9u8 or c == 10u8 or c == 13u8

fn digit_val : (u8) -> i64
  | (c) -> c as i64 - 48
```

Write `48u8`, not `48`, when comparing with a byte: the literal adopts the type it
meets, and a mismatch is an error rather than a conversion.

### 10.4 Reading input ✅

```
let cap : i64 = 8388608
let buf : *u8 = alloc [u8; cap]
let n : i64 = syscall(0, 0, buf as i64, cap)      -- read(0, buf, cap)
if n <= 0
  free buf
  return 1
```

One `read` may return less than you asked for. There is no `buf + total`, so a
growing reader copies chunk by chunk:

```
fn read_stdin : (*u8, i64) -> i64        -- (dst, cap) -> bytes read
  | (dst, cap) ->
      let mut total : i64 = 0
      let mut done : i64 = 0
      let chunk : *u8 = alloc [u8; 65536]
      while done == 0
        let got : i64 = syscall(0, 0, chunk as i64, 65536)
        if got <= 0
          done = 1
        else
          let mut i : i64 = 0
          while i < got and total < cap
            dst[total] = chunk[i]
            total = total + 1
            i = i + 1
          if total >= cap
            done = 1
      free chunk
      total
```

For a file, `syscall(2, path, 0, 0)` opens it, `syscall(5, fd, statbuf)` fills a
stat struct you allocate, and the size is at a fixed offset — but reading stdin
into a generous buffer is simpler and is what most programs need.

---

## 11. Program architecture for a few thousand lines

The split below keeps every layer in the flat, checked shapes of §7.

| layer | contents | rule |
|---|---|---|
| 1. prelude | §3 verbatim | one allocation per print at most |
| 2. input | `read_stdin`, `count_*`, `scan_*` | one buffer, `(ptr, n)` everywhere |
| 3. model | flat `*i64`/`*u8` arrays + counts | index-based, no pointers in records |
| 4. algorithms | sort/search/hash from §7 | take `(ptr, n)`, return `i64` |
| 5. output | one `out : *u8` and `outn : i64` | format into memory, one `write` at the end |
| 6. `main` | allocate, call in order, free, return a code | every `free` reachable from every exit |

Two habits that save hours:

- **One output buffer** (§7.7). Faster, and it removes interleaving bugs.
- **A phase result made of scalars.** Five counts are five `i64`s in a struct of
  scalars, or five slots in a `*i64` array — never a struct with a pointer.

### 11.1 File layout

```
-- prog.pie
--
-- One paragraph: what it reads, what it writes, what the exit codes mean.
--
--   0  success
--   1  bad input
--   2  refused

-- ── prelude ────────────────────────────────────────────────────────────────
-- ── input ──────────────────────────────────────────────────────────────────
-- ── model ──────────────────────────────────────────────────────────────────
-- ── algorithms ─────────────────────────────────────────────────────────────
-- ── output ─────────────────────────────────────────────────────────────────
-- ── main ───────────────────────────────────────────────────────────────────
```

Exit codes are the interface to whoever runs the program: `0` success, `1` usage,
`2` data error, `3` internal invariant broken. Document them at the top and return
them from `main` (`fn main : () -> i64`).

---

## 12. Sizing and performance

- `i64` arithmetic is one instruction. `/` and `%` by a constant are strength-
  reduced at `-O2`, so do not contort code to avoid them.
- One big buffer beats a thousand small ones: every `alloc` is a `malloc` call,
  and the model tracks each object.
- **Bounds checks are the price of checked indexing**, and they are cheap: one
  compare per access against the object's extent. Index arithmetic of your own
  (`a[i * cols + j]`) is still checked, once.
- Prefer `while` + index to `for x in array` in hot loops: `for` copies each
  element.
- Recursion per tree node is fine; recursion per element of a million-element
  array is not.

---

## 13. Testing without a debugger ✅

There is no debugger and no stack trace, so the program reports its own failure.
Put a `selftest` in the file and call it from `main`:

```
fn check : (i64, i64, i64) -> i64        -- (label, got, want) -> 0 ok, 1 bad
  | (label, got, want) ->
      if got == want
        0
      else
        write_bytes("FAIL ", 5)
        print_i64(label)
        write_bytes(" got ", 5)
        print_i64(got)
        write_bytes(" want ", 6)
        print_i64_nl(want)
        1

fn selftest : () -> i64
  | () ->
      let mut bad : i64 = 0
      let a : *i64 = alloc [i64; 4]
      fill_i64(a, 4, 7)
      bad = bad + check(1, sum_i64(a, 4), 28)
      free a
      bad
```

Report the first failing label and a non-zero exit code — that is the whole
harness. Deterministic output is what makes it usable: never print a pointer or an
uninitialised value.

---

## 14. Build and run

```
# once, in the repo root
make pfrontc pear2c

# per program
./pfrontc prog.pie --emit-air-low          # writes prog.low.air
./pear2/pear2c prog.low.air                # writes prog.low  (ELF executable)
./prog.low; echo "exit=$?"
```

- `pear2c` takes **no `-o`**: the artifact is the input path with the extension
  swapped (`prog.low.air` → `prog.low`).
- `--emit-ll` writes `prog.low.ll` — the thing to read when a program
  misbehaves or a construct needs inspecting.
- `--probe` answers only "does this backend accept the AIR"; it writes nothing and
  needs no LLVM context at run time.
- `-O0` is the debugging pipeline; `-O2` and `-Os` are the shipping ones.
- If `pfrontc` prints `errors=` or no `.low.air` appears, the problem is front-end
  (syntax, types, an unlowered construct): fix it there first.
- If `pear2c` refuses with a source position, it is a memory-model or shape
  refusal: find the line, pick the flat pattern from §5–§9, retry.

---

## 15. Error catalogue — message, cause, fix

| message (abridged) | cause | fix |
|---|---|---|
| `operands have different types` | mixing `i32`/`i64`/`u8` | make both `i64` (`x as i64`) |
| `let without a type or initialiser` | `let x : i64` | initialise: `let x : i64 = 0` |
| assignment to an immutable binding | `let x` then `x = ...` | `let mut x : i64 = ...` |
| `memory access with unknown/out-of-bounds/misaligned provenance` | a pointer the model lost: a call result, an int cast, or a cell written elsewhere | allocate at the point of use; pass buffers as parameters (rules 5–8) |
| `a bulk memory operation exceeds the object` | `memcpy`/`memset` longer than the destination | fix the length |
| `free` refused | interior pointer, double free, or not a heap base | free exactly the base, once |
| `an atomic operation needs a constant address` | `atomic` through a dynamic index | keep atomics on a stable field or global |
| `two dynamic pointer offsets` / `a dynamic pointer offset needs a known object extent` | `p[i][j]` with two runtime indices | flatten: `p[i * cols + j]` |
| `GEP escapes the known object bounds` | constant index past the end of an object | fix the index |
| `for over something that is not a range, an array or a slice` | iterating a struct or a string | `for i in 0..n` |
| closure / capture refused | capturing a loop variable | hoist the closure, or use an `i64` selector |
| non-exhaustive `match` | missing variant | add the arm, or `| _ ->` |
| `unsupported AIR …` | a construct the backend has not built yet | rewrite with the §7 shapes and report it |

---

## 16. A complete worked example ✅

Reads stdin, counts words and distinct leading bytes, prints the first three
leading bytes, and exits with `distinct % 256`. It exercises the prelude, two-pass
sizing, sorting, deduplication, and buffer output — and it contains no construct
outside §3–§10.

```
-- wc.pie -- count words on stdin; print up to three distinct first bytes.
--
--   0  success
--   1  bad input

-- ── prelude ────────────────────────────────────────────────────────────────
fn write_bytes : (*u8, i64) -> ()
  | (buf, n) ->
      if n > 0
        syscall(1, 1, buf as i64, n)

fn fmt_i64 : (*u8, i64) -> i64
  | (buf, n) ->
      let mut x : i64 = n
      let mut neg : i64 = 0
      if x < 0
        neg = 1
      let mut i : i64 = 0
      if x == 0
        buf[0] = 48u8
        i = 1
      else
        let tmp : *u8 = alloc [u8; 24]
        let mut t : i64 = 0
        while x != 0
          let d : i64 = x % 10
          if d < 0
            tmp[t] = (0 - d + 48) as u8
          else
            tmp[t] = (d + 48) as u8
          x = x / 10
          t = t + 1
        if neg == 1
          tmp[t] = 45u8
          t = t + 1
        let mut k : i64 = t - 1
        while k >= 0
          buf[i] = tmp[k]
          i = i + 1
          k = k - 1
        free tmp
      i

fn print_i64 : i64 -> ()
  | n ->
      let b : *u8 = alloc [u8; 24]
      let len : i64 = fmt_i64(b, n)
      write_bytes(b, len)
      free b

fn print_i64_nl : i64 -> ()
  | n ->
      print_i64(n)
      write_bytes("\n", 1)

-- ── scanning ───────────────────────────────────────────────────────────────
fn is_space : (u8) -> bool
  | (c) -> c == 32u8 or c == 9u8 or c == 10u8 or c == 13u8

fn count_words : (*u8, i64) -> i64
  | (s, n) ->
      let mut count : i64 = 0
      let mut in_word : i64 = 0
      let mut i : i64 = 0
      while i < n
        if is_space(s[i])
          in_word = 0
        else
          if in_word == 0
            count = count + 1
          in_word = 1
        i = i + 1
      count

-- First byte of each word, in order; at most `outcap` of them.
fn first_bytes : (*u8, i64, *i64, i64) -> i64
  | (s, n, out, outcap) ->
      let mut distinct : i64 = 0
      let mut in_word : i64 = 0
      let mut i : i64 = 0
      while i < n
        if is_space(s[i])
          in_word = 0
        else
          if in_word == 0 and distinct < outcap
            out[distinct] = s[i] as i64
            distinct = distinct + 1
          in_word = 1
        i = i + 1
      distinct

-- ── algorithms ─────────────────────────────────────────────────────────────
fn sort_i64 : (*i64, i64) -> ()
  | (a, n) ->
      let mut i : i64 = 1
      while i < n
        let v : i64 = a[i]
        let mut j : i64 = i - 1
        while j >= 0 and a[j] > v
          a[j + 1] = a[j]
          j = j - 1
        a[j + 1] = v
        i = i + 1

fn dedup_i64 : (*i64, i64) -> i64          -- -> new length
  | (a, n) ->
      if n == 0
        0
      else
        let mut w : i64 = 1
        let mut i : i64 = 1
        while i < n
          if a[i] != a[w - 1]
            a[w] = a[i]
            w = w + 1
          i = i + 1
        w

-- ── output ─────────────────────────────────────────────────────────────────
fn put_char : (u8) -> ()
  | (c) ->
      let b : *u8 = alloc [u8; 1]
      b[0] = c
      write_bytes(b, 1)
      free b

-- ── main ───────────────────────────────────────────────────────────────────
fn main : () -> i64
  | () ->
      let cap : i64 = 33554432
      let text : *u8 = alloc [u8; cap]
      let n : i64 = syscall(0, 0, text as i64, cap)
      if n <= 0
        write_bytes("wc: no input\n", 13)
        free text
        return 1
      let words : i64 = count_words(text, n)
      let firsts : *i64 = alloc [i64; words + 1]
      let seen : i64 = first_bytes(text, n, firsts, words)
      sort_i64(firsts, seen)
      let uniq : i64 = dedup_i64(firsts, seen)
      print_i64(words)
      write_bytes(" words, ", 8)
      print_i64(uniq)
      write_bytes(" distinct first bytes: ", 23)
      let mut i : i64 = 0
      while i < uniq and i < 3
        put_char(firsts[i] as u8)
        i = i + 1
      write_bytes("\n", 1)
      let code : i64 = uniq % 256
      free firsts
      free text
      code
```

What to notice: one allocation for input, one for the derived array, every index
`i64`, every buffer freed on every path, no pointer fields, no closures, no
generics, `main` returning the exit code. Nothing here needs the backend to prove
more than "this `alloc` is still alive at this index" — which is exactly what it
is built to do.

---

## 17. Checklist before handing a program over

- [ ] Every integer that is not a byte is `i64`.
- [ ] Every `let` has an initialiser; every reassigned binding is `let mut`.
- [ ] No `&`, no pointer arithmetic, no integer-to-pointer casts.
- [ ] Every buffer is allocated at the point of use and its pointer never
      returned.
- [ ] Every `alloc` has exactly one `free` on every path that reaches it.
- [ ] No struct holds a pointer that crosses a function boundary.
- [ ] Every `match` is exhaustive.
- [ ] No effects, no `defer` in a loop, no closures in a loop.
- [ ] Every function that takes a buffer also takes its length, and every caller
      passes a truthful length.
- [ ] `main` returns `i64` and documents its exit codes.
- [ ] A `selftest` exists and runs in well under a second.
- [ ] It is one file, and it builds with the two commands in §14.
