// ============================================================================
// theory_dataflow.c3 — Generic monotone dataflow framework
// ----------------------------------------------------------------------------
// Dataflow analysis (Kildall 1973; Kam/Ullman 1977) is the workhorse of the
// middle end. theory_opt.c3 runs specific constant-prop and algebraic
// simplifications, theory_live.c3 solves liveness, and theory_absint.c3 runs
// abstract interpretation with intervals/signs — but none of them share a
// generic fixpoint ENGINE. This file provides that engine so additional
// analyses (reaching defs, available expressions, busy expressions,
// anticipability, partial-redundancy, taint, null-deref) can be added as
// plain TRANSFER FUNCTIONS over a uniform lattice without re-implementing
// the worklist loop.
//
// Two directions plus may/must meet operators cover four classic bitvector
// problems here: reaching definitions, available expressions, very-busy
// expressions, and live variables. Product/bidirectional PRE is not claimed.
//
// The current finite bitvector lattice has explicit bottom/top identities,
// OR for may analyses and AND for must analyses, and the standard
// OUT=GEN ∪ (IN−KILL) transfer. The worklist is a bounded circular queue;
// disconnected function/clause entries and exits each receive a boundary
// fact, so one module CFG can contain many independent components.
//
// This file instantiates the engine on a real pfront_cfg CFG assembled from
// every function clause in the module. Facts are binder-identity reaching
// definitions and structurally equal pure expressions; the four solvers are
// reaching-definitions (forward may), available-expressions (forward must),
// very-busy expressions (backward must), and live variables (backward may).
//
// Reference:
//   Kildall 1973 "A Unified Approach to Global Program Optimization"
//   Kam & Ullman 1977 "Monotone Data Flow Analysis Frameworks"
//   Morel/Renvoise 1979 "Interprocedurally valid PRE"
//   Aho/Sethi/Ullman 1986 "Compilers" ch. 10
// ============================================================================

module theory_dataflow;

import pfront_lex;
import pfront_core;
import pfront_cfg;
import theory_term;

alias Tk    = pfront_lex::TokenType;
alias Node  = pfront_core::PNode;
alias Nk    = pfront_core::NodeKind;
alias Arena = pfront_core::Arena;
alias Block = pfront_cfg::Block;
alias Cfg   = pfront_cfg::Cfg;

extern fn void* malloc(usz size);
extern fn void* calloc(usz nmemb, usz size);
extern fn void* realloc(void* p, usz size);
extern fn void  free(void* ptr);
extern fn int   printf(char* fmt, ...);

const usz DF_MAX_BLOCKS    = 8192;
const usz DF_MAX_WORDS     = 64;        // bits per fact: 64 * 64 = 4096
const usz DF_MAX_FACTS     = 16;
const int DF_MAX_ITERS     = 256;
const usz DF_FACT_SZ       = DF_MAX_WORDS * 8 + 8;  // bits + bool

enum DfDirection : int { DF_FORWARD, DF_BACKWARD }
enum DfMeet : int { DF_OR, DF_AND }

// ── Bitvector fact ────────────────────────────────────────────────────
struct DfFact
{
    ulong[DF_MAX_WORDS] bits;
    bool    bottom;
}

fn void df_bottom(DfFact* f)
{
    for (usz i = 0; i < DF_MAX_WORDS; i++) f.bits[i] = 0;
    f.bottom = true;
}

fn void df_boundary(DfFact* f, DfMeet meet, usz facts)
{
    for (usz i = 0; i < DF_MAX_WORDS; i++) f.bits[i] = 0;
    if (meet == DfMeet.DF_AND)
    {
        for (usz i = 0; i < facts / 64; i++) f.bits[i] = 0xffffffffffffffffUL;
        if (facts % 64 != 0) f.bits[facts / 64] = (1UL << (facts % 64)) - 1UL;
    }
    f.bottom = false;
}

fn bool df_equal(DfFact* a, DfFact* b)
{
    if (a.bottom != b.bottom) return false;
    if (a.bottom) return true;
    for (usz i = 0; i < DF_MAX_WORDS; i++) { if (a.bits[i] != b.bits[i]) return false; }
    return true;
}

fn void df_join(DfFact* dst, DfFact* other, DfMeet meet)
{
    if (dst.bottom) { for (usz i = 0; i < DF_MAX_WORDS; i++) dst.bits[i] = other.bits[i]; dst.bottom = other.bottom; return; }
    if (other.bottom) return;
    if (meet == DfMeet.DF_OR)
    {
        for (usz i = 0; i < DF_MAX_WORDS; i++) dst.bits[i] = dst.bits[i] | other.bits[i];
    }
    else
    {
        for (usz i = 0; i < DF_MAX_WORDS; i++) dst.bits[i] = dst.bits[i] & other.bits[i];
    }
}

fn bool df_subset(DfFact* a, DfFact* b, usz facts)
{
    for (usz i = 0; i < DF_MAX_WORDS; i++)
    {
        ulong valid = 0xffffffffffffffffUL;
        if (i * 64 >= facts) { valid = 0; }
        else if ((i + 1) * 64 > facts) { valid = (1UL << (facts - i * 64)) - 1UL; }
        if ((a.bits[i] & ~b.bits[i] & valid) != 0) return false;
    }
    return true;
}

fn void df_transfer_value(DfFact* gen, DfFact* kill, DfFact* input, DfFact* output, usz facts)
{
    for (usz i = 0; i < DF_MAX_WORDS; i++)
    {
        ulong valid = 0xffffffffffffffffUL;
        if (i * 64 >= facts) { valid = 0; }
        else if ((i + 1) * 64 > facts) { valid = (1UL << (facts - i * 64)) - 1UL; }
        output.bits[i] = (gen.bits[i] | (input.bits[i] & ~kill.bits[i])) & valid;
    }
    output.bottom = false;
}

fn bool df_plain_equal(DfFact* a, DfFact* b)
{
    for (usz i = 0; i < DF_MAX_WORDS; i++) if (a.bits[i] != b.bits[i]) return false;
    return true;
}

fn bool DfAnalysis.check_lattice(DfAnalysis* d)
{
    // The bitvector meet must be associative, commutative and idempotent;
    // the worklist's fixed-point proof relies on this algebra. Exercise the
    // actual operator on varied finite facts once per analysis instance.
    DfFact a; DfFact b; DfFact c; DfFact ab; DfFact ba; DfFact aa; DfFact left; DfFact right;
    df_bottom(&a); df_bottom(&b); df_bottom(&c);
    a.bottom = false; b.bottom = false; c.bottom = false;
    for (usz i = 0; i < DF_MAX_WORDS; i++)
    {
        a.bits[i] = 0xAAAAAAAAAAAAAAAAUL ^ ((ulong)i * 0x0101010101010101UL);
        b.bits[i] = 0xCCCCCCCCCCCCCCCCUL ^ ((ulong)i * 0x1111111111111111UL);
        c.bits[i] = 0xF0F00F0FF0F00F0FUL ^ ((ulong)i * 0x0011001100110011UL);
    }
    df_copy(&ab, &a); df_join(&ab, &b, d.meet);
    df_copy(&ba, &b); df_join(&ba, &a, d.meet);
    df_copy(&aa, &a); df_join(&aa, &a, d.meet);
    df_copy(&left, &ab); df_join(&left, &c, d.meet);
    df_copy(&right, &b); df_join(&right, &c, d.meet);
    DfFact right2; df_copy(&right2, &a); df_join(&right2, &right, d.meet);
    d.n_lattice_failures = 0;
    if (!df_plain_equal(&ab, &ba)) d.n_lattice_failures = d.n_lattice_failures + 1;
    if (!df_plain_equal(&aa, &a)) d.n_lattice_failures = d.n_lattice_failures + 1;
    if (!df_plain_equal(&left, &right2)) d.n_lattice_failures = d.n_lattice_failures + 1;
    // Also check transfer monotonicity: if x is below y in the selected
    // lattice order, F(x) must remain below F(y). This is the condition that
    // lets a chaotic worklist converge to the same least/greatest fixpoint.
    DfFact low; DfFact high; DfFact gen; DfFact kill; DfFact flow_low; DfFact flow_high;
    df_bottom(&low); df_bottom(&high); df_bottom(&gen); df_bottom(&kill);
    low.bottom = false; high.bottom = false; gen.bottom = false; kill.bottom = false;
    for (usz i = 0; i < DF_MAX_WORDS; i++)
    {
        ulong valid = 0xffffffffffffffffUL;
        if (i * 64 >= d.n_facts) { valid = 0; }
        else if ((i + 1) * 64 > d.n_facts) { valid = (1UL << (d.n_facts - i * 64)) - 1UL; }
        ulong pattern = 0xA55AA55AA55AA55AUL ^ (ulong)i * 0x0101010101010101UL;
        low.bits[i] = pattern & 0x3333333333333333UL & valid;
        high.bits[i] = (pattern | low.bits[i]) & valid;
        gen.bits[i] = (pattern >> 2) & valid;
        kill.bits[i] = (pattern << 3) & valid;
    }
    bool ordered = df_subset(&low, &high, d.n_facts);
    df_transfer_value(&gen, &kill, &low, &flow_low, d.n_facts);
    df_transfer_value(&gen, &kill, &high, &flow_high, d.n_facts);
    if (!ordered || !df_subset(&flow_low, &flow_high, d.n_facts))
    { d.n_lattice_failures = d.n_lattice_failures + 1; }
    d.lattice_ok = d.n_lattice_failures == 0;
    return d.lattice_ok;
}

fn void df_copy(DfFact* dst, DfFact* src)
{
    for (usz i = 0; i < DF_MAX_WORDS; i++) dst.bits[i] = src.bits[i];
    dst.bottom = src.bottom;
}

fn void df_set(DfFact* f, usz bit)
{
    usz w = bit / 64; usz b = bit % 64;
    if (w < DF_MAX_WORDS) { f.bits[w] = f.bits[w] | (1UL << b); f.bottom = false; }
}

fn void df_clear(DfFact* f, usz bit)
{
    usz w = bit / 64; usz b = bit % 64;
    if (w < DF_MAX_WORDS) { f.bits[w] = f.bits[w] & ~(1UL << b); f.bottom = false; }
}

fn bool df_get(DfFact* f, usz bit)
{
    if (f.bottom) return false;
    usz w = bit / 64; usz b = bit % 64;
    if (w >= DF_MAX_WORDS) return false;
    return (f.bits[w] & (1UL << b)) != 0;
}

fn usz df_popcount(DfFact* f)
{
    usz c = 0;
    for (usz i = 0; i < DF_MAX_WORDS; i++)
    {
        ulong w = f.bits[i];
        while (w != 0) { c = c + (usz)(w & 1); w = w >> 1; }
    }
    return c;
}

// ── A generic analysis ─────────────────────────────────────────────────
struct Transfer
{
    int kind;        // tag: which analysis we are
}

struct DfAnalysis
{
    char*       name;
    DfDirection direction;
    DfMeet      meet;
    Arena*      arena;

    DfFact*     in;      // per-block in-fact
    DfFact*     out;     // per-block out-fact
    DfFact*     gen;     // per-block GEN set
    DfFact*     kill;    // per-block KILL set

    usz         block_count;
    usz         n_iterations;
    usz         n_wl_pops;
    usz         n_added;   // bits set across all GEN
    usz         n_killed;
    usz         n_monotone_violations;
    usz         n_equation_violations;
    usz         n_wl_remaining;
    usz         n_max_wl;
    usz         n_fact_bits_in;
    usz         n_fact_bits_out;
    usz         n_lattice_failures;

    usz         n_facts;
    bool        lattice_ok;   // number of tracked bits
    bool        ready;
}

fn void DfAnalysis.init(DfAnalysis* d, char* name, DfDirection dir, DfMeet m, Arena* a)
{
    d.name = name; d.direction = dir; d.meet = m; d.arena = a;
    d.block_count = 0;
    d.n_iterations = 0; d.n_wl_pops = 0; d.n_added = 0; d.n_killed = 0;
    d.n_monotone_violations = 0; d.n_equation_violations = 0; d.n_wl_remaining = 0; d.n_max_wl = 0;
    d.n_fact_bits_in = 0; d.n_fact_bits_out = 0; d.n_lattice_failures = 0; d.lattice_ok = false;
    d.n_facts = 0;
    d.in = null; d.out = null; d.gen = null; d.kill = null;
    d.ready = false;
}

fn void DfAnalysis.alloc(DfAnalysis* d, usz blocks, usz facts)
{
    d.block_count = blocks;
    d.n_facts = facts;
    usz total = blocks;
    d.in = (DfFact*)calloc(total, DF_FACT_SZ);
    d.out = (DfFact*)calloc(total, DF_FACT_SZ);
    d.gen = (DfFact*)calloc(total, DF_FACT_SZ);
    d.kill = (DfFact*)calloc(total, DF_FACT_SZ);
    if (d.in == null || d.out == null) return;
    for (usz i = 0; i < blocks; i++)
    {
        df_bottom(&d.in[i]);
        df_bottom(&d.out[i]);
        if (d.meet == DfMeet.DF_AND)
        {
            // Must analyses solve from the greatest element downward.
            df_boundary(&d.in[i], d.meet, facts);
            df_boundary(&d.out[i], d.meet, facts);
        }
        df_bottom(&d.gen[i]);
        df_bottom(&d.kill[i]);
    }
    d.ready = true;
}

fn void DfAnalysis.mark_gen(DfAnalysis* d, usz blk, usz bit)
{
    if (!d.ready || blk >= d.block_count) return;
    if (!df_get(&d.gen[blk], bit)) { df_set(&d.gen[blk], bit); d.n_added = d.n_added + 1; }
}

fn void DfAnalysis.mark_kill(DfAnalysis* d, usz blk, usz bit)
{
    if (!d.ready || blk >= d.block_count) return;
    if (!df_get(&d.kill[blk], bit)) { df_set(&d.kill[blk], bit); d.n_killed = d.n_killed + 1; }
}

fn void DfAnalysis.clear_gen(DfAnalysis* d, usz blk, usz bit)
{
    if (!d.ready || blk >= d.block_count || bit >= d.n_facts) return;
    d.gen[blk].bits[bit / 64] = d.gen[blk].bits[bit / 64] & ~(1UL << (bit % 64));
}

// Transfer: in[b] -> out[b] = gen[b] ∪ (in[b] \ kill[b])
fn void df_transfer(DfAnalysis* d, usz blk)
{
    // All four classic bitvector problems share OUT=GEN ∪ (IN − KILL).
    // The meet (union for may, intersection for must) is selected by solve().
    df_transfer_value(&d.gen[blk], &d.kill[blk], &d.in[blk], &d.out[blk], d.n_facts);
}

// ── Fixpoint iteration via worklist ───────────────────────────────────
// For FORWARD: in[b] = meet_{p ∈ pred(b)} out[p]; start with out[entry]
// initialised to top for meet=OR (or bottom for AND), iterate until stable.
// For BACKWARD: swap in/out and successors/predecessors.
fn void DfAnalysis.solve(DfAnalysis* d, Cfg* cfg)
{
    if (!d.ready || cfg == null) return;
    usz nb = cfg.block_count;
    if (nb != d.block_count || nb == 0) return;
    usz* wl = (usz*)malloc(nb * 8);
    bool* in_wl = (bool*)calloc(nb, 1);
    if (wl == null || in_wl == null) { if (wl != null) free(wl); if (in_wl != null) free(in_wl); return; }
    usz head = 0; usz tail = 0; usz count = 0;
    for (usz i = 0; i < nb; i++) { wl[tail] = i; tail = (tail + 1) % nb; count = count + 1; in_wl[i] = true; }
    if (count > d.n_max_wl) d.n_max_wl = count;
    usz iters = 0;
    while (count > 0 && iters < (usz)DF_MAX_ITERS * (nb + 1))
    {
        usz b = wl[head]; head = (head + 1) % nb; count = count - 1; in_wl[b] = false;
        d.n_wl_pops = d.n_wl_pops + 1;
        Block* bb = &cfg.blocks[b];
        DfFact new_in;
        df_bottom(&new_in);
        bool boundary = d.direction == DfDirection.DF_FORWARD ? bb.pred_count == 0 : bb.succ_count == 0;
        if (boundary) { df_boundary(&new_in, d.meet, d.n_facts); }
        else if (d.direction == DfDirection.DF_FORWARD)
        {
            for (usz i = 0; i < bb.pred_count; i++)
            {
                int p = bb.preds[i];
                if (p >= 0 && (usz)p < nb) df_join(&new_in, &d.out[(usz)p], d.meet);
            }
        }
        else
        {
            for (usz i = 0; i < bb.succ_count; i++)
            {
                int q = bb.succs[i];
                if (q >= 0 && (usz)q < nb) df_join(&new_in, &d.out[(usz)q], d.meet);
            }
        }
        DfFact old_out; df_copy(&old_out, &d.out[b]);
        df_copy(&d.in[b], &new_in);
        df_transfer(d, b);
        if (!df_equal(&d.out[b], &old_out))
        {
            if (!old_out.bottom)
            {
                bool violation = false;
                for (usz w = 0; w < DF_MAX_WORDS; w++)
                {
                    if (d.meet == DfMeet.DF_OR && (old_out.bits[w] & ~d.out[b].bits[w]) != 0) violation = true;
                    if (d.meet == DfMeet.DF_AND && (d.out[b].bits[w] & ~old_out.bits[w]) != 0) violation = true;
                }
                if (violation) d.n_monotone_violations = d.n_monotone_violations + 1;
            }
            if (d.direction == DfDirection.DF_FORWARD)
            {
                for (usz i = 0; i < bb.succ_count; i++)
                {
                    int q = bb.succs[i];
                    if (q >= 0 && (usz)q < nb && !in_wl[(usz)q])
                    { wl[tail] = (usz)q; tail = (tail + 1) % nb; count = count + 1; in_wl[(usz)q] = true; if (count > d.n_max_wl) d.n_max_wl = count; }
                }
            }
            else
            {
                for (usz i = 0; i < bb.pred_count; i++)
                {
                    int q = bb.preds[i];
                    if (q >= 0 && (usz)q < nb && !in_wl[(usz)q])
                    { wl[tail] = (usz)q; tail = (tail + 1) % nb; count = count + 1; in_wl[(usz)q] = true; if (count > d.n_max_wl) d.n_max_wl = count; }
                }
            }
        }
        iters = iters + 1;
    }
    d.n_iterations = d.n_iterations + iters;
    d.n_wl_remaining = count;
    free(wl); free(in_wl);
}

fn void DfAnalysis.verify(DfAnalysis* d, Cfg* cfg)
{
    if (!d.ready || cfg == null || cfg.block_count != d.block_count) return;
    d.n_equation_violations = 0; d.n_fact_bits_in = 0; d.n_fact_bits_out = 0;
    for (usz b = 0; b < d.block_count; b++)
    {
        Block* bb = &cfg.blocks[b];
        d.n_fact_bits_in = d.n_fact_bits_in + df_popcount(&d.in[b]);
        d.n_fact_bits_out = d.n_fact_bits_out + df_popcount(&d.out[b]);
        Block* bb_unused = bb; (void)bb_unused;
        DfFact expected_in; df_bottom(&expected_in);
        bool boundary = d.direction == DfDirection.DF_FORWARD ? bb.pred_count == 0 : bb.succ_count == 0;
        if (boundary) { df_boundary(&expected_in, d.meet, d.n_facts); }
        else if (d.direction == DfDirection.DF_FORWARD)
        {
            for (usz i = 0; i < bb.pred_count; i++) { int p = bb.preds[i]; if (p >= 0 && (usz)p < d.block_count) df_join(&expected_in, &d.out[(usz)p], d.meet); }
        }
        else
        {
            for (usz i = 0; i < bb.succ_count; i++) { int q = bb.succs[i]; if (q >= 0 && (usz)q < d.block_count) df_join(&expected_in, &d.out[(usz)q], d.meet); }
        }
        if (!df_equal(&expected_in, &d.in[b])) d.n_equation_violations = d.n_equation_violations + 1;
        DfFact expected_out; df_bottom(&expected_out);
        for (usz w = 0; w < DF_MAX_WORDS; w++)
        {
            ulong valid = 0xffffffffffffffffUL;
            if (w * 64 >= d.n_facts) { valid = 0; }
            else if ((w + 1) * 64 > d.n_facts) { valid = (1UL << (d.n_facts - w * 64)) - 1UL; }
            expected_out.bits[w] = (d.gen[b].bits[w] | (d.in[b].bits[w] & ~d.kill[b].bits[w])) & valid;
        }
        expected_out.bottom = false;
        if (!df_equal(&expected_out, &d.out[b])) d.n_equation_violations = d.n_equation_violations + 1;
    }
}

fn void DfAnalysis.report(DfAnalysis* d)
{
    printf("  df-%-12s : %d blks, %d bits, %d wl pops, %d iters, gen=%d kill=%d\n",
           d.name != null ? d.name : "anon",
           (int)d.block_count, (int)d.n_facts, (int)d.n_wl_pops, (int)d.n_iterations,
           (int)d.n_added, (int)d.n_killed);
    printf("  df-lattice     : %s, %d law failures (meet is associative / commutative / idempotent)\n",
           d.name != null ? d.name : "anon", (int)d.n_lattice_failures);
    printf("  df-cert        : %s, monotone violations=%d, equation violations=%d, worklist remaining=%d, IN bits=%d OUT bits=%d\n",
           d.name != null ? d.name : "anon", (int)d.n_monotone_violations,
           (int)d.n_equation_violations, (int)d.n_wl_remaining, (int)d.n_fact_bits_in, (int)d.n_fact_bits_out);
}

fn void DfAnalysis.destroy(DfAnalysis* d)
{
    if (d.in != null) { free((void*)d.in); d.in = null; }
    if (d.out != null) { free((void*)d.out); d.out = null; }
    if (d.gen != null) { free((void*)d.gen); d.gen = null; }
    if (d.kill != null) { free((void*)d.kill); d.kill = null; }
    d.ready = false;
}

// ── Real AST/CFG instantiation ─────────────────────────────────────────
// Facts are definitions for reaching-defs, and pure binary/unary expressions
// for available / very-busy expressions. IDs are stable within the module.
const usz DF_MAX_DEFS = DF_MAX_WORDS * 64;
const usz DF_MAX_EXPRS = DF_MAX_WORDS * 64;
const usz DF_MAX_FNS = 4096;

struct DfDef
{
    Node* binder;
    Node* site;
    int   bit;
    int   entry_block; // non-negative for a parameter definition
}

struct DfExpr
{
    Node* node;
    int   bit;
}

struct DfFnEntry { Node* fn_node; Node* clause_node; Node* body_node; int entry_block; }

const usz DF_MAX_RUNS = 8;

struct DfBundle
{
    Arena* arena;
    DfAnalysis[DF_MAX_RUNS] runs;
    usz      n_runs;
    usz      n_cfg_seen;
    usz      n_defs;
    usz      n_exprs;
    usz      n_cfg_blocks;
    usz      n_real_edges;
    usz      n_reaching_sites;
    usz      n_vars;
    Node**   vars;
    usz      n_available_exprs;
    usz      n_vbusy_exprs;
    bool     overflow;
    DfDef*   defs;
    DfExpr*  exprs;
    DfFnEntry* fns;
    usz      n_fn_entries;
}

fn void DfBundle.init(DfBundle* b, Arena* a)
{
    b.arena = a; b.n_runs = 0; b.n_cfg_seen = 0;
    b.n_defs = 0; b.n_exprs = 0; b.n_cfg_blocks = 0; b.n_real_edges = 0;
    b.n_reaching_sites = 0; b.n_vars = 0; b.n_available_exprs = 0; b.n_vbusy_exprs = 0; b.overflow = false;
    b.vars = (Node**)calloc(DF_MAX_DEFS, (usz)8);
    b.defs = (DfDef*)calloc(DF_MAX_DEFS, DfDef::size);
    b.exprs = (DfExpr*)calloc(DF_MAX_EXPRS, DfExpr::size);
    b.fns = (DfFnEntry*)calloc(DF_MAX_FNS, DfFnEntry::size);
    b.n_fn_entries = 0;
    b.runs[b.n_runs].init("reaching", DfDirection.DF_FORWARD, DfMeet.DF_OR, a); b.n_runs = b.n_runs + 1;
    b.runs[b.n_runs].init("avail", DfDirection.DF_FORWARD, DfMeet.DF_AND, a); b.n_runs = b.n_runs + 1;
    b.runs[b.n_runs].init("vbusy", DfDirection.DF_BACKWARD, DfMeet.DF_AND, a); b.n_runs = b.n_runs + 1;
    b.runs[b.n_runs].init("live", DfDirection.DF_BACKWARD, DfMeet.DF_OR, a); b.n_runs = b.n_runs + 1;
}

fn bool pure_expr(Node* n, int depth)
{
    if (n == null || depth > 64) return false;
    switch (n.kind)
    {
        case Nk.N_EXPR_INT: case Nk.N_EXPR_BOOL: case Nk.N_EXPR_CHAR: case Nk.N_EXPR_STRING:
        case Nk.N_EXPR_IDENT: case Nk.N_EXPR_PATH: case Nk.N_EXPR_UNIT:
            return true;
        case Nk.N_EXPR_BINARY: case Nk.N_EXPR_UNARY: case Nk.N_EXPR_FIELD:
        case Nk.N_EXPR_TUPLE: case Nk.N_EXPR_CAST:
            for (usz i = 0; i < n.child_count; i++) { if (!pure_expr(n.children[i], depth + 1)) return false; }
            return true;
        default: return false;
    }
}

fn bool expr_same(Node* a, Node* b, int depth)
{
    if (a == b) return true;
    if (a == null || b == null || depth > 64 || a.kind != b.kind || a.child_count != b.child_count) return false;
    if (a.kind == Nk.N_EXPR_BINARY || a.kind == Nk.N_EXPR_UNARY)
    { if (a.p.op != b.p.op) return false; }
    if (a.kind == Nk.N_EXPR_INT || a.kind == Nk.N_EXPR_BOOL || a.kind == Nk.N_EXPR_CHAR)
    { if (a.p.ival != b.p.ival) return false; }
    if (a.kind == Nk.N_EXPR_IDENT || a.kind == Nk.N_EXPR_PATH)
    { if (a.resolved != b.resolved && (a.name_id == 0 || a.name_id != b.name_id)) return false; }
    if (a.kind == Nk.N_EXPR_FIELD && a.name_id != b.name_id) return false;
    for (usz i = 0; i < a.child_count; i++) { if (!expr_same(a.children[i], b.children[i], depth + 1)) return false; }
    return true;
}

fn bool expr_mentions(Node* expr, Node* binder, int depth)
{
    if (expr == null || binder == null || depth > 64) return false;
    if ((expr.kind == Nk.N_EXPR_IDENT || expr.kind == Nk.N_EXPR_PATH) && expr.resolved == binder) return true;
    for (usz i = 0; i < expr.child_count; i++) { if (expr_mentions(expr.children[i], binder, depth + 1)) return true; }
    return false;
}

fn int DfBundle.expr_id(DfBundle* b, Node* n)
{
    if (n == null || !pure_expr(n, 0)) return -1;
    for (usz i = 0; i < b.n_exprs; i++) { if (expr_same(b.exprs[i].node, n, 0)) return (int)i; }
    if (b.n_exprs >= DF_MAX_EXPRS) { b.overflow = true; return -1; }
    int id = (int)b.n_exprs;
    b.exprs[b.n_exprs].node = n; b.exprs[b.n_exprs].bit = id; b.n_exprs = b.n_exprs + 1;
    return id;
}

fn void DfBundle.collect_exprs(DfBundle* b, Node* n, int depth)
{
    if (n == null || depth > 128) return;
    if (n.kind == Nk.N_EXPR_BINARY || n.kind == Nk.N_EXPR_UNARY)
    {
        if (pure_expr(n, 0)) { (void)b.expr_id(n); }
    }
    for (usz i = 0; i < n.child_count; i++) b.collect_exprs(n.children[i], depth + 1);
}

fn void DfBundle.add_def(DfBundle* b, Node* binder, Node* site, int entry)
{
    if (binder == null || site == null) return;
    for (usz i = 0; i < b.n_defs; i++)
    {
        if (b.defs[i].binder == binder && b.defs[i].site == site && b.defs[i].entry_block == entry) return;
    }
    if (b.n_defs >= DF_MAX_DEFS) { b.overflow = true; return; }
    DfDef* d = &b.defs[b.n_defs]; d.binder = binder; d.site = site; d.bit = (int)b.n_defs; d.entry_block = entry;
    b.n_defs = b.n_defs + 1;
}

fn void DfBundle.add_pattern_defs(DfBundle* b, Node* pat, Node* site, int entry, int depth)
{
    if (pat == null || depth > 64) return;
    if (pat.kind == Nk.N_PAT_IDENT) { b.add_def(pat, site, entry); return; }
    for (usz i = 0; i < pat.child_count; i++) b.add_pattern_defs(pat.children[i], site, entry, depth + 1);
}

fn Node* assignment_base(Node* lhs)
{
    int guard = 0;
    while (lhs != null && guard++ < 32)
    {
        if (lhs.kind == Nk.N_EXPR_FIELD || lhs.kind == Nk.N_EXPR_INDEX || lhs.kind == Nk.N_EXPR_DEREF || lhs.kind == Nk.N_EXPR_REF)
        { lhs = lhs.child_count > 0 ? lhs.children[0] : null; continue; }
        return lhs;
    }
    return null;
}

fn void DfBundle.collect_defs(DfBundle* b, Node* n, int block_entry, int depth)
{
    if (n == null || depth > 128) return;
    if (n.kind == Nk.N_DECL_LET)
    {
        Node* pat = null;
        for (usz i = 0; i < n.child_count; i++) { if (n.children[i] != null && pfront_core::is_pattern(n.children[i].kind)) { pat = n.children[i]; break; } }
        b.add_pattern_defs(pat, n, -1, 0);
    }
    else if (n.kind == Nk.N_STMT_ASSIGN || n.kind == Nk.N_STMT_COMPOUND_ASSIGN || n.kind == Nk.N_EXPR_ASSIGN)
    {
        Node* lhs = assignment_base(n.child_count > 0 ? n.children[0] : null);
        if (lhs != null && lhs.kind == Nk.N_EXPR_IDENT && lhs.resolved != null) b.add_def(lhs.resolved, n, -1);
    }
    for (usz i = 0; i < n.child_count; i++) b.collect_defs(n.children[i], block_entry, depth + 1);
}

fn int DfBundle.def_id(DfBundle* b, Node* binder, Node* site)
{
    for (usz i = 0; i < b.n_defs; i++) { if (b.defs[i].binder == binder && b.defs[i].site == site) return (int)i; }
    return -1;
}

fn void DfBundle.collect_write_defs(DfBundle* b, Node* n, int block, DfAnalysis* r, int depth)
{
    if (n == null || depth > 128) return;
    if (n.kind == Nk.N_DECL_LET)
    {
        Node* pat = null;
        for (usz i = 0; i < n.child_count; i++) { if (n.children[i] != null && pfront_core::is_pattern(n.children[i].kind)) { pat = n.children[i]; break; } }
        b.mark_pattern_defs(pat, n, block, r, 0);
    }
    else if (n.kind == Nk.N_STMT_ASSIGN || n.kind == Nk.N_STMT_COMPOUND_ASSIGN || n.kind == Nk.N_EXPR_ASSIGN)
    {
        Node* lhs = assignment_base(n.child_count > 0 ? n.children[0] : null);
        if (lhs != null && lhs.kind == Nk.N_EXPR_IDENT && lhs.resolved != null) b.mark_def(lhs.resolved, n, block, r);
    }
    for (usz i = 0; i < n.child_count; i++) b.collect_write_defs(n.children[i], block, r, depth + 1);
}

fn void DfBundle.mark_pattern_defs(DfBundle* b, Node* pat, Node* site, int block, DfAnalysis* r, int depth)
{
    if (pat == null || depth > 64) return;
    if (pat.kind == Nk.N_PAT_IDENT) { b.mark_def(pat, site, block, r); return; }
    for (usz i = 0; i < pat.child_count; i++) b.mark_pattern_defs(pat.children[i], site, block, r, depth + 1);
}

fn void DfBundle.mark_def(DfBundle* b, Node* binder, Node* site, int block, DfAnalysis* r)
{
    int id = b.def_id(binder, site);
    if (id < 0) return;
    // KILL every definition of this binder, and GEN only the last definition
    // reached in this block (so two writes in one block do not both reach out).
    for (usz i = 0; i < b.n_defs; i++)
    {
        if (b.defs[i].binder == binder)
        {
            r.mark_kill((usz)block, i);
            r.clear_gen((usz)block, i);
        }
    }
    r.mark_gen((usz)block, (usz)id);
    b.n_reaching_sites = b.n_reaching_sites + 1;
}

fn void DfBundle.mark_expr_gen(DfBundle* b, Node* n, int block, DfAnalysis* d, int depth)
{
    if (n == null || depth > 128) return;
    if (n.kind == Nk.N_EXPR_BINARY || n.kind == Nk.N_EXPR_UNARY)
    {
        int id = b.expr_id(n);
        if (id >= 0) d.mark_gen((usz)block, (usz)id);
    }
    for (usz i = 0; i < n.child_count; i++) b.mark_expr_gen(n.children[i], block, d, depth + 1);
}

fn void DfBundle.kill_exprs_for_binder(DfBundle* b, Node* binder, int block, DfAnalysis* d)
{
    for (usz i = 0; i < b.n_exprs; i++)
    {
        if (expr_mentions(b.exprs[i].node, binder, 0))
        {
            d.mark_kill((usz)block, i);
            d.clear_gen((usz)block, i);
        }
    }
}

fn void DfBundle.mark_expr_kills_for_stmt(DfBundle* b, Node* n, int block, DfAnalysis* d, int depth)
{
    if (n == null || depth > 128) return;
    if (n.kind == Nk.N_DECL_LET)
    {
        Node* pat = null;
        for (usz i = 0; i < n.child_count; i++) { if (n.children[i] != null && pfront_core::is_pattern(n.children[i].kind)) { pat = n.children[i]; break; } }
        b.mark_pattern_kills(pat, block, d, 0);
    }
    else if (n.kind == Nk.N_STMT_ASSIGN || n.kind == Nk.N_STMT_COMPOUND_ASSIGN || n.kind == Nk.N_EXPR_ASSIGN)
    {
        Node* lhs = assignment_base(n.child_count > 0 ? n.children[0] : null);
        if (lhs != null && lhs.kind == Nk.N_EXPR_IDENT && lhs.resolved != null) b.kill_exprs_for_binder(lhs.resolved, block, d);
    }
    for (usz i = 0; i < n.child_count; i++) b.mark_expr_kills_for_stmt(n.children[i], block, d, depth + 1);
}

fn void DfBundle.mark_pattern_kills(DfBundle* b, Node* pat, int block, DfAnalysis* d, int depth)
{
    if (pat == null || depth > 64) return;
    if (pat.kind == Nk.N_PAT_IDENT) { b.kill_exprs_for_binder(pat, block, d); return; }
    for (usz i = 0; i < pat.child_count; i++) b.mark_pattern_kills(pat.children[i], block, d, depth + 1);
}

fn int DfBundle.var_id(DfBundle* b, Node* binder)
{
    if (binder == null) return -1;
    for (usz i = 0; i < b.n_vars; i++) if (b.vars[i] == binder) return (int)i;
    if (b.n_vars >= DF_MAX_DEFS) { b.overflow = true; return -1; }
    int id = (int)b.n_vars; b.vars[b.n_vars] = binder; b.n_vars = b.n_vars + 1;
    return id;
}

fn void DfBundle.note_var_read(DfBundle* b, Node* binder, int block, DfAnalysis* live)
{
    int id = b.var_id(binder);
    if (id >= 0 && !df_get(&live.kill[(usz)block], (usz)id)) live.mark_gen((usz)block, (usz)id);
}

fn void DfBundle.note_pattern_write(DfBundle* b, Node* pat, int block, DfAnalysis* live, int depth)
{
    if (pat == null || depth > 64) return;
    if (pat.kind == Nk.N_PAT_IDENT)
    {
        int id = b.var_id(pat);
        if (id >= 0) { live.mark_kill((usz)block, (usz)id); live.clear_gen((usz)block, (usz)id); }
        return;
    }
    for (usz i = 0; i < pat.child_count; i++) b.note_pattern_write(pat.children[i], block, live, depth + 1);
}

fn void DfBundle.read_expr(DfBundle* b, Node* n, int block, DfAnalysis* live, int depth)
{
    if (n == null || depth > 128) return;
    if (n.kind == Nk.N_EXPR_IDENT || n.kind == Nk.N_EXPR_PATH)
    {
        b.note_var_read(n.resolved, block, live);
        return;
    }
    if (pfront_core::is_pattern(n.kind) || pfront_core::is_type(n.kind) || n.kind == Nk.N_DECL_PARAM || n.kind == Nk.N_DECL_TYPEPARAM) return;
    for (usz i = 0; i < n.child_count; i++) b.read_expr(n.children[i], block, live, depth + 1);
}

// Transfer source statements into USE-before-DEF and DEF bitsets. For an
// assignment, RHS and (for compound updates) old LHS are uses before the new
// definition; for `let`, the initializer precedes its binders.
fn void DfBundle.live_stmt(DfBundle* b, Node* n, int block, DfAnalysis* live, int depth)
{
    if (n == null || depth > 128) return;
    if (n.kind == Nk.N_DECL_LET)
    {
        Node* pat = null; Node* init = null;
        for (usz i = 0; i < n.child_count; i++)
        {
            Node* c = n.children[i]; if (c == null) continue;
            if (pfront_core::is_pattern(c.kind) && pat == null) { pat = c; }
            else if (pfront_core::is_expr(c.kind)) { init = c; }
        }
        b.read_expr(init, block, live, 0);
        b.note_pattern_write(pat, block, live, 0);
        return;
    }
    if (n.kind == Nk.N_STMT_ASSIGN || n.kind == Nk.N_STMT_COMPOUND_ASSIGN || n.kind == Nk.N_EXPR_ASSIGN)
    {
        Node* lhs = n.child_count > 0 ? n.children[0] : null;
        Node* rhs = n.child_count > 1 ? n.children[1] : null;
        if (n.kind != Nk.N_STMT_ASSIGN) b.read_expr(lhs, block, live, 0);
        b.read_expr(rhs, block, live, 0);
        Node* base = assignment_base(lhs);
        if (base != null && base.kind == Nk.N_EXPR_IDENT && base.resolved != null)
        {
            int id = b.var_id(base.resolved);
            if (id >= 0) { live.mark_kill((usz)block, (usz)id); live.clear_gen((usz)block, (usz)id); }
        }
        return;
    }
    b.read_expr(n, block, live, 0);
}

// Gather one function clause body into an existing CFG allocation. All
// clauses become disconnected entry components, which solve() treats with
// their own boundary facts. A single allocation per module avoids the
// enormous fixed per-function CFG slabs of pfront_cfg.
fn bool cfg_append_body(Cfg* c, Node* body)
{
    if (body == null) return false;
    if (c.blocks == null && !c.allocate()) return false;
    c.loop_sp = 0;
    int entry = c.new_block();
    if (entry < 0) return false;
    if (c.entry < 0) c.entry = entry;
    c.set_cur(entry);
    c.walk(body);
    if (c.cur >= 0 && c.blocks[c.cur].term == pfront_cfg::TermKind.TERM_FALL) c.terminate(pfront_cfg::TermKind.TERM_RETURN);
    return true;
}

fn void DfBundle.collect_functions(DfBundle* b, Node* n, Cfg* cfg, int depth)
{
    if (n == null || depth > 200) return;
    if (n.kind == Nk.N_DECL_FN)
    {
        b.n_cfg_seen = b.n_cfg_seen + 1;
        for (usz i = 0; i < n.child_count; i++)
        {
            Node* c = n.children[i];
            if (c == null) continue;
            if (c.kind == Nk.N_CLAUSE)
            {
                Node* body = null;
                for (usz j = 0; j < c.child_count; j++) { if (c.children[j] != null && !pfront_core::is_pattern(c.children[j].kind)) body = c.children[j]; }
                if (body == null || b.n_fn_entries >= DF_MAX_FNS) continue;
                int entry = (int)cfg.block_count;
                if (!cfg_append_body(cfg, body)) { b.overflow = true; continue; }
                DfFnEntry* fe = &b.fns[b.n_fn_entries]; fe.fn_node = n; fe.clause_node = c; fe.body_node = body; fe.entry_block = entry;
                b.n_fn_entries = b.n_fn_entries + 1;
                for (usz j = 0; j < c.child_count; j++) { if (c.children[j] != null && pfront_core::is_pattern(c.children[j].kind)) b.add_pattern_defs(c.children[j], c, entry, 0); }
            }
            else if (c.kind == Nk.N_BLOCK)
            {
                Node* body = c;
                if (b.n_fn_entries >= DF_MAX_FNS) continue;
                int entry = (int)cfg.block_count;
                if (!cfg_append_body(cfg, body)) { b.overflow = true; continue; }
                DfFnEntry* fe = &b.fns[b.n_fn_entries]; fe.fn_node = n; fe.clause_node = null; fe.body_node = body; fe.entry_block = entry;
                b.n_fn_entries = b.n_fn_entries + 1;
                for (usz j = 0; j < n.child_count; j++) { if (n.children[j] != null && n.children[j].kind == Nk.N_DECL_PARAM) b.add_pattern_defs(n.children[j], n.children[j], entry, 0); }
            }
        }
        return;
    }
    for (usz i = 0; i < n.child_count; i++) b.collect_functions(n.children[i], cfg, depth + 1);
}

fn void destroy_cfg(Cfg* c)
{
    if (c.blocks != null)
    {
        for (usz i = 0; i < c.block_count; i++)
        {
            if (c.blocks[i].stmts != null) { free((void*)c.blocks[i].stmts); c.blocks[i].stmts = null; }
            if (c.blocks[i].dom_children != null) { free((void*)c.blocks[i].dom_children); c.blocks[i].dom_children = null; }
        }
        free((void*)c.blocks); c.blocks = null;
    }
    if (c.loops != null)
    {
        for (usz i = 0; i < c.loop_count; i++)
        {
            if (c.loops[i].blocks != null) free((void*)c.loops[i].blocks);
            if (c.loops[i].exiting != null) free((void*)c.loops[i].exiting);
            if (c.loops[i].exit_blocks != null) free((void*)c.loops[i].exit_blocks);
        }
        free((void*)c.loops); c.loops = null;
    }
    if (c.loop_stack != null) { free((void*)c.loop_stack); c.loop_stack = null; }
    if (c.break_to != null) { free((void*)c.break_to); c.break_to = null; }
    if (c.cont_to != null) { free((void*)c.cont_to); c.cont_to = null; }
}

fn void DfBundle.scan(DfBundle* b, Node* root, int depth)
{
    (void)depth;
    if (root == null) return;
    Cfg cfg; cfg.init(b.arena);
    b.collect_functions(root, &cfg, 0);
    if (cfg.block_count == 0) { destroy_cfg(&cfg); return; }
    b.n_cfg_blocks = cfg.block_count;
    for (usz i = 0; i < cfg.block_count; i++) b.n_real_edges = b.n_real_edges + cfg.blocks[i].succ_count;

    // Build the finite universes before allocating any analysis bitvectors.
    for (usz i = 0; i < cfg.block_count; i++)
    {
        Block* bl = &cfg.blocks[i];
        for (usz j = 0; j < bl.stmt_count; j++)
        {
            Node* st = bl.stmts[j];
            b.collect_defs(st, (int)i, 0);
            b.collect_exprs(st, 0);
        }
        if (bl.term_node != null) { b.collect_defs(bl.term_node, (int)i, 0); b.collect_exprs(bl.term_node, 0); }
    }
    for (usz fi = 0; fi < b.n_fn_entries; fi++)
    {
        DfFnEntry* fe = &b.fns[fi];
        // param definitions are already present; assign their bits to entry block
        for (usz i = 0; i < b.n_defs; i++) { if (b.defs[i].entry_block == fe.entry_block) b.defs[i].site = fe.clause_node != null ? fe.clause_node : fe.fn_node; }
    }
    if (b.n_defs > DF_MAX_DEFS || b.n_exprs > DF_MAX_EXPRS) b.overflow = true;

    for (usz d = 0; d < b.n_defs; d++) (void)b.var_id(b.defs[d].binder);
    b.runs[0].alloc(cfg.block_count, b.n_defs);
    b.runs[1].alloc(cfg.block_count, b.n_exprs);
    b.runs[2].alloc(cfg.block_count, b.n_exprs);
    b.runs[3].alloc(cfg.block_count, b.n_vars);
    // Per block, construct KILL plus path-order-aware GEN sets.
    for (usz bi = 0; bi < cfg.block_count; bi++)
    {
        Block* bl = &cfg.blocks[bi];
        DfAnalysis* reach = &b.runs[0]; DfAnalysis* avail = &b.runs[1]; DfAnalysis* busy = &b.runs[2];
        // Function parameters: definitions at each component entry.
        for (usz d = 0; d < b.n_defs; d++)
        {
            if (b.defs[d].entry_block == (int)bi)
            {
                for (usz q = 0; q < b.n_defs; q++) if (b.defs[q].binder == b.defs[d].binder) reach.mark_kill(bi, q);
                reach.mark_gen(bi, d);
            }
        }
        for (usz si = 0; si < bl.stmt_count; si++)
        {
            Node* st = bl.stmts[si];
            b.mark_expr_gen(st, (int)bi, avail, 0);
            b.collect_write_defs(st, (int)bi, reach, 0);
            b.mark_expr_kills_for_stmt(st, (int)bi, avail, 0);
        }
        if (bl.term_node != null)
        {
            b.mark_expr_gen(bl.term_node, (int)bi, avail, 0);
            b.mark_expr_gen(bl.term_node, (int)bi, busy, 0);
        }
        // Very-busy expressions: walk the block backwards, killing at each
        // write, then generating expressions evaluated before that write.
        for (usz si = bl.stmt_count; si > 0; si--)
        {
            Node* st = bl.stmts[si - 1];
            b.mark_expr_kills_for_stmt(st, (int)bi, busy, 0);
            b.mark_expr_gen(st, (int)bi, busy, 0);
        }
        // Liveness is a fourth, independent backward-may problem. Process
        // statements in execution order so USE contains only uses before the
        // first definition in this block; the solver propagates through the
        // real predecessor/successor graph.
        DfAnalysis* live = &b.runs[3];
        for (usz si = 0; si < bl.stmt_count; si++) b.live_stmt(bl.stmts[si], (int)bi, live, 0);
        if (bl.term_node != null) b.read_expr(bl.term_node, (int)bi, live, 0);
        // Component-entry parameters are definitions before body execution.
        for (usz d = 0; d < b.n_defs; d++)
        {
            if (b.defs[d].entry_block == (int)bi)
            {
                int id = b.var_id(b.defs[d].binder);
                if (id >= 0) { live.mark_kill(bi, (usz)id); live.clear_gen(bi, (usz)id); }
            }
        }
        // KILL for available/busy is the full expression set invalidated by
        // any assignment in this block; GEN takes precedence if recomputed.
        for (usz d = 0; d < b.n_defs; d++)
        {
            if (b.defs[d].entry_block == (int)bi)
            {
                b.kill_exprs_for_binder(b.defs[d].binder, (int)bi, avail);
                b.kill_exprs_for_binder(b.defs[d].binder, (int)bi, busy);
            }
        }
    }
    for (usz k = 0; k < b.n_runs; k++)
    {
        (void)b.runs[k].check_lattice();
        b.runs[k].solve(&cfg);
        b.runs[k].verify(&cfg);
    }
    b.n_available_exprs = b.n_exprs;
    b.n_vbusy_exprs = b.n_exprs;
    destroy_cfg(&cfg);
}

fn void DfBundle.report(DfBundle* b)
{
    for (usz i = 0; i < b.n_runs; i++) b.runs[i].report();
    printf("  df-bundle        : %d functions, %d real CFG blocks / %d edges, %d reaching-def writes, %d defs, %d vars, %d pure exprs (%s)\n",
           (int)b.n_cfg_seen, (int)b.n_cfg_blocks, (int)b.n_real_edges, (int)b.n_reaching_sites,
           (int)b.n_defs, (int)b.n_vars, (int)b.n_exprs, b.overflow ? "capacity reached; partial" : "complete");
}

fn void DfBundle.destroy(DfBundle* b)
{
    for (usz i = 0; i < b.n_runs; i++) b.runs[i].destroy();
    if (b.defs != null) { free((void*)b.defs); b.defs = null; }
    if (b.exprs != null) { free((void*)b.exprs); b.exprs = null; }
    if (b.fns != null) { free((void*)b.fns); b.fns = null; }
    if (b.vars != null) { free((void*)b.vars); b.vars = null; }
}
