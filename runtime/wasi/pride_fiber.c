// Fibers for wasm32: the runtime behind __pride_fiber_{spawn,resume,yield,release} (what non-tail-resumptive effect handlers use).
//
// wasm has no way to switch stacks, so scripts/wasm-fibers.py runs binaryen's Asyncify over the linked module: a function that calls
// `asyncify.start_unwind` returns immediately and every instrumented caller saves its locals into a buffer and returns in turn (the
// call stack is unwound into memory); `start_rewind` + calling the entry again replays down to the same call site (the stack is rebuilt).
// A fiber is therefore: its own Asyncify buffer (the saved wasm call stack while it is suspended) and its own region of linear memory for
// the C shadow stack (`__stack_pointer`: allocas and spilled locals), so the frames of a suspended fiber survive while another one runs.
//
//   resume(f, v): f.val = v; switch __stack_pointer to f's stack; call the entry (first time) or rewind into it (later);
//                 when control comes back, either the entry returned (f is done, f.val is its result) or it yielded (unwind stopped here).
//   yield(v):     f.val = v; remember the stack pointer; start unwinding -- the unwind stops in resume, which returns f.val to its caller.
//   Re-entering after a yield: yield sees `rewinding`, stops the rewind and returns the value the resumer passed.
//
// pride_fiber_sched is the one function Asyncify must NOT instrument (--pass-arg=asyncify-removelist@pride_fiber_sched): it is the place the
// unwind stops, so it must see the callee return normally.  The state is kept in `mode` here, not read back from Asyncify.
// Resuming a fiber from inside another fiber is fine (each resume is its own stopping point); a fiber that was resumed on a different
// resume frame than the one that started it is fine too, the saved stack does not contain resume frames.
#include <stdint.h>
#include <stdlib.h>

#ifndef PRIDE_FIBER_ASYNC_BYTES
#define PRIDE_FIBER_ASYNC_BYTES (2048 * 1024)  // the saved wasm call stack of a suspended fiber (locals of every frame); linear memory is committed lazily
#endif
#ifndef PRIDE_FIBER_STACK_BYTES
#define PRIDE_FIBER_STACK_BYTES (1024 * 1024)  // the C shadow stack of a fiber
#endif

__asm__(".globaltype __stack_pointer, i32\n");
static inline uint32_t get_sp(void) { uint32_t v; __asm__ volatile("global.get __stack_pointer\n\tlocal.set %0" : "=r"(v)); return v; }
static inline void set_sp(uint32_t v) { __asm__ volatile("local.get %0\n\tglobal.set __stack_pointer" : : "r"(v)); }

__attribute__((import_module("asyncify"), import_name("start_unwind"))) void asyncify_start_unwind(void *);
__attribute__((import_module("asyncify"), import_name("stop_unwind")))  void asyncify_stop_unwind(void);
__attribute__((import_module("asyncify"), import_name("start_rewind"))) void asyncify_start_rewind(void *);
__attribute__((import_module("asyncify"), import_name("stop_rewind")))  void asyncify_stop_rewind(void);

enum { MODE_NORMAL = 0, MODE_UNWINDING = 1, MODE_REWINDING = 2 };
static int mode = MODE_NORMAL;

typedef void *(*entry_t)(void *);
typedef struct Fiber {
    void *abuf[2];          // Asyncify data header: {current, end}; the buffer follows
    char *async_mem;
    size_t async_bytes;
    char *stack_mem;
    uint32_t stack_top;     // initial shadow stack pointer
    uint32_t sp;            // shadow stack pointer at the last yield
    entry_t entry;
    void *val;
    int started, done;
    struct Fiber *prev;     // the fiber that was running when this one was resumed (NULL: the main program)
} Fiber;
static Fiber *current = 0;

// PRIDE_FIBER_ASYNC_KB / PRIDE_FIBER_STACK_KB (WASI environment) override the sizes, like PRIDE_FIBER_STACK_KB on native
static size_t env_kb(const char *name, size_t dflt_bytes)
{
    const char *e = getenv(name);
    size_t kb = e ? (size_t)strtoul(e, 0, 10) : 0;
    return kb >= 16 ? kb * 1024 : dflt_bytes;
}

void *pride_rt___pride_fiber_spawn(void *entry, void *arg)
{
    Fiber *f = (Fiber *)calloc(1, sizeof(Fiber));
    if (!f) abort();
    f->async_bytes = env_kb("PRIDE_FIBER_ASYNC_KB", PRIDE_FIBER_ASYNC_BYTES);
    size_t sb = env_kb("PRIDE_FIBER_STACK_KB", PRIDE_FIBER_STACK_BYTES);
    f->async_mem = (char *)malloc(f->async_bytes);
    f->stack_mem = (char *)malloc(sb + 16);
    if (!f->async_mem || !f->stack_mem) abort();
    f->stack_top = ((uint32_t)(uintptr_t)f->stack_mem + (uint32_t)sb + 15u) & ~15u;
    f->sp = f->stack_top;
    f->entry = (entry_t)entry;
    f->val = arg;
    return f;
}

// not instrumented: the unwind of the fiber's frames ends here
__attribute__((noinline)) static void pride_fiber_sched(Fiber *f)
{
    uint32_t caller_sp = get_sp();
    f->prev = current;
    current = f;
    set_sp(f->sp);
    if (!f->started) {
        f->started = 1;
        void *r = f->entry(f->val);
        if (mode == MODE_UNWINDING) {            // the fiber yielded: its frames are saved in abuf
            asyncify_stop_unwind();
            mode = MODE_NORMAL;
        } else {                                 // the entry returned
            f->val = r; f->done = 1;
        }
    } else {
        mode = MODE_REWINDING;
        asyncify_start_rewind(&f->abuf[0]);
        void *r = f->entry(f->val);              // replays down to the yield that suspended it
        if (mode == MODE_UNWINDING) {
            asyncify_stop_unwind();
            mode = MODE_NORMAL;
        } else {
            f->val = r; f->done = 1;
        }
    }
    current = f->prev;
    set_sp(caller_sp);
}

void *pride_rt___pride_fiber_resume(void *fp, void *arg)
{
    Fiber *f = (Fiber *)fp;
    if (!f || f->done) return 0;
    f->val = arg;
    pride_fiber_sched(f);
    return f->val;
}

void *pride_rt___pride_fiber_yield(void *arg)
{
    Fiber *f = current;
    if (!f) abort();
    if (mode == MODE_REWINDING) {                // re-entered by resume: the frames are rebuilt, carry on from here
        asyncify_stop_rewind();
        mode = MODE_NORMAL;
        return f->val;
    }
    f->val = arg;
    f->sp = get_sp();
    f->abuf[0] = f->async_mem;
    f->abuf[1] = f->async_mem + f->async_bytes;
    mode = MODE_UNWINDING;
    asyncify_start_unwind(&f->abuf[0]);
    return 0;                                    // ignored: the unwind returns through every instrumented frame
}

void pride_rt___pride_fiber_release(void *fp)
{
    Fiber *f = (Fiber *)fp;
    if (!f) return;
    free(f->async_mem); free(f->stack_mem); free(f);
}
