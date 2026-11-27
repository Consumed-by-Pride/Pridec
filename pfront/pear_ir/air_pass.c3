// ============================================================================
// air_pass.c3 — the AIR pass driver
// ----------------------------------------------------------------------------
// `pfront` emits AIR and stops. Until now there was nowhere to put an AIR-to-AIR
// rewrite: the only optimiser in the project lived inside one backend
// (`pear2/pear2_opt.c3`), so a second consumer of AIR could not use it, and no
// pass could be measured on its own. This module is the missing engine.
//
// A pipeline is a list of pass names. The driver:
//
//   1. runs each pass in the order given, and iterates the WHOLE list to a
//      fixpoint (a round that changes nothing ends the loop) up to a cap, so a
//      pass only has to be correct once and the "run it again" is free;
//   2. verifies the module after EVERY pass (air_verify), so a pass that
//      produces a malformed module names itself instead of corrupting the file
//      a backend later reads;
//   3. optionally writes the module after each pass (`--print-after`), which is
//      what makes a pass reviewable as a diff instead of an assertion;
//   4. reports a per-pass rewrite count, so "did it do anything" is a number and
//      not a claim.
//
// Passes are named in the registry below and dispatched through one switch.
// A function pointer table would be tidier, but a switch is a closed set that a
// reader can enumerate, and it keeps every pass's signature identical.
//
// Adding a pass:
//   * write `fn bool run(AirModule* m, PassStats* st)` in its own module;
//   * return true iff the module changed (that is what drives the fixpoint);
//   * add a `case` to `run_one` and a name to `pass_index`.
// A pass that returns true without changing anything makes the driver spin to
// its round cap: the round limit exists because of that mistake, and the report
// prints the round count so it is visible.
// ============================================================================
module air_pass;

import air_ir;
import air_text;
import air_verify;
import air_write;
import air_fold;

extern fn int printf(char* fmt, ...);
extern fn int snprintf(char* buf, usz size, char* fmt, ...);

// Why a fixed cap instead of trusting `changed`: two passes in a pipeline can
// undo each other (fold then un-fold). The cap turns "oscillates forever" into
// "stops after N rounds and says N", which is a bug report rather than a hang.
const int AIR_PASS_MAX_ROUNDS = 8;

struct PassStats
{
    usz rounds;          // pipeline rounds executed
    usz changes;         // passes that reported a change
    usz verified;        // verification runs
    usz rewrites;        // pass-specific rewrite count, summed
    bool failed;         // a pass or the verifier reported a problem
    bool oscillating;    // hit the round cap while still changing
}

// ---------------------------------------------------------------------------
// Registry. The order here is only the order names resolve; the pipeline order
// is whatever `--passes=` says.
// ---------------------------------------------------------------------------
fn int pass_index(char* name)
{
    if (air_text::streq(name, "nop"))   { return 0; }
    if (air_text::streq(name, "fold"))  { return 1; }
    return -1;
}

fn char* pass_name(int which)
{
    switch (which)
    {
        case 0: return (char*)"nop";
        case 1: return (char*)"fold";
        default: return (char*)"?";
    }
}

// One pass. `changed` is the pass's own answer; `failed` is set when the pass
// could not complete (a pass must not report "unchanged" because it gave up).
fn bool run_one(int which, AirModule* m, bool* failed)
{
    switch (which)
    {
        // `nop` exists to be the identity element of a pipeline: it is how the
        // driver, the reader/writer round trip and `--print-after` are tested
        // without a single optimisation involved.
        case 0: return false;
        case 1:
        {
            air_fold::Stats st;
            st.init();
            bool changed = air_fold::run(m, &st);
            if (st.failed) { *failed = true; }
            return changed;
        }
        default: { *failed = true; return false; }
    }
}

// One pass, then verify, then optionally dump. Verification after every pass is
// the whole point: a malformed module has to be attributed to the pass that made
// it, while the pass is still the last thing that ran.
//
// Two DIFFERENT results travel out of here and conflating them is this file's
// first bug (the driver read "did not change" as "failed" and every pipeline
// with a nop in it exited 1): the return value is "the module is still usable",
// and `changed_out` is "this pass rewrote something", which is what the
// fixpoint loop counts.
fn bool step(int which, AirModule* m, PassStats* st, bool verify_each, char* dump_dir, char* stem, bool* changed_out)
{
    bool failed = false;
    bool changed = run_one(which, m, &failed);
    if (changed_out != null) { *changed_out = changed; }
    if (failed)
    {
        printf("air opt: pass '%s' failed\n", pass_name(which));
        st.failed = true;
        return false;
    }
    if (st != null && changed) { st.changes = st.changes + 1; }
    if (verify_each)
    {
        int[8] cnt;
        int n = air_verify::verify_module(m, &cnt[0], false, 20);
        st.verified = st.verified + 1;
        if (n != 0)
        {
            printf("air opt: pass '%s' produced an invalid module (%d violation(s))\n", pass_name(which), n);
            st.failed = true;
            return false;
        }
    }
    if (dump_dir != null && dump_dir[0] != 0)
    {
        // FILE.<n>-<pass>.air, numbered so the order is the filename's order even
        // when one pass runs in several rounds.
        char[4096] path;
        int k = snprintf(&path[0], 4096, "%s/%s.%02d-%s.air", dump_dir, stem, (int)st.verified, pass_name(which));
        if (k <= 0 || k >= 4096)
        {
            printf("air opt: --print-after path is too long\n");
            st.failed = true;
            return false;
        }
        // A dump that silently fails is worse than no dump: the whole point is
        // to look at what the pass did. The writer reports the error count.
        int werrs = air_write::write_module(m, &path[0]);
        if (werrs != 0)
        {
            printf("air opt: cannot write '%s' (%d error(s))\n", &path[0], werrs);
            st.failed = true;
            return false;
        }
    }
    return true;
}

// The pipeline driver. One implementation, because two fixpoint loops that
// disagree about when to stop is exactly the class of bug this file exists to
// prevent.
//
// The loop condition compares the cumulative change count before and after a
// round: `changes` has two jobs (the report and the loop), and overloading it is
// how a fixpoint loop ends up either stopping after one pass or never stopping.
// Returns true when the module is usable; `st.failed` is set otherwise.
fn bool run(AirModule* m, int* which, usz count, PassStats* st, bool verify_each, char* dump_dir, char* stem)
{
    if (m == null || st == null) { return false; }
    if (count == 0) { return true; }
    for (int round = 0; round < AIR_PASS_MAX_ROUNDS; round++)
    {
        st.rounds = st.rounds + 1;
        usz before = st.changes;
        for (usz i = 0; i < count; i++)
        {
            if (!step(which[i], m, st, verify_each, dump_dir, stem, null)) { return false; }
        }
        if (st.changes == before) { return true; }   // fixpoint: a whole round changed nothing
    }
    st.oscillating = true;
    return true;
}

fn void PassStats.init(PassStats* st)
{
    st.rounds = 0; st.changes = 0; st.verified = 0; st.rewrites = 0;
    st.failed = false; st.oscillating = false;
}

fn void PassStats.report(PassStats* st)
{
    printf("air opt: %d round(s), %d pass change(s), %d verification(s)%s\n",
           (int)st.rounds, (int)st.changes, (int)st.verified, st.oscillating ? " (round cap: passes are oscillating)" : "");
}

// Parse `a,b,c` into indices. Unknown names are a hard error: a typo in a
// pipeline string must not silently run a subset of the passes, because the
// resulting module would look optimised and not be.
fn bool parse_pipeline(char* spec, int* out, usz cap, usz* count)
{
    if (spec == null || out == null || count == null) { return false; }
    *count = 0;
    usz i = 0;
    while (spec[i] != 0)
    {
        char[64] name;
        usz n = 0;
        while (spec[i] != 0 && spec[i] != ',')
        {
            if (n + 1 >= 64) { return false; }
            if (spec[i] != ' ') { name[n] = spec[i]; n = n + 1; }
            i = i + 1;
        }
        name[n] = 0;
        if (n > 0)
        {
            int which = pass_index(&name[0]);
            if (which < 0) { printf("air opt: unknown pass '%.*s'\n", (int)n, &name[0]); return false; }
            if (*count >= cap) { return false; }
            out[*count] = which; *count = *count + 1;
        }
        if (spec[i] == ',') { i = i + 1; }
    }
    return *count > 0;
}
