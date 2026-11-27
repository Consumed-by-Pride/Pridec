#!/usr/bin/env python3
"""Generate the tests/grown/regress corpus.

Each case is a standalone Pride program whose `main` returns 0 exactly when the
pinned behaviour held; the exit status is the whole harness. `run.sh` compiles
every case with pfrontc --emit-c, builds the C with gcc, executes it, and
compares the exit status with the `-- EXIT:` line in the header.

Writing the corpus from one generator keeps the expectations in one place next
to the reasoning, the way tests/pfront/run.sh keeps its EXPECT table.
"""
import os
import sys

OUT = os.path.join(os.path.dirname(__file__), "regress")

# helper snippets reused by many cases -------------------------------

PRINT_I64 = '''
fn print_i64 : i64 -> () ! [IO, Alloc]
  | v ->
      let buf : *u8 = alloc [u8; 24]
      let mut pos : i64 = 0i64
      let mut x : i64 = v
      if x < 0i64
        buf[pos] = 45u8
        pos = pos + 1i64
        x = 0i64 - x
      if x == 0i64
        buf[pos] = 48u8
        pos = pos + 1i64
      else
        let tmp : *u8 = alloc [u8; 21]
        let mut tlen : i64 = 0i64
        while x > 0i64
          tmp[tlen] = (x % 10i64 + 48i64) as u8
          x = x / 10i64
          tlen = tlen + 1i64
        let mut k : i64 = tlen - 1i64
        while k >= 0i64
          buf[pos] = tmp[k]
          pos = pos + 1i64
          k = k - 1i64
        free tmp
      buf[pos] = 10u8
      syscall(1, 1, buf as i64, pos + 1i64)
      free buf
'''

CASES = {}

def case(name, exit_code, body, note=""):
    CASES[name] = (exit_code, note, body)

# ── arithmetic ──────────────────────────────────────────────────────────────

case("01_arith_precedence", 0, '''
fn main : () -> i64
  | () ->
      let mut f : i64 = 0i64
      if 2i64 + 3i64 * 4i64 != 14i64
        f = f + 1i64
      if (2i64 + 3i64) * 4i64 != 20i64
        f = f + 2i64
      if 100i64 / 7i64 != 14i64
        f = f + 4i64
      if 100i64 % 7i64 != 2i64
        f = f + 8i64
      if 0i64 - 7i64 != -7i64
        f = f + 16i64
      if 2i64 * 3i64 + 4i64 * 5i64 != 26i64
        f = f + 32i64
      f
''')

case("02_wrapping_checked", 0, '''
fn main : () -> i64
  | () ->
      let big : i64 = 9223372036854775807i64
      let w = big +% 1i64
      let mut f : i64 = 0i64
      if w != -9223372036854775807i64 - 1i64
        f = f + 1i64
      if big +% 2i64 != -9223372036854775807i64
        f = f + 2i64
      f
''')

case("03_shift_edges", 0, '''
fn main : () -> i64
  | () ->
      let mut f : i64 = 0i64
      if (1i64 << 62i64) != 4611686018427387904i64
        f = f + 1i64
      if (64i64 >> 3i64) != 8i64
        f = f + 2i64
      if (-16i64 >> 2i64) != -4i64
        f = f + 4i64
      if (1i64 << 4i64) | (1i64 << 1i64) != 18i64
        f = f + 8i64
      if (255i64 & 15i64) != 15i64
        f = f + 16i64
      if (240i64 ^ 15i64) != 255i64
        f = f + 32i64
      f
''')

case("04_width_truncation", 0, '''
fn narrow : i64 -> u8
  | v -> v as u8

fn widen : u8 -> i64
  | v -> v as i64

fn main : () -> i64
  | () ->
      let mut f : i64 = 0i64
      if narrow(300i64) != 44u8
        f = f + 1i64
      if widen(200u8) != 200i64
        f = f + 2i64
      if (0i64 - 1i64) as u8 != 255u8
        f = f + 4i64
      let small : i32 = 3000000000i64 as i32
      if small == 70000i32
        f = f + 8i64
      f
''')

case("05_bool_logic", 0, '''
fn boom : () -> bool
  | () -> false

fn main : () -> i64
  | () ->
      let mut f : i64 = 0i64
      if (true && false) != false
        f = f + 1i64
      if (true || false) != true
        f = f + 2i64
      if !(1i64 == 2i64) != true
        f = f + 4i64
      if (1i64 < 2i64 && 2i64 <= 2i64 && 3i64 > 2i64 && 3i64 >= 3i64) != true
        f = f + 8i64
      if (1i64 != 1i64 || 2i64 == 2i64) != true
        f = f + 16i64
      if not false != true
        f = f + 32i64
      f
''')

# ── control flow ────────────────────────────────────────────────────────────

case("06_while_sum", 0, '''
fn main : () -> i64
  | () ->
      let mut s : i64 = 0i64
      let mut i : i64 = 1i64
      while i <= 100i64
        s = s + i
        i = i + 1i64
      let mut f : i64 = 0i64
      if s != 5050i64
        f = f + 1i64
      f
''')

case("07_for_range", 0, '''
fn main : () -> i64
  | () ->
      let mut s : i64 = 0i64
      for i in 0..10
        s = s + i
      if s != 45i64
        s = s + 1000i64
      for i in 0..=10
        s = s + i
      if s != 45i64 + 55i64
        s = s + 10000i64
      let mut t : i64 = 0i64
      for i in 10..0
        t = t + 1i64
      if t != 0i64
        s = s + 100000i64
      s - 100i64
''')

case("08_break_continue", 0, '''
fn main : () -> i64
  | () ->
      let mut s : i64 = 0i64
      let mut i : i64 = 0i64
      while true
        i = i + 1i64
        if i > 100i64
          break
        if i % 2i64 == 0i64
          continue
        s = s + i
      if s != 2500i64
        s = s + 1000000i64
      for j in 0..5
        if j == 2i64
          continue
        s = s + j
      if s != 2508i64
        s = s + 10000000i64
      s - 2500i64 - 8i64
''')

case("09_nested_loops", 0, '''
fn main : () -> i64
  | () ->
      let mut s : i64 = 0i64
      for i in 0..10
        for j in 0..10
          s = s + 1i64
      if s != 100i64
        s = s + 1i64
      let mut k : i64 = 0i64
      while k < 3i64
        let mut m : i64 = 0i64
        while m < 4i64
          s = s + 10i64
          m = m + 1i64
        k = k + 1i64
      if s != 220i64
        s = s + 2i64
      s - 220i64
''')

case("10_recursion_fib", 0, '''
fn fib : i64 -> i64
  | 0 -> 0
  | 1 -> 1
  | n -> fib(n - 1i64) + fib(n - 2i64)

fn main : () -> i64
  | () ->
      let mut f : i64 = 0i64
      if fib(10i64) != 55i64
        f = f + 1i64
      if fib(20i64) != 6765i64
        f = f + 2i64
      f
''')

case("11_mutual_recursion", 0, '''
fn is_even : i64 -> bool
  | 0 -> true
  | n -> is_odd(n - 1i64)

fn is_odd : i64 -> bool
  | 0 -> false
  | n -> is_even(n - 1i64)

fn ack : (i64, i64) -> i64
  | (0, n) -> n + 1i64
  | (m, 0) -> ack(m - 1i64, 1i64)
  | (m, n) -> ack(m - 1i64, ack(m, n - 1i64))

fn main : () -> i64
  | () ->
      let mut f : i64 = 0i64
      if is_even(10i64) != true
        f = f + 1i64
      if is_odd(7i64) != true
        f = f + 2i64
      if ack(2i64, 3i64) != 9i64
        f = f + 4i64
      f
''')

case("12_early_return", 0, '''
fn find : (i64, i64) -> i64
  | (target, cap) ->
      for i in 0..cap
        if i * i >= target
          return i
      -1i64

fn main : () -> i64
  | () ->
      let mut f : i64 = 0i64
      if find(17i64, 10i64) != 5i64
        f = f + 1i64
      if find(0i64, 3i64) != 0i64
        f = f + 2i64
      if find(1000i64, 10i64) != -1i64
        f = f + 4i64
      f
''')

# ── match ───────────────────────────────────────────────────────────────────

case("13_match_dense", 0, '''
fn digit_name : i64 -> i64
  | 0 -> 10i64
  | 1 -> 11i64
  | 2 -> 12i64
  | 3 -> 13i64
  | 4 -> 14i64
  | 5 -> 15i64
  | 6 -> 16i64
  | 7 -> 17i64
  | 8 -> 18i64
  | 9 -> 19i64
  | _ -> -1i64

fn main : () -> i64
  | () ->
      let mut f : i64 = 0i64
      let mut i : i64 = 0i64
      while i < 10i64
        if digit_name(i) != 10i64 + i
          f = f + 1i64
        i = i + 1i64
      if digit_name(42i64) != -1i64
        f = f + 2i64
      f
''')

case("14_match_guard", 0, '''
fn clamp_word : i64 -> i64
  | n if n < 0 -> 0i64
  | n if n > 255i64 -> 255i64
  | n -> n

fn main : () -> i64
  | () ->
      let mut f : i64 = 0i64
      if clamp_word(-5i64) != 0i64
        f = f + 1i64
      if clamp_word(1000i64) != 255i64
        f = f + 2i64
      if clamp_word(100i64) != 100i64
        f = f + 4i64
      f
''')

case("15_match_tuple", 0, '''
fn classify : (i64, i64) -> i64
  | (0, 0) -> 0i64
  | (0, _) -> 1i64
  | (_, 0) -> 2i64
  | (a, b) if a == b -> 3i64
  | _ -> 4i64

fn main : () -> i64
  | () ->
      let mut f : i64 = 0i64
      if classify(0i64, 0i64) != 0i64
        f = f + 1i64
      if classify(0i64, 9i64) != 1i64
        f = f + 2i64
      if classify(9i64, 0i64) != 2i64
        f = f + 4i64
      if classify(7i64, 7i64) != 3i64
        f = f + 8i64
      if classify(2i64, 3i64) != 4i64
        f = f + 16i64
      f
''')

# ── data: arrays, slices, structs ───────────────────────────────────────────

case("16_array_basics", 0, '''
fn sum4 : [i64; 4] -> i64
  | xs ->
      let mut s : i64 = 0i64
      for i in 0..4
        s = s + xs[i]
      s

fn main : () -> i64
  | () ->
      let a : [i64; 4] = [10, 20, 30, 40]
      let b : [i64; 4] = [7; 4]
      let mut f : i64 = 0i64
      if sum4(a) != 100i64
        f = f + 1i64
      if sum4(b) != 28i64
        f = f + 2i64
      let mut c : [i64; 4] = [0, 0, 0, 0]
      c[0] = 5i64
      c[3] = 6i64
      if c[0] + c[3] != 11i64
        f = f + 4i64
      f
''')

case("17_array_by_value", 0, '''
fn make : i64 -> [i64; 8]
  | base ->
      let a : [i64; 8] = [0; 8]
      let mut i : i64 = 0i64
      while i < 8i64
        let mut b : [i64; 8] = a
        b[i] = base + i
        if i == 7i64
          return b
        a
        i = i + 1i64
      a

fn main : () -> i64
  | () ->
      let v = make(100i64)
      let mut f : i64 = 0i64
      if v[7i64] != 107i64
        f = f + 1i64
      f
''')

case("18_slice_views", 0, '''
fn bump : [i64] -> i64
  | xs ->
      xs[0] = xs[0] + 1i64
      xs[0]

fn main : () -> i64
  | () ->
      let mut a : [i64; 6] = [1, 2, 3, 4, 5, 6]
      let mid = a[2..4]
      let mut f : i64 = 0i64
      if mid.len != 2i64
        f = f + 1i64
      if mid[0] != 3i64
        f = f + 2i64
      if bump(a[0..2]) != 2i64
        f = f + 4i64
      if a[0] != 2i64
        f = f + 8i64
      if bump(mid) != 4i64
        f = f + 16i64
      if a[2] != 4i64
        f = f + 32i64
      let all = a[0..6]
      if all.len != 6i64
        f = f + 64i64
      f
''')

case("19_wide_struct", 0, '''
struct Wide
  a : i64
  b : i64
  c : i64
  d : i64
  e : i64
  f : i64
  g : i64
  h : i64
  i : i64
  j : i64
  k : i64
  l : i64

fn widen : (i64, i64) -> Wide
  | (x, y) ->
      let mut w : Wide = Wide { a: x, b: y, c: 0i64, d: 0i64, e: 0i64, f: 0i64, g: 0i64, h: 0i64, i: 0i64, j: 0i64, k: 0i64, l: 0i64 }
      w.c = w.a + w.b
      w.l = w.c * 2i64
      w

fn main : () -> i64
  | () ->
      let w = widen(3i64, 4i64)
      let mut f : i64 = 0i64
      if w.a != 3i64
        f = f + 1i64
      if w.b != 4i64
        f = f + 2i64
      if w.c != 7i64
        f = f + 4i64
      if w.l != 14i64
        f = f + 8i64
      let mut v : Wide = w
      v.a = 100i64
      if w.a != 3i64
        f = f + 16i64
      if v.a != 100i64
        f = f + 32i64
      f
''')

case("20_nested_structs", 0, '''
struct Inner
  x : i64
  y : i64

struct Outer
  tag : i64
  first : Inner
  second : Inner

fn make : (i64, i64) -> Outer
  | (a, b) ->
      let o : Outer = Outer { tag: 1i64, first: Inner { x: a, y: a + 1i64 }, second: Inner { x: b, y: b + 1i64 } }
      o

fn main : () -> i64
  | () ->
      let o = make(10i64, 20i64)
      let mut f : i64 = 0i64
      if o.first.y != 11i64
        f = f + 1i64
      if o.second.x != 20i64
        f = f + 2i64
      let mut q = o
      q.first.x = 77i64
      if o.first.x != 10i64
        f = f + 4i64
      if q.first.x != 77i64
        f = f + 8i64
      f
''')

case("21_array_of_structs", 0, '''
struct Pt
  x : i64
  y : i64

fn main : () -> i64
  | () ->
      let pts : [Pt; 3] = [Pt { x: 1i64, y: 2i64 }, Pt { x: 3i64, y: 4i64 }, Pt { x: 5i64, y: 6i64 }]
      let mut f : i64 = 0i64
      if pts[1].y != 4i64
        f = f + 1i64
      let mut acc : i64 = 0i64
      for p in pts
        acc = acc + p.x + p.y
      if acc != 21i64
        f = f + 2i64
      let mut w = pts[2]
      w.x = 50i64
      if pts[2].x != 5i64
        f = f + 4i64
      f
''')

case("22_struct_array_field", 0, '''
struct Buf
  data : [i64; 4]
  used : i64

fn push : (*Buf, i64) -> ()
  | (b, v) ->
      if b.used < 4i64
        b.data[b.used] = v
        b.used = b.used + 1i64

fn main : () -> i64
  | () ->
      let mut b : Buf = Buf { data: [0, 0, 0, 0], used: 0i64 }
      push(&b, 10i64)
      push(&b, 20i64)
      push(&b, 30i64)
      let mut f : i64 = 0i64
      if b.used != 3i64
        f = f + 1i64
      if b.data[2] != 30i64
        f = f + 2i64
      push(&b, 40i64)
      push(&b, 50i64)
      if b.used != 4i64
        f = f + 4i64
      f
''')

# ── enums ───────────────────────────────────────────────────────────────────

case("23_enum_payloads", 0, '''
enum Shape
  Circle(i64)
  Rect(i64, i64)
  Dot

fn area : Shape -> i64
  | Circle(r) -> 3i64 * r * r
  | Rect(w, h) -> w * h
  | Dot -> 0i64

fn main : () -> i64
  | () ->
      let mut f : i64 = 0i64
      if area(Shape.Circle(2i64)) != 12i64
        f = f + 1i64
      if area(Shape.Rect(3i64, 4i64)) != 12i64
        f = f + 2i64
      if area(Shape.Dot) != 0i64
        f = f + 4i64
      let s = Shape.Rect(10i64, 20i64)
      if area(s) != 200i64
        f = f + 8i64
      f
''')

case("24_enum_in_struct", 0, '''
enum Tok
  Num(i64)
  Plus
  Eof

struct Slot
  t : Tok
  line : i64

fn describe : Slot -> i64
  | s ->
      match s.t
        | Num(v) -> v * 10i64 + s.line
        | Plus -> 100i64 + s.line
        | Eof -> 1000i64 + s.line

fn main : () -> i64
  | () ->
      let a : Slot = Slot { t: Tok.Num(7i64), line: 3i64 }
      let b : Slot = Slot { t: Tok.Plus, line: 4i64 }
      let mut f : i64 = 0i64
      if describe(a) != 73i64
        f = f + 1i64
      if describe(b) != 104i64
        f = f + 2i64
      f
''')

case("25_enum_recursion", 0, '''
enum Tree
  Leaf(i64)
  Node(Tree, Tree)

fn depth : Tree -> i64
  | Leaf(_) -> 1i64
  | Node(l, r) ->
      let dl = depth(l)
      let dr = depth(r)
      if dl > dr
        dl + 1i64
      else
        dr + 1i64

fn total : Tree -> i64
  | Leaf(v) -> v
  | Node(l, r) -> total(l) + total(r)

fn main : () -> i64
  | () ->
      let t : Tree = Tree.Node(Tree.Leaf(1i64), Tree.Node(Tree.Leaf(2i64), Tree.Leaf(3i64)))
      let mut f : i64 = 0i64
      if depth(t) != 3i64
        f = f + 1i64
      if total(t) != 6i64
        f = f + 2i64
      f
''')

# ── tuples ──────────────────────────────────────────────────────────────────

case("26_tuples", 0, '''
fn divmod : (i64, i64) -> (i64, i64)
  | (a, b) -> (a / b, a % b)

fn swap : (i64, i64) -> (i64, i64)
  | (a, b) -> (b, a)

fn main : () -> i64
  | () ->
      let (q, r) = divmod(47i64, 5i64)
      let (x, y) = swap(1i64, 2i64)
      let pair = (7i64, 8i64)
      let mut f : i64 = 0i64
      if q != 9i64
        f = f + 1i64
      if r != 2i64
        f = f + 2i64
      if x != 2i64
        f = f + 4i64
      if pair.0 + pair.1 != 15i64
        f = f + 8i64
      let (p, q) = (3i64, 4i64)
      if p + q != 7i64
        f = f + 16i64
      let mut m : i64 = 3i64
      m = m + 4i64
      if m != 7i64
        f = f + 32i64
      f
''')

# ── closures and function values ────────────────────────────────────────────

case("27_closures", 0, '''
fn make_counter : () -> (fn() -> i64)
  | () ->
      let mut n = 0
      fn () -> i64 {
        n = n + 1i64
        n
      }

fn make_adder : i64 -> (fn(i64) -> i64)
  | k ->
      fn (d: i64) -> i64 { k + d }

fn apply : ((fn(i64) -> i64), i64) -> i64
  | (g, v) -> g(v)

fn compose_test : () -> i64
  | () ->
      let add5 = make_adder(5i64)
      let add10 = make_adder(10i64)
      apply(add5, 1i64) + apply(add10, 2i64) + add5(100i64)

fn main : () -> i64
  | () ->
      let tick = make_counter()
      let a = tick()
      let b = tick()
      let c = tick()
      let mut f : i64 = 0i64
      if a != 1i64 || b != 2i64 || c != 3i64
        f = f + 1i64
      if compose_test() != 118i64
        f = f + 2i64
      f
''')

case("28_fn_struct_field", 0, '''
struct Ops
  name_id : i64
  add : fn(i64, i64) -> i64
  mul : fn(i64, i64) -> i64

fn iadd : (i64, i64) -> i64
  | (a, b) -> a + b

fn imul : (i64, i64) -> i64
  | (a, b) -> a * b

fn run_ops : (*Ops, i64) -> i64
  | (o, v) ->
      let s = o.add(v, v)
      let p = o.mul(v, v)
      s + p

fn main : () -> i64
  | () ->
      let table : Ops = Ops { name_id: 1i64, add: iadd, mul: imul }
      let mut heap : *Ops = alloc [Ops; 1]
      heap[0].name_id = 2i64
      heap[0].add = iadd
      heap[0].mul = imul
      let mut f : i64 = 0i64
      if run_ops(&table, 3i64) != 15i64
        f = f + 1i64
      if run_ops(heap, 5i64) != 35i64
        f = f + 2i64
      free heap
      f
''')

# ── generics and interfaces ─────────────────────────────────────────────────

case("29_generics", 0, '''
fn pick_max<T> : (T, T, T) -> T
  | (a, b, c) ->
      let mut best = a
      if b > best
        best = b
      if c > best
        best = c
      best

fn pair_first<T> : (T, T) -> T
  | (a, _) -> a

fn main : () -> i64
  | () ->
      let mut f : i64 = 0i64
      if pick_max<i64>(3i64, 9i64, 5i64) != 9i64
        f = f + 1i64
      if pair_first<i64>(7i64, 8i64) != 7i64
        f = f + 2i64
      let u8m = pick_max<u8>(7u8, 200u8, 100u8)
      if u8m != 200u8
        f = f + 4i64
      f
''')

case("30_interface_impl", 0, '''
struct Sq
  s : i64

struct Ci
  r : i64

interface Area
  fn area : Self -> i64

impl Area for Sq
  fn area : Self -> i64 | q -> q.s * q.s

impl Area for Ci
  fn area : Self -> i64 | c -> 3i64 * c.r * c.r

fn total_area : (Sq, Ci) -> i64
  | (a, b) -> a.area() + b.area()

fn main : () -> i64
  | () ->
      let sq : Sq = Sq { s: 5i64 }
      let ci : Ci = Ci { r: 2i64 }
      let mut f : i64 = 0i64
      if Area.area(sq) != 25i64
        f = f + 1i64
      if Area.area(ci) != 12i64
        f = f + 2i64
      if total_area(sq, ci) != 37i64
        f = f + 4i64
      f
''')

# ── globals ─────────────────────────────────────────────────────────────────

case("31_globals", 0, '''
const SCALE : i64 = 1000i64
const TABLE : [i64; 5] = [2, 3, 5, 7, 11]

let mut COUNTER : i64 = 0i64

fn bump : () -> i64
  | () ->
      COUNTER = COUNTER + SCALE
      COUNTER

fn main : () -> i64
  | () ->
      let mut f : i64 = 0i64
      if bump() != 1000i64
        f = f + 1i64
      if bump() != 2000i64
        f = f + 2i64
      let mut t : i64 = 0i64
      for v in TABLE
        t = t + v
      if t != 28i64
        f = f + 4i64
      f
''')

# ── heap ────────────────────────────────────────────────────────────────────

case("32_heap_vec", 0, '''
struct Vec
  data : *i64
  len : i64
  cap : i64

fn vec_new : () -> Vec
  | () ->
      let v : Vec = Vec { data: alloc [i64; 4], len: 0i64, cap: 4i64 }
      v

fn vec_push : (*Vec, i64) -> ()
  | (v, x) ->
      if v.len >= v.cap
        let bigger : *i64 = alloc [i64; v.cap * 2i64]
        let mut i : i64 = 0i64
        while i < v.len
          bigger[i] = v.data[i]
          i = i + 1i64
        free v.data
        v.data = bigger
        v.cap = v.cap * 2i64
      v.data[v.len] = x
      v.len = v.len + 1i64

fn vec_sum : *Vec -> i64
  | v ->
      let mut s : i64 = 0i64
      let mut i : i64 = 0i64
      while i < v.len
        s = s + v.data[i]
        i = i + 1i64
      s

fn main : () -> i64
  | () ->
      let mut v = vec_new()
      let mut i : i64 = 1i64
      while i <= 20i64
        vec_push(&v, i)
        i = i + 1i64
      let mut s = vec_sum(&v)
      free v.data
      if s != 210i64
        s = 0i64 - 1i64
      s - 210i64
''')

case("33_heap_bytes", 0, '''
fn main : () -> i64
  | () ->
      let buf : *u8 = alloc [u8; 16]
      let mut i : i64 = 0i64
      while i < 16i64
        buf[i] = (i * 3i64) as u8
        i = i + 1i64
      let mut acc : i64 = 0i64
      i = 0i64
      while i < 16i64
        acc = acc + buf[i] as i64
        i = i + 1i64
      let mut f : i64 = 0i64
      if buf[15i64] != 45u8
        f = f + 1i64
      free buf
      acc + f
''')

case("34_ptr_swap", 0, '''
fn swap_i64 : (*i64, *i64) -> ()
  | (a, b) ->
      let t = a[0]
      a[0] = b[0]
      b[0] = t

fn main : () -> i64
  | () ->
      let pa : *i64 = alloc [i64; 1]
      let pb : *i64 = alloc [i64; 1]
      pa[0] = 1i64
      pb[0] = 2i64
      swap_i64(pa, pb)
      let mut f : i64 = 0i64
      if pa[0] != 2i64
        f = f + 1i64
      if pb[0] != 1i64
        f = f + 2i64
      let mut s : [i64; 2] = [10, 20]
      swap_i64(&s[0], &s[1])
      if s[0] != 20i64
        f = f + 4i64
      free pa
      free pb
      f
''')

# ── strings and bytes ───────────────────────────────────────────────────────

case("35_string_scan", 0, '''
fn strlen : ptr -> i64
  | p ->
      let b = p as *u8
      let mut n : i64 = 0i64
      while b[n] != 0u8
        n = n + 1i64
      n

fn count_char : (ptr, u8) -> i64
  | (p, want) ->
      let b = p as *u8
      let mut n : i64 = 0i64
      let mut i : i64 = 0i64
      while b[i] != 0u8
        if b[i] == want
          n = n + 1i64
        i = i + 1i64
      n

fn main : () -> i64
  | () ->
      let s = "hello, pride world"
      let mut f : i64 = 0i64
      if strlen(s) != 18i64
        f = f + 1i64
      if count_char(s, 'l') != 3i64
        f = f + 2i64
      if count_char(s, 'z') != 0i64
        f = f + 4i64
      let esc = "a\\tb\\nc"
      if strlen(esc) != 5i64
        f = f + 8i64
      f
''')

# ── clause dispatch and polymorphic constants ───────────────────────────────

case("36_literal_adapt", 0, '''
fn add32 : (i32, i32) -> i32
  | (a, b) -> a + b

fn add8 : (u8, u8) -> u8
  | (a, b) -> a + b

fn base : i64 -> i64
  | n -> n + 3

fn main : () -> i64
  | () ->
      let mut f : i64 = 0i64
      if add32(2i32, 3i32) != 5i32
        f = f + 1i64
      if add8(200u8, 55u8) != 255u8
        f = f + 2i64
      if base(4i64) != 7i64
        f = f + 4i64
      f
''')

case("37_clauses_multi", 0, '''
fn cmp3 : (i64, i64) -> i64
  | (a, b) if a < b -> -1i64
  | (a, b) if a > b -> 1i64
  | _ -> 0i64

fn apply_op : (i64, i64, i64) -> i64
  | (1i64, a, b) -> a + b
  | (2i64, a, b) -> a - b
  | (3i64, a, b) -> a * b
  | (_, a, b) if b != 0i64 -> a / b
  | _ -> 0i64

fn main : () -> i64
  | () ->
      let mut f : i64 = 0i64
      if cmp3(1i64, 2i64) != -1i64
        f = f + 1i64
      if cmp3(2i64, 2i64) != 0i64
        f = f + 2i64
      if apply_op(1i64, 6i64, 7i64) != 13i64
        f = f + 4i64
      if apply_op(3i64, 6i64, 7i64) != 42i64
        f = f + 8i64
      if apply_op(9i64, 8i64, 0i64) != 0i64
        f = f + 16i64
      f
''')

# ── bigger integration ──────────────────────────────────────────────────────

case("38_sort_ints", 0, '''
fn sort4 : (*i64) -> ()
  | p ->
      let mut i : i64 = 0i64
      while i < 4i64
        let mut j : i64 = 0i64
        while j < 3i64 - i
          if p[j] > p[j + 1i64]
            let t = p[j]
            p[j] = p[j + 1i64]
            p[j + 1i64] = t
          j = j + 1i64
        i = i + 1i64

fn main : () -> i64
  | () ->
      let a : *i64 = alloc [i64; 4]
      a[0] = 42i64
      a[1] = 7i64
      a[2] = 19i64
      a[3] = 3i64
      sort4(a)
      let mut f : i64 = 0i64
      if a[0] != 3i64
        f = f + 1i64
      if a[1] != 7i64
        f = f + 2i64
      if a[2] != 19i64
        f = f + 4i64
      if a[3] != 42i64
        f = f + 8i64
      free a
      f
''')

case("39_rpn_eval", 0, '''
enum Step
  Push(i64)
  Op(i64)

fn run : [Step; 7] -> i64
  | prog ->
      let st : *i64 = alloc [i64; 8]
      let mut sp : i64 = 0i64
      let mut bad : i64 = 0i64
      for step in prog
        match step
          | Push(v) ->
              st[sp] = v
              sp = sp + 1i64
          | Op(code) ->
              if sp >= 2i64
                let b = st[sp - 1i64]
                let a = st[sp - 2i64]
                sp = sp - 2i64
                if code == 1i64
                  st[sp] = a + b
                  sp = sp + 1i64
                else if code == 2i64
                  st[sp] = a - b
                  sp = sp + 1i64
                else
                  st[sp] = a * b
                  sp = sp + 1i64
              else
                bad = 1i64
      let mut r = st[0]
      free st
      if bad != 0i64
        r = 0i64 - 1i64
      r

fn main : () -> i64
  | () ->
      let prog : [Step; 7] = [Step.Push(5i64), Step.Push(3i64), Step.Op(1i64), Step.Push(4i64), Step.Op(3i64), Step.Push(2i64), Step.Op(2i64)]
      let mut r = run(prog)
      if r != 24i64
        r = r * 0i64 - 1i64
      24i64 - r
''')

case("40_lcg_stream", 0, '''
const A : i64 = 6364136223846793005i64
const C : i64 = 1442695040888963407i64

struct Rng
  state : i64

fn next : *Rng -> i64
  | r ->
      r.state = r.state *% A +% C
      (r.state >> 33i64) & 0x7FFFFFFFi64

fn main : () -> i64
  | () ->
      let mut r : Rng = Rng { state: 12345i64 }
      let a1 = next(&r)
      let a2 = next(&r)
      let mut sum : i64 = 0i64
      let mut i : i64 = 0i64
      while i < 1000i64
        sum = sum + (next(&r) & 15i64)
        i = i + 1i64
      let mut f : i64 = 0i64
      if a1 == 0i64 && a2 == 0i64
        f = f + 1i64
      if sum <= 0i64 || sum >= 24000i64
        f = f + 2i64
      if a1 == a2
        f = f + 4i64
      f
''')


def main():
    os.makedirs(OUT, exist_ok=True)
    for name, (exit_code, note, body) in sorted(CASES.items()):
        header = "-- EXIT: %d\n" % exit_code
        if note:
            header += "-- %s\n" % note
        header += "-- grown regression corpus: generated by gen_corpus.py\n\n"
        path = os.path.join(OUT, name + ".pie")
        with open(path, "w") as f:
            f.write(header + body.strip() + "\n")
    print("wrote %d cases to %s" % (len(CASES), OUT))
    return 0


if __name__ == "__main__":
    sys.exit(main())
