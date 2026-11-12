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
      let mut i : i64 = 0
      while i < s.len
        syscall(1, 1, (&s[i]) as i64, 1)
        i = i + 1
```

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

### 2.1 Fixed capacity (simplest)

```pride
struct Buf
  data : [i64; 1024]
  len : i64

fn buf_new : () -> Buf
  | () -> Buf { data: [0; 1024], len: 0 }

fn buf_push : (*Buf, i64) -> i64
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
```

Every access is guarded: `a[i]` out of range is undefined behaviour, not a
trapped error.

`*Buf` is a pointer, so the caller writes `buf_push(&b, 42)`. Taking the address
of a local with `&` is used in `tests/exec/40_vec_algorithms.pie`
(`sort_array(&arr[0] as *i64, 5i64)`); returning the struct by value instead of
passing a pointer is the more heavily exercised direction (`ag02`), and is the
safer choice when a function only reads.

### 2.2 Heap-backed, with a compile-time capacity

```pride
const MAXV : i64 = 4096

struct Vec8
  ptr : *u8
  len : i64

fn vec8_new : () -> Vec8
  | () ->
      let p : *u8 = alloc [u8; 4096]
      Vec8 { ptr: p, len: 0 }

fn vec8_push : (*Vec8, u8) -> i64
  | (v, b) ->
      if v.len >= MAXV
        0 - 1
      else
        v.ptr[v.len] = b
        v.len = v.len + 1
        0

fn vec8_free : (*Vec8) -> ()
  | v ->
      free v.ptr
```

The capacity is a **compile-time** constant: `alloc [T; n]` needs a literal or a
`const`. `MAXV` is `i64` and the buffer is 4096 bytes because the two numbers are
written twice; keep them in step or derive the block from `MAXV` in one place.

Growing past a fixed capacity means allocating a second, larger block, copying,
and freeing the first — the backend models `realloc` and computed heap extents,
but this subset has no source-level declaration for them. Size the largest block
you will ever need.

### 2.3 Linked list

```pride
struct Node
  value : i64
  next : *Node

fn cons : (*Node, i64) -> *Node
  | (tail, v) ->
      let n : *Node = alloc [Node; 1]
      n.value = v
      n.next = tail
      n

fn list_sum : (*Node) -> i64
  | head ->
      let mut s : i64 = 0
      let mut p = head
      while p as i64 != 0
        s = s + p.value
        p = p.next
      s
```

`p as i64 != 0` is the null test. A null pointer is the integer 0; there is no
`Option` at the pointer level.

### 2.4 Hash table

Open addressing over a fixed table. `fnv1a` is a proven shape
(`tests/exec/10_fnv1a.pie`).

```pride
const TSIZE : i64 = 256

struct Entry
  key : i64
  val : i64
  used : bool

struct Table
  slots : [Entry; 256]
  count : i64

fn hash_i64 : i64 -> i64
  | k ->
      let mut h : i64 = 1469598103934665603i64
      let mut x = k
      let mut i : i64 = 0
      while i < 8
        h = (h ^ (x & 255i64)) * 1099511628211i64
        x = x >> 8
        i = i + 1
      h
```

`^` is xor, `&` is and, `>>` is shift — all in the operator table
(`docs/pride/SYNTAX.md` §6). Index with `h % TSIZE` after making it non-negative.

---

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
