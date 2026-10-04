// Pride runtime for wasm32-wasi (C, compiled with `zig cc -target wasm32-wasi`).
//
// AIR 3 is target-neutral: an extern declared in Pride keeps the signature Pride gave it (`i64` is 64 bits, so
// a C `size_t` parameter declared `i64` is an i64 in the .air). A 32-bit target's libc takes 32-bit sizes, so
// scripts/ll-exe.py renames every external function F of a wasm module to `pride_rt_F` and THIS file defines
// each of them with the Pride-declared (i64) signature, forwarding to wasi-libc. The link error for a missing
// symbol therefore names exactly what a target must supply.
//
// `syscall` (the AIR `syscall` instruction and libc's variadic `syscall`) is emulated for the Linux numbers the
// stdlib uses most; an unknown number returns -38 (ENOSYS).
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>

// size_t / ssize_t parameters are pointer-wide: the lowering declares these C functions with usz/isz (air_low.c3 c_abi_widths), i32 on wasm32
void *pride_rt_malloc(size_t n) { return malloc(n); }
void pride_rt_free(void *p) { free(p); }
ssize_t pride_rt_write(int fd, const void *p, size_t n) { return write(fd, p, n); }
ssize_t pride_rt_read(int fd, void *p, size_t n) { return read(fd, p, n); }
void *pride_rt_calloc(size_t a, size_t b) { return calloc(a, b); }
void *pride_rt_realloc(void *p, size_t n) { return realloc(p, n); }
void *pride_rt_memcpy(void *d, const void *s, size_t n) { return memcpy(d, s, n); }
void *pride_rt_memmove(void *d, const void *s, size_t n) { return memmove(d, s, n); }
void *pride_rt_memset(void *d, int c, size_t n) { return memset(d, c, n); }
int pride_rt_memcmp(const void *a, const void *b, size_t n) { return memcmp(a, b, n); }
size_t pride_rt_strlen(const char *s) { return strlen(s); }
int pride_rt_strcmp(const char *a, const char *b) { return strcmp(a, b); }
int pride_rt_close(int fd) { return close(fd); }
void pride_rt_exit(int c) { exit(c); }
void pride_rt_abort(void) { abort(); }

long long pride_rt_syscall(long long nr, ...)
{
    va_list ap; va_start(ap, nr);
    long long a = va_arg(ap, long long), b = va_arg(ap, long long), c = va_arg(ap, long long);
    va_end(ap);
    switch (nr)
    {
        case 0:   { long r = read((int)a, (void *)(size_t)b, (size_t)c); return r < 0 ? -errno : r; }
        case 1:   { long r = write((int)a, (const void *)(size_t)b, (size_t)c); return r < 0 ? -errno : r; }
        case 3:   { int r = close((int)a); return r < 0 ? -errno : r; }
        case 39:  return 1;                                   // getpid
        case 60: case 231: exit((int)a);                      // exit, exit_group
        case 228: { struct timespec ts; int r = clock_gettime((clockid_t)a, &ts); if (r) return -errno;
                    long long *o = (long long *)(size_t)b; o[0] = ts.tv_sec; o[1] = ts.tv_nsec; return 0; }   // clock_gettime (64-bit timespec)
        default:  return -38;
    }
}

// the entry: ll-exe renames the program's `main` to pride_rt_main. WASI cannot exit with a status >= 126, so a
// larger one is reported on stderr as `pride-exit:N` (scripts/wasm-run.py turns it back into the exit status).
extern int pride_rt_main(void);
int main(void)
{
    int r = pride_rt_main();
    if (r >= 0 && r < 126) { return r; }
    fprintf(stderr, "\npride-exit:%d\n", r & 255);
    return 125;
}

long long pride_rt_labs(long long x) { return x < 0 ? -x : x; }
int pride_rt_abs(int x) { return x < 0 ? -x : x; }
