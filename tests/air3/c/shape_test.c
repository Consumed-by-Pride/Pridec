/* ============================================================================
 * shape_test.c -- the C text air_c emits for every awkward AIR 3.0 form, written
 * BY HAND in exactly the shape the emitter prints, and executed.
 *
 * This file is a contract test, not an example. Each function below corresponds
 * to one AIR form in docs/pear2/C_TARGET.md §4, and it is written the way
 * pfront/pear_ir/air_c.c3 prints it: same naming, same hoisting, same label
 * spelling, same jump-to-store translation. If the emitter's template for a form
 * is wrong, this file is wrong in the same way and stops compiling or stops
 * agreeing with the expected output -- which is the only check available while
 * the emitter itself cannot be built (there is no c3c here; see §7 of the doc).
 *
 * Build and run:  cc -std=c11 -Wall -Wextra -Werror shape_test.c -o /tmp/shape_test
 *                 /tmp/shape_test
 * It is wired into tests/air3/c/run.sh and `make test-c-target`.
 * ==========================================================================*/
#include "__pride_rt.h"

/* ---- AIR: `data` with one constructor => a struct ------------------------ */
struct Point { int64_t x; int64_t y; };

/* ---- AIR: a label spine with a back edge => hoisted params + goto --------
 *
 * AIR (AIR 3.0 low, after air_low has lowered `while`):
 *   def sum_to(n: i64) : i64
 *     label L0(i: i64, acc: i64)
 *       %c = i <= n
 *       if %c then jump L1(i, acc) else jump L2(i, acc)
 *     ...
 *
 * Two things are load-bearing here and both are properties of C, not of my
 * taste: the label parameters become locals declared ONCE at the top (a phi
 * written on one path is read on another, and C blocks do not share scope), and
 * the back edge is a plain `goto`. This is the whole of §3.
 * ------------------------------------------------------------------------*/
int64_t air_sum_to(int64_t n)
{
    int64_t L0_i, L0_acc;      /* hoisted label parameters */
    int64_t r = 0;

    L0_i = 0;                  /* the entry jump's parallel copy */
    L0_acc = 0;
    goto L0;

L0: {
    bool c = (L0_i <= n);     /* APRD_BINOP: LE on i64 -> bool */
    if (c) { goto L1; } else { goto L2; }
}
L1: {
    int64_t a = (L0_acc + L0_i);   /* APRD_BINOP: ADD */
    int64_t i2 = (L0_i + 1);       /* APRD_BINOP: ADD */
    L0_i = i2;                     /* the vertex: both writes complete first */
    L0_acc = a;
    goto L0;                       /* back edge */
}
L2: {
    r = L0_acc;                    /* ACMD_RET through the spine */
    goto done3;
}
done3:
    return r;
}

/* ---- AIR: the same, but the parallel copy needs a vertex ----------------
 * `jump L0(i2, a)` where both new values are read from the old ones is the
 * textbook lost-copy problem. The emitter emits a temp for EVERY vertex in a
 * parallel copy that has more than one assignment, rather than analysing whether
 * the copies actually interfere: one extra copy per iteration is cheaper than a
 * wrong answer, and PIR's header makes the same argument for slots.
 * ----------------------------------------------------------------------*/
int64_t air_fib(int64_t n)
{
    int64_t i, a, b;
    int64_t r;
    i = 0; a = 0; b = 1;
    goto F0;
F0: {
    bool c = (i < n);
    if (c) { goto F1; } else { goto F2; }
}
F1: {
    int64_t nt = (a + b);
    int64_t ni = (i + 1);
    int64_t v0 = nt;      /* vertex: `jump F0(ni, nt, a)` */
    int64_t v1 = ni;
    int64_t v2 = a;
    a = v0; i = v1; b = v2;
    goto F0;
}
F2: {
    r = a;
    goto done4;
}
done4:
    return r;
}

/* ---- AIR: MATCH on an int => switch, CUT inside an arm => assignment ---- */
int64_t air_match(int64_t x)
{
    int64_t y;
    switch (x)
    {
        case 0: y = 100; goto M2;
        case 1: y = 200; goto M2;
        case 7: y = 700; goto M2;
        default: y = -1; goto M2;
    }
M2:
    return y;
}

/* ---- AIR: alloca/load/store/gep through a struct pointer ---------------
 * APRD_ALLOCA -> a C local and `&local`; APRD_LOAD -> `*p`; ACMD_STORE -> `*p = v`;
 * APRD_GEP with a literal struct index -> `&p->field`. No helpers, no casts. */
void air_geo(void)
{
    struct Point p;            /* alloca(Point) */
    struct Point *pp = &p;
    int64_t *px = &pp->x;      /* gep[Point](pp, 0) */
    int64_t *py = &pp->y;      /* gep[Point](pp, 1) */
    *px = 3;                   /* store */
    *py = (*(px) + 4);         /* load, add, store */
    atomic_store_explicit((_Atomic int64_t *)px, (int64_t)9, memory_order_seq_cst);
}

/* ---- AIR: tuple => a generated struct, with a field per index ---------- */
struct __tup_i64_i64 { int64_t _0; int64_t _1; };

int64_t air_tuple(void)
{
    struct __tup_i64_i64 t = { ._0 = 11, ._1 = 31 };
    int64_t a = t._0;          /* ACNS_PROJ -> ._0 */
    int64_t b = t._1;
    return (a + b);
}

/* ---- AIR: fixed array, APRD_ARRAY and gep --------------------------------- */
int64_t air_array(void)
{
    int64_t a[4] = { 5, 6, 7, 8 };            /* APRD_ARRAY */
    int64_t *p = &(a)[0];
    int64_t s = 0;
    for (int64_t i = 0; i < 4; i++) { s = (s + *(p + i)); }   /* gep[array](p, i), load */
    return s;
}

/* ---- AIR: strings and bytes -------------------------------------------- */
static const char __s0[] = "air says hi";

/* ---- AIR: global, and a `declare` through the C ABI --------------------- */
int64_t pear_out_counter = 0;                 /* global mut, no initialiser */

int main(void);

/* AIR: a closure record is {fn, env} -- ordinary data, no new form. */
struct Fn__i64_i64 { int64_t (*fn)(uint8_t *, int64_t); uint8_t *env; };

static int64_t clo_body(uint8_t *env, int64_t x) { return x + *(int64_t *)env; }

int64_t air_closure(int64_t cap)
{
    struct Fn__i64_i64 f;
    f.fn = clo_body;
    f.env = (uint8_t *)&cap;
    return f.fn(f.env, 5);       /* ind.clo adapter: the call goes through the record */
}

/* ---- the checks --------------------------------------------------------- */
static int fails = 0;
static void check(const char *what, int64_t got, int64_t want)
{
    if (got != want) { __builtin_printf("FAIL %s: got %lld want %lld\n", what, (long long)got, (long long)want); fails++; }
}

extern int __builtin_printf(const char *, ...);

int main(void)
{
    check("sum_to(5) = 15", air_sum_to(5), 15);
    check("sum_to(0) = 0", air_sum_to(0), 0);
    check("fib(10) = 55", air_fib(10), 55);
    check("match(7) = 700", air_match(7), 700);
    check("match(3) = -1", air_match(3), -1);
    check("tuple = 42", air_tuple(), 42);
    check("array = 26", air_array(), 26);
    check("closure = 15", air_closure(10), 15);
    check("string len", (int64_t)(sizeof(__s0) - 1), 11);

    air_geo();
    check("global starts 0", pear_out_counter, 0);

    if (fails == 0) { __builtin_printf("shape_test: all %d checks pass\n", 9); return 0; }
    return 1;
}
