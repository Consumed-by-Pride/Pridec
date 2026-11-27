/* ============================================================================
 * __pride_rt.h -- the generated runtime for AIR 3.0 -> C output.
 *
 * This is the whole of what air_c emits ahead of a module's own code. It is
 * C11 + one x86-64 Linux inline-asm block, and every entry here exists because
 * an AIR 3.0 low-profile form has no direct C expression:
 *
 *   alloca/load/store/gep   -> ordinary C locals and `*p`, `p[i]`, `p->f`
 *   trap / ub               -> __pride_trap / __builtin_unreachable
 *   volatile load/store     -> *(volatile T *)p        (a cast, not a helper)
 *   atomic ops              -> <stdatomic.h>           (a macro, not a helper)
 *   fence                   -> atomic_thread_fence
 *   syscall                 -> inline asm, Linux ABI
 *   asm                     -> __asm__ volatile
 *
 * The point of keeping it this small is that a generated C file stays readable:
 * anything that could be an ordinary C expression is printed as one, rather than
 * as a call to a stub. See docs/pear2/C_TARGET.md.
 * ==========================================================================*/
#ifndef PRIDE_RT_H
#define PRIDE_RT_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdatomic.h>
#include <string.h>

/* AIR's `isz`/`usz` are pointer-width. intptr_t/uintptr_t are exactly that, and
 * unlike `size_t` intptr_t is signed, which AIR's `isz` is. */
typedef intptr_t  pride_isz;
typedef uintptr_t pride_usz;

/* AIR `unit` as a value (it appears only as an aggregate part). */
typedef struct { char __unused; } pride_unit;

/* `trap` ends the program and does not return; `ub` is a promise the program
 * never gets here, so it needs no code at all -- but a body that falls off the
 * end of a switch must still be terminated, so both are spelled as a call that
 * the compiler knows does not return. */
static inline void __pride_trap(const char *why) { (void)why; __builtin_trap(); }
#define __pride_ub(why) __builtin_unreachable()

/* ---- syscall -------------------------------------------------------------
 * AIR 3.0: `syscall` with a number and up to 6 operands, all i64, result i64.
 * x86-64 Linux: rax = number, then rdi rsi rdx r10 r8 r9.
 * The odd argument order (r10 before r8) is the ABI's, not a mistake.
 * ------------------------------------------------------------------------*/
static inline int64_t __pride_syscall1(int64_t n)
{
    int64_t r;
    __asm__ volatile ("syscall" : "=a"(r) : "a"(n) : "rcx", "r11", "memory");
    return r;
}
static inline int64_t __pride_syscall2(int64_t n, int64_t a)
{
    int64_t r;
    __asm__ volatile ("syscall" : "=a"(r) : "a"(n), "D"(a) : "rcx", "r11", "memory");
    return r;
}
static inline int64_t __pride_syscall3(int64_t n, int64_t a, int64_t b)
{
    int64_t r;
    __asm__ volatile ("syscall" : "=a"(r) : "a"(n), "D"(a), "S"(b) : "rcx", "r11", "memory");
    return r;
}
static inline int64_t __pride_syscall4(int64_t n, int64_t a, int64_t b, int64_t c)
{
    int64_t r;
    __asm__ volatile ("syscall" : "=a"(r) : "a"(n), "D"(a), "S"(b), "d"(c) : "rcx", "r11", "memory");
    return r;
}
static inline int64_t __pride_syscall5(int64_t n, int64_t a, int64_t b, int64_t c, int64_t d)
{
    int64_t r;
    register int64_t r10 __asm__("r10") = d;
    __asm__ volatile ("syscall" : "=a"(r) : "a"(n), "D"(a), "S"(b), "d"(c), "r"(r10) : "rcx", "r11", "memory");
    return r;
}
static inline int64_t __pride_syscall6(int64_t n, int64_t a, int64_t b, int64_t c, int64_t d, int64_t e)
{
    int64_t r;
    register int64_t r10 __asm__("r10") = d;
    register int64_t r8  __asm__("r8")  = e;
    __asm__ volatile ("syscall" : "=a"(r) : "a"(n), "D"(a), "S"(b), "d"(c), "r"(r10), "r"(r8) : "rcx", "r11", "memory");
    return r;
}
static inline int64_t __pride_syscall7(int64_t n, int64_t a, int64_t b, int64_t c, int64_t d, int64_t e, int64_t f)
{
    int64_t r;
    register int64_t r10 __asm__("r10") = d;
    register int64_t r8  __asm__("r8")  = e;
    register int64_t r9  __asm__("r9")  = f;
    __asm__ volatile ("syscall" : "=a"(r) : "a"(n), "D"(a), "S"(b), "d"(c), "r"(r10), "r"(r8), "r"(r9) : "rcx", "r11", "memory");
    return r;
}

/* ---- attributes ---------------------------------------------------------
 * AIR declaration attributes that C11 has no keyword for. Each is a macro
 * because the AIR attribute is a property of the declaration the emitter is
 * already printing next to it.
 * ------------------------------------------------------------------------*/
#define PRIDE_SECTION(x) __attribute__((section(x)))
#define PRIDE_ALIGN(n)   __attribute__((aligned(n)))
#define PRIDE_PACKED     __attribute__((packed))
#define PRIDE_NORETURN   __attribute__((noreturn))
#define PRIDE_INLINE     __attribute__((always_inline)) inline
#define PRIDE_NOINLINE   __attribute__((noinline))
#define PRIDE_TLOCAL     _Thread_local
#define PRIDE_UNUSED     __attribute__((unused))

#endif /* PRIDE_RT_H */
