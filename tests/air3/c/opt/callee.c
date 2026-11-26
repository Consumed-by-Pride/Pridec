/* A separate AIR module: its own .c file, so the caller's compiler cannot see
 * into it. This is the realistic shape -- AIR modules lower to separate C files,
 * and only the fact attributes cross that boundary. */
#include <stdint.h>
int64_t width(int64_t *p, int64_t n) { return p[n >> 4]; }
int64_t width_pure(int64_t *p, int64_t n) __attribute__((pure));
int64_t width_pure(int64_t *p, int64_t n) { return p[n >> 4]; }
