# Pride Cookbook

Recipes for the things a large program needs, written only in the executable
subset (`EXECUTABLE_SUBSET.md`). Each recipe is a shape, not a library: paste it
into your file and adapt it.

Nothing here has been executed in the workspace it was written in — there is no
LLVM there. Each recipe is composed from constructs that appear in passing tests,
but the *combinations* are not individually tested: treat a recipe as a starting
shape, not as a proven unit. If one does not build, reduce it to the shapes in
`EXECUTABLE_SUBSET.md` §1 and add back one piece at a time.

---

## 1. Printing

### 1.1 Decimal integer

See `docs/pride/AI_BRIEF.md` §8 — copy `print_i64_nl` verbatim. It is the same
function `tests/exec/02_fibonacci.pie` uses.

### 1.2 A literal string

The length is stated by hand because a literal carries no run-time length.
`"hello\n"` is 6 bytes.

```pride
syscall(1, 1, "hello\n" as i64, 6)
```

Keep a comment next to each such call giving the count, or the first edit will
desynchronise it.

### 1.3 A run-time byte buffer

A `[u8]` slice carries its length, so a printer can walk it.

```pride
fn print_slice : ([u8]) -> ()
  | s ->
      let buf : *u8 = alloc [u8; 256]
      let mut pos : i64 = 0
      for c in s
        if pos == 256
          syscall(1, 1, buf as i64, pos)
          pos = 0
        buf[pos] = c
        pos = pos + 1
      if pos > 0
        syscall(1, 1, buf as i64, pos)
      free buf
```

One syscall per byte is correct but slow; the buffered form above is what a
program that prints a lot should use. `for c in s` over a slice and `s[i]` reads
are both exercised by `tests/air3/prog/sl01_subslices.pie`.

### 1.4 Boolean and hex

```pride
fn print_bool : bool -> ()
  | b ->
      if b
        syscall(1, 1, "true\n" as i64, 5)
      else
        syscall(1, 1, "false\n" as i64, 6)

fn print_hex_byte : u8 -> ()
  | v ->
      let digits : *u8 = alloc [u8; 1]
      let hi = (v / 16) as i64
      let lo = (v % 16) as i64
      digits[0] = hex_digit(hi)
      syscall(1, 1, digits as i64, 1)
      digits[0] = hex_digit(lo)
      syscall(1, 1, digits as i64, 1)
      free digits

fn hex_digit : i64 -> u8
  | d ->
      if d < 10 then (48 + d) as u8 else (87 + d) as u8
```

---

## 2. Collections

There is no `Vec`. A growable array is a fixed-capacity array plus a count, or a
heap block that you replace with a bigger one. The second form is the one that
scales, and it is the reason `malloc`-with-a-computed-size and `realloc` were
added to the backend.

### 2.0 Two rules that shape every container

The backend knows where a pointer came from, or it refuses the access. Two
consequences decide every recipe in this section (the reasoning is in
`PROGRAMMING.md` §2 and §5):

* **A pointer is usable where it was allocated.** `alloc` records an extent; a
  pointer *returned* from a function records nothing, so `vec_new() -> Vec` cannot
  hand back a buffer, and a struct returned with a pointer field in it is not
  indexable by the caller.
* **There is no `&x`.** `&` is only the bitwise operator; `&x` parses and does not
  lower. To pass a `*T` to a helper, allocate the object on the heap
  (`let b : *Buf = alloc Buf`), or pass the fields separately.

So: flat buffers, `i64` lengths, `(ptr, n)` arguments, and allocation at the point
of use.

### 2.1 A fixed-capacity buffer, heap-allocated

```pride
type Buf = struct
  data : [i64; 1024]
  len : i64

fn buf_push : (*Buf, i64) -> i64            -- 0 ok, -1 full
  | (b, v) ->
      if b.len >= 1024
        0 - 1
      else
        b.data[b.len] = v
        b.len = b.len + 1
        0

fn buf_get : (*Buf, i64) -> i64
  | (b, i) ->
      if i < 0
        0
      else if i >= b.len
        0
      else
        b.data[i]

fn main : () -> i64
  | () ->
      let b : *Buf = alloc Buf            -- one object; the extent is known here
      b.len = 0
      buf_push(b, 42)
      let v : i64 = buf_get(b, 0)
      free b
      v
```

`alloc Buf` allocates exactly one `Buf`, so `b.len` and `b.data[i]` are field
accesses through a tracked base. **Do not** write `buf_push(&b, 42)`: `&b` does
not lower, and the fixture that appears to use it
(`tests/exec/40_vec_algorithms.pie`) does not get past the lowering either.

The struct-free form is the other option, and it is what the algorithms in §3
take — an array and a length as separate parameters:

```pride
fn arr_push : (*i64, i64, i64, i64) -> i64  -- (a, len, cap, v) -> new len
  | (a, len, cap, v) ->
      if len >= cap
        len
      else
        a[len] = v
        len + 1
```

### 2.2 Growth: size it up front, in two passes

`alloc [T; n]` takes a *runtime* `n`, so there is no need to grow: count first,
allocate once, fill.

```pride
fn count_lines : (*u8, i64) -> i64
  | (text, n) ->
      let mut count : i64 = 0
      let mut i : i64 = 0
      while i < n
        if text[i] == 10u8
          count = count + 1
        i = i + 1
      count

fn line_starts : (*u8, i64, *i64, i64) -> i64
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
```

Growing in place (`realloc`) is modelled by the backend, but this subset has no
source-level declaration for it; a second allocation plus an element-by-element
copy does the same job and is checked the same way. Prefer the two passes.

### 2.3 Arrays of records

```pride
type Item = struct
  key : i64
  val : i64

let items : *Item = alloc [Item; n]         -- n may be a runtime i64
items[3].key = 7
let k : i64 = items[3].key
```

Scalars in the fields, allocated where it is used. If a dynamic index into an
array of records is ever refused, switch to parallel arrays (`keys : *i64`,
`vals : *i64`): same shape, no field GEP, always accepted.

### 2.4 Hash table

Two flat arrays, power-of-two capacity, `-1` for an empty slot (so keys must be
non-negative; add a `used : *u8` array if they are not).

```pride
fn hash_i64 : (i64, i64) -> i64
  | (k, cap) ->
      let mut h : i64 = k * 2654435761
      h = h ^ (h >> 13)
      h & (cap - 1)                         -- cap is a power of two

fn map_slot : (*i64, i64, i64) -> i64       -- slot for k, creating it; -1 if full
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
```

`^` is xor, `&` is and, `>>` is shift — the operator table is `SYNTAX.md` §6.
Caller allocates both arrays, clears `keys` to `-1`, and frees both.

## 3. Algorithms

### 3.1 Sorting (insertion sort, in place)

```pride
fn insertion_sort : (*i64, i64) -> ()
  | (a, n) ->
      let mut i : i64 = 1
      while i < n
        let key = a[i]
        let mut j = i - 1
        let mut done : i64 = 0
        while j >= 0 && done == 0
          if a[j] > key
            a[j + 1] = a[j]
            j = j - 1
          else
            done = 1
        a[j + 1] = key
        i = i + 1
```

### 3.2 Binary search

```pride
fn bsearch : (*i64, i64, i64) -> i64
  | (a, n, key) ->
      let mut lo : i64 = 0
      let mut hi = n - 1
      let mut found : i64 = 0 - 1
      while lo <= hi && found < 0
        let mid = lo + (hi - lo) / 2
        if a[mid] == key
          found = mid
        else if a[mid] < key
          lo = mid + 1
        else
          hi = mid - 1
      found
```

### 3.3 GCD and modular arithmetic

```pride
fn gcd : (i64, i64) -> i64
  | (a, b) ->
      if b == 0 then a else gcd(b, a % b)

fn mod_pow : (i64, i64, i64) -> i64
  | (base, exp, m) ->
      let mut r : i64 = 1
      let mut b = base % m
      let mut e = exp
      while e > 0
        if e % 2 == 1
          r = (r * b) % m
        b = (b * b) % m
        e = e / 2
      r
```

---

## 4. Strings

There is no string type in the executable subset. A string is a `*u8` plus a
count, or a `[u8]` slice.

```pride
fn bytes_equal : ([u8], [u8]) -> bool
  | (a, b) ->
      if a.len != b.len
        false
      else
        let mut i : i64 = 0
        let mut same : i64 = 1
        while i < a.len && same == 1
          if a[i] != b[i]
            same = 0
          i = i + 1
        same == 1
```

Copying into a buffer:

```pride
fn copy_bytes : (*u8, i64, [u8]) -> i64
  | (dst, cap, src) ->
      if src.len > cap
        0 - 1
      else
        let mut i : i64 = 0
        while i < src.len
          dst[i] = src[i]
          i = i + 1
        src.len
```

Comparing a literal:

```pride
"--help" as i64 == arg as i64       -- identity of a pooled literal, not content
```

Do not rely on that: literals are pooled per occurrence, so it compares addresses.
Compare byte by byte instead.

---

## 5. Program structure

### 5.1 Phase reporting

```pride
fn phase : i64 -> ()
  | n ->
      if n == 1
        syscall(1, 1, "[1/3] parse\n" as i64, 12)
      else if n == 2
        syscall(1, 1, "[2/3] build\n" as i64, 12)
      else
        syscall(1, 1, "[3/3] run\n" as i64, 10)
```

A trap in a 5,000-line program with no output is unfixable. Print before every
phase.

### 5.2 Assertions that survive

`assert(cond)` traps. A trap gives you an exit status and no location, so prefer a
checked path that prints where it failed:

```pride
fn check : (bool, i64) -> i64
  | (ok, code) ->
      if ok then 0 else code
```

Then `if check(x > 0, 31) != 0 …` lets `main` return 31, and 31 is a line number
you can find.

### 5.3 Error codes as an enum

```pride
enum Err
  Ok
  Bounds
  Overflow
  Syntax

fn err_code : Err -> i64
  | e ->
      match e
        | Ok -> 0
        | Bounds -> 1
        | Overflow -> 2
        | Syntax -> 3
```

---

## 6. Things that look like they should work but do not

| Attempt | What happens | Use instead |
|---|---|---|
| `let s : str = "x"` | `str` is not on the proven path | `*u8` + length, or `[u8]` |
| `s.len` on a literal | no run-time length | state the count |
| `printf`-style formatting | no such function | print fields separately |
| `Vec::push` from the stdlib | not linked | §2 |
| `free` on a stack array | `free` only takes a heap base from `alloc` | nothing to free |
| `p + 1` pointer arithmetic | pointer arithmetic is not in the proven subset | index: `p[i]` |
| reading argv | no runtime | compile the inputs in, or use `syscall` on fd 0 (untested) |
| `realloc` from source | the backend models it, the *language* has no declaration for it in this subset | §2.2 |
| comparing strings with `==` | compares pointers | §4 |
| `f64` printing | no library | scale to integer, print, insert the point |
