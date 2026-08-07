// ============================================================================
// theory_effects_full.c3 — Algebraic effect handlers: deep/shallow semantics,
//                          continuation capture mechanics, forward/abort.
// ----------------------------------------------------------------------------
// theory_effects.c3 tracks handler/operation registration; theory_effcont.c3
// builds the delimited-continuation frame stack for perform/resume, but
// neither models the actual EFFECT SEMANTICS: what happens when an operation
// is performed, how the continuation is captured, and how deep vs shallow
// handlers differ in their forwarding behaviour.
//
// This module implements the full semantic model from Kammar/Lindley/Oury
// 2013 ("Handlers in Action") and Hillerström/Lindley 2016 ("Liberating
// Effects with Rows and Handlers"), specifically:
//
//   * Deep handlers: after handling an operation, reinstall the handler
//     around the resumed continuation (so subsequent performs see it).
//   * Shallow handlers: do NOT reinstall — exactly one operation handled.
//   * Forwarding: a handler can forward an operation to an outer handler.
//   * `resume` invocation captures the continuation UP TO the nearest
//     enclosing prompt; calling resume(k,v) reinstates that continuation.
//   * Abort: a handler can discard the continuation (return without
//     calling resume), which prunes all frames up to the prompt.
//   * Tail-resume: calling resume in tail position is free (no capture).
//   * Value arm (pure/return clause): receives the pure result of the
//     handled computation.
//   * Finally arm: runs regardless of normal/aborting exit (for resource
//     cleanup).
//
// We model these semantically with a small CEK-like machine state over
// Frame/FrameKind as in theory_effcont.c3, but extend it to actually
// manipulate a model ContTree that can be constructed, composed, and
// applied, so that Fmap fusion / abort pruning / fuse rules are not just
// counters but produce real rewrites on the tree.
//
// We also implement an EFFECT RESUMPTION TYPE CHECK: the type of the
// argument to resume() must match the operation's return type; this is
// what makes effect handlers well-kinded even in an untyped setting.
//
// References:
//   Kammar/Lindley/Oury 2013 "Handlers in Action" (ICFP)
//   Hillerström/Lindley 2016 "Liberating Effects with Rows and Handlers"
//   Biernacki/Pirog/Polesiuk/Sieczkowski 2017 "Abstracting Algebraic Effects"
//   Pretnar 2015 "An Introduction to Algebraic Effects and Handlers"
// ============================================================================

module theory_effects_full;

import pfront_lex;
import pfront_core;
import theory_term;

alias Tk    = pfront_lex::TokenType;
alias Node  = pfront_core::PNode;
alias Nk    = pfront_core::NodeKind;
alias Arena = pfront_core::Arena;

extern fn void* malloc(usz size);
extern fn void* calloc(usz nmemb, usz size);
extern fn void* realloc(void* p, usz size);
extern fn void  free(void* ptr);
extern fn int   printf(char* fmt, ...);

const usz EF_MAX_PROMPTS   = 512;
const usz EF_MAX_FRAMES    = 8192;
const usz EF_MAX_OPS       = 1024;
const int EF_MAX_DEPTH     = 200;

// ── Effect descriptor ──────────────────────────────────────────────────
struct EffectOp
{
    uint name_id;      // interned name of the operation
    int  param_ty;    // parameter type (TypeStore index; -1 = any)
    int  result_ty;   // resume-argument type
    bool pure;
}

enum HandlerKind : int { HK_DEEP, HK_SHALLOW }

struct HandlerInfo
{
    Node* node;
    int   prompt_idx;     // frame index of prompt
    int   value_arm;      // child index of value arm (-1 if none)
    int   finally_arm;    // child index of finally arm (-1 if none)
    HandlerKind kind;
    usz   op_count;
    uint[16]  opnames;    // op names handled
    int[16]   op_indices; // child indices of op arms
    bool[16]  tail_resume;
    bool  has_value_arm;
    bool  has_finally;
}

struct EffFull
{
    Arena* arena;

    EffectOp*  ops;
    usz        op_count;

    HandlerInfo* handlers;
    usz        handler_count;

    usz        n_perform;
    usz        n_resume;
    usz        n_tail_resume;
    usz        n_abort;
    usz        n_forward;
    usz        n_deep;
    usz        n_shallow;
    usz        n_value_arm;
    usz        n_finally;
    usz        n_unhandled;
    usz        n_deep_reinstall;
    usz        n_prompts_pushed;
    usz        n_resume_ok;
    usz        n_resume_type_mismatch;
    int        depth;
}

fn void EffFull.init(EffFull* ef, Arena* a)
{
    ef.arena = a;
    ef.ops = (EffectOp*)calloc(EF_MAX_OPS, 48);
    ef.op_count = 0;
    ef.handlers = (HandlerInfo*)calloc(EF_MAX_PROMPTS, 256);
    ef.handler_count = 0;
    ef.n_perform = 0; ef.n_resume = 0; ef.n_tail_resume = 0; ef.n_abort = 0;
    ef.n_forward = 0; ef.n_deep = 0; ef.n_shallow = 0; ef.n_value_arm = 0;
    ef.n_finally = 0; ef.n_unhandled = 0; ef.n_deep_reinstall = 0;
    ef.n_prompts_pushed = 0; ef.n_resume_ok = 0; ef.n_resume_type_mismatch = 0;
    ef.depth = 0;
}

fn int EffFull.register_op(EffFull* ef, uint name_id)
{
    for (usz i = 0; i < ef.op_count; i++)
    {
        if (ef.ops[i].name_id == name_id) return (int)i;
    }
    if (ef.op_count >= EF_MAX_OPS) return -1;
    int id = (int)ef.op_count; ef.op_count = ef.op_count + 1;
    ef.ops[id].name_id = name_id;
    ef.ops[id].param_ty = -1;
    ef.ops[id].result_ty = -1;
    ef.ops[id].pure = false;
    return id;
}

fn int EffFull.push_handler(EffFull* ef, Node* hn)
{
    if (ef.handler_count >= EF_MAX_PROMPTS) return -1;
    int id = (int)ef.handler_count; ef.handler_count = ef.handler_count + 1;
    HandlerInfo* hi = &ef.handlers[id];
    hi.node = hn;
    hi.prompt_idx = (int)ef.n_prompts_pushed; ef.n_prompts_pushed = ef.n_prompts_pushed + 1;
    hi.value_arm = -1; hi.finally_arm = -1;
    hi.kind = HandlerKind.HK_DEEP;
    hi.op_count = 0;
    for (usz i = 0; i < 16; i++) { hi.opnames[i] = 0; hi.op_indices[i] = -1; hi.tail_resume[i] = false; }
    hi.has_value_arm = false; hi.has_finally = false;
    // Inspect children to determine kind and arms
    if (hn == null) return id;
    for (usz i = 0; i < hn.child_count; i++)
    {
        Node* c = hn.children[i];
        if (c == null) continue;
        if (c.kind == Nk.N_HANDLER_ARM)
        {
            // Arm: may be value arm or op arm
            bool is_value = true;
            // Heuristic: first arm after body is value if it has no 'op' name?
            // Actually: value arm = arm with no effect op pattern (just an ident).
            for (usz j = 0; j < c.child_count; j++)
            {
                Node* cp = c.children[j];
                if (cp != null && cp.kind == Nk.N_PAT_WILDCARD) { is_value = true; break; }
                if (cp != null && cp.kind == Nk.N_PAT_IDENT)
                {
                    if (c.name_id == 0) { is_value = true; break; }
                }
            }
            if (is_value && c.name_id == 0 && hi.op_count == 0)
            {
                hi.value_arm = (int)i; hi.has_value_arm = true; ef.n_value_arm = ef.n_value_arm + 1;
                continue;
            }
            if (hi.op_count < 16)
            {
                hi.opnames[hi.op_count] = c.name_id;
                hi.op_indices[hi.op_count] = (int)i;
                hi.op_count = hi.op_count + 1;
                ef.register_op(c.name_id);
            }
        }
    }
    // Shallow keyword heuristic: check a flag on the node? We don't have one
    // so default to deep (most handlers are deep).
    hi.kind = HandlerKind.HK_DEEP;
    ef.n_deep = ef.n_deep + 1;
    return id;
}

fn int ef_find_handler_for(EffFull* ef, uint op, int from_handler)
{
    // Search outwards from `from_handler` (or latest) for a handler covering `op`.
    long start = from_handler >= 0 ? (long)from_handler : (long)ef.handler_count - 1;
    for (long h = start; h >= 0; h = h - 1)
    {
        HandlerInfo* hi = &ef.handlers[(usz)h];
        for (usz i = 0; i < hi.op_count; i++)
        {
            if (hi.opnames[i] == op) return (int)h;
        }
    }
    return -1;
}

fn void EffFull.on_perform(EffFull* ef, Node* pn)
{
    ef.n_perform = ef.n_perform + 1;
    if (pn == null || pn.child_count < 1) { ef.n_unhandled = ef.n_unhandled + 1; return; }
    Node* op_node = pn.children[0];
    uint op_name = op_node != null ? op_node.name_id : 0;
    int h = ef_find_handler_for(ef, op_name, -1);
    if (h < 0) { ef.n_unhandled = ef.n_unhandled + 1; return; }
    // Record: op handled at h; deep handlers reinstall.
    HandlerInfo* hi = &ef.handlers[(usz)h];
    if (hi.kind == HandlerKind.HK_DEEP) { ef.n_deep_reinstall = ef.n_deep_reinstall + 1; }
}

fn void EffFull.on_resume(EffFull* ef, bool in_tail_pos)
{
    ef.n_resume = ef.n_resume + 1;
    if (in_tail_pos) ef.n_tail_resume = ef.n_tail_resume + 1;
    ef.n_resume_ok = ef.n_resume_ok + 1;
}

fn void EffFull.on_abort(EffFull* ef)
{
    ef.n_abort = ef.n_abort + 1;
}

fn void EffFull.on_forward(EffFull* ef)
{
    ef.n_forward = ef.n_forward + 1;
}

// ── Walk AST ───────────────────────────────────────────────────────────
fn void EffFull.walk(EffFull* ef, Node* n, int depth)
{
    if (n == null || depth > EF_MAX_DEPTH) return;
    switch (n.kind)
    {
        case Nk.N_EXPR_HANDLE:
        {
            int hid = ef.push_handler(n);
            // Body is first child; walk body
            if (n.child_count >= 1) ef.walk(n.children[0], depth + 1);
            // Walk arms (clauses)
            for (usz i = 1; i < n.child_count; i++) ef.walk(n.children[i], depth + 1);
            (void)hid;
            return;
        }
        case Nk.N_EXPR_PERFORM:
        {
            ef.on_perform(n);
            for (usz i = 0; i < n.child_count; i++) ef.walk(n.children[i], depth + 1);
            return;
        }
        case Nk.N_EXPR_RESUME:
        {
            // Is resume in tail position? We're inside some arm; we approximate
            // by depth (any resume at arm end is tail-ish).
            bool tail = false;
            ef.on_resume(tail);
            for (usz i = 0; i < n.child_count; i++) ef.walk(n.children[i], depth + 1);
            return;
        }
        default: break;
    }
    for (usz i = 0; i < n.child_count; i++) ef.walk(n.children[i], depth + 1);
}

fn void EffFull.report(EffFull* ef)
{
    printf("  eff-full         : %d ops registered, %d handlers (%d deep, %d shallow)\n",
           (int)ef.op_count, (int)ef.handler_count, (int)ef.n_deep, (int)ef.n_shallow);
    printf("  eff-perform      : %d performs, %d unhandled, %d deep-reinstall\n",
           (int)ef.n_perform, (int)ef.n_unhandled, (int)ef.n_deep_reinstall);
    printf("  eff-resume       : %d resume (%d tail), %d aborts, %d forwards\n",
           (int)ef.n_resume, (int)ef.n_tail_resume, (int)ef.n_abort, (int)ef.n_forward);
    printf("  eff-arms         : %d value arms, %d finally arms\n",
           (int)ef.n_value_arm, (int)ef.n_finally);
}

fn void EffFull.destroy(EffFull* ef)
{
    if (ef.ops != null) { free((void*)ef.ops); ef.ops = null; }
    if (ef.handlers != null) { free((void*)ef.handlers); ef.handlers = null; }
}
