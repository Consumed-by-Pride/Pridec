/* What AIR's facts are worth, measured end to end.
 *
 * The two programs below are the same code. They differ only in the qualifiers
 * air_c now prints on the strength of AIR facts it has certified:
 *
 *   memory_readonly (AFACT_AIR_CHECKED) -> __attribute__((pure)) on the callee
 *   no_capture      (AFACT_AIR_CHECKED) -> `restrict` on the pointer parameter
 *
 * Without them the C compiler must assume `width()` may write through `p` and
 * that `*g` may change across the call, so every iteration reloads memory the
 * program never touches. This file exists so the claim "faster than the same
 * program in C" is a measurement rather than a slogan -- and so that the places
 * where it is NOT faster are measured too (see §5 of docs/pear2/C_TARGET.md).
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

/* The callee lives in callee.c -- a separate AIR module, so neither version can
 * see that it only reads. That is the whole point: without the fact the caller
 * must assume it writes, and WITH the fact the caller may assume it does not. */
extern int64_t width(int64_t *p, int64_t n);

/* ── the AIR facts withheld: plain C ─────────────────────────────────────── */
extern int64_t total_blind(const int64_t *a, const int64_t *g, int64_t n);
int64_t total_blind(const int64_t *a, const int64_t *g, int64_t n)
{
    int64_t s = 0;
    for (int64_t i = 0; i < n; i++) { s += *g + width((int64_t *)a, n) + a[i]; }
    return s;
}

/* ── the AIR facts used: exactly what air_c now prints ─────────────────── */
/* `pure` is what air_c prints for memory_readonly. Declared here, defined in
 * callee.c under the same attributes (the declaration is what the caller sees). */
extern int64_t width_pure(int64_t *p, int64_t n) __attribute__((pure));

int64_t total_facts(const int64_t *restrict a, const int64_t *restrict g, int64_t n)
{
    int64_t s = 0;
    for (int64_t i = 0; i < n; i++) { s += *g + width_pure((int64_t *)a, n) + a[i]; }
    return s;
}

static double now(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (double)t.tv_sec + (double)t.tv_nsec * 1e-9;
}

int main(void)
{
    const int64_t N = 2 * 1000 * 1000;
    const int64_t reps = 200;
    int64_t *a = malloc((size_t)N * sizeof *a);
    int64_t g = 7;
    if (a == NULL) { return 2; }
    for (int64_t i = 0; i < N; i++) { a[i] = i; }

    volatile int64_t sink = 0;
    sink += total_blind(a, &g, N);
    sink += total_facts(a, &g, N);
    if (sink <= 0) { return 2; }              /* keep both calls alive */

    double t0 = now(); for (int64_t r = 0; r < reps; r++) { sink += total_blind(a, &g, N); } double t1 = now();
    double t2 = now(); for (int64_t r = 0; r < reps; r++) { sink += total_facts(a, &g, N); } double t3 = now();

    double blind = (t1 - t0) / (double)reps * 1000.0;
    double facts = (t3 - t2) / (double)reps * 1000.0;
    printf("plain C          (facts withheld): %7.3f ms\n", blind);
    printf("air_c output     (facts licensed): %7.3f ms\n", facts);
    printf("ratio                             : %.2fx\n", blind / facts);
    free(a);
    return 0;
}
