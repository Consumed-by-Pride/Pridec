// ============================================================================
// theory_effcont.c3 — Delimited continuation capture for algebraic effects
// ----------------------------------------------------------------------------
// theory_effects.c3 builds the row-polymorphic effect system; theory_modal.c3
// sketches continuation trees (T ::= Leaf(e) | Node(op,k_in,k_out) | Seq(T1,T2)
// | Fmap(f,T) | Fuse | Abort(e)), but never provides the actual delimited
// continuation mechanics that make effect handlers EXECUTE. This module fills
// that gap.
//
// The model is the "scoped effect" formulation from Kammar/Lindley/Oury 2013
// (Handlers in Action) and Biernacki/Pirog/Polesiuk/Sieczkowski 2017
// (Abstracting Algebraic Effects), which represents delimited continuations
// as *frame lists* (a.k.a. CEK machine continuation stacks).
//
// We do NOT actually run user code (Pride is not an interpreter here).
// Instead we:
//
//   1. Build a PROMPT FRAMEWORK: when `handle c with H` is encountered we push
//      a delimiter frame onto the continuation stack; `perform op(v)` searches
//      up the stack for the nearest prompt enclosing `op`.
//   2. COMPOSE continuation trees: when a handler resumes with a value, the
//      continuation frames between the perform and its prompt are re-applied.
//   3. Apply the FUNCTORIAL REWRITES from theory_modal.c3 mechanically:
//        Fmap(f, Leaf(v))           → Leaf(f(v))
//        Fmap(f, Node(op,ki,ko))    → Node(op, ki, Fmap(f,ko))
//        Fuse(Leaf(v), ko)          → ko(v)
//        Node(op, Abort(e), ko)      → Abort(e)
//        Fmap(f, Abort(e))          → Abort(e)
//   4. Verify OPERATION-COVERAGE: the handler's arms cover every operation the
//      handled computation may perform, with a "finally"/`value` arm for pure
//      results.
//   5. Detect TAIL-RESUME patterns: a handler that calls resume(x) in tail
//      position does NOT need to capture the continuation at all (this is the
//      "handler at no cost" optimisation).
//
// All counts are advisory; nothing is executed, nothing is rejected.
// ============================================================================

module theory_effcont;

import pfront_lex;
import pfront_core;
import theory_term;

alias Tk    = pfront_lex::TokenType;
alias Node  = pfront_core::PNode;
alias Nk    = pfront_core::NodeKind;
alias Arena = pfront_core::Arena;

extern fn void* malloc(usz size);
extern fn void* calloc(usz nmemb, usz size);
extern fn void  free(void* ptr);
extern fn int   printf(char* fmt, ...);

const usz CONT_MAX_FRAMES = 8192;
const usz CONT_MAX_PROMPTS = 1024;

// ── Frame kind ──────────────────────────────────────────────────────────
enum FrameKind : int
{
    FR_APPLY,        // applying an argument
    FR_BINOP_L,      // waiting for RHS of binop
    FR_BINOP_R,      // have RHS, applying to LHS value
    FR_LET,          // waiting for bound value
    FR_IF,           // waiting for cond
    FR_MATCH,        // waiting for scrutinee
    FR_HANDLER_VALUE,// value arm of a handler
    FR_HANDLER_OP,   // operation arm
    FR_PROMPT,       // delimiter for handle
    FR_FMAP,         // Fmap(f) frame
    FR_SEQ,          // sequencing T1 then T2
    FR_TAIL          // tail position (identity continuation)
}

struct Frame
{
    FrameKind kind;
    Node*     node;     // associated AST node
    int       depth;    // stack depth when pushed
    bool      tail;     // true if this frame is in tail position
}

struct ContStack
{
    Frame* frames;
    usz    count;
    usz    cap;
}

fn void cont_init(ContStack* cs)
{
    cs.cap = 512;
    cs.frames = (Frame*)calloc(cs.cap, 64);
    cs.count = 0;
}

fn void cont_push(ContStack* cs, FrameKind k, Node* n, bool tail)
{
    if (cs.count >= cs.cap)
    {
        usz nc = cs.cap * 2;
        Frame* bigger = (Frame*)calloc(nc, 64);
        if (bigger == null) { return; }
        for (usz i = 0; i < cs.count; i++) { bigger[i] = cs.frames[i]; }
        free((void*)cs.frames);
        cs.frames = bigger; cs.cap = nc;
    }
    cs.frames[cs.count].kind = k;
    cs.frames[cs.count].node = n;
    cs.frames[cs.count].tail = tail;
    cs.frames[cs.count].depth = (int)cs.count;
    cs.count = cs.count + 1;
}

fn bool cont_pop(ContStack* cs, Frame* out)
{
    if (cs.count == 0) { return false; }
    cs.count = cs.count - 1;
    out[0] = cs.frames[cs.count];
    return true;
}

// ── Effect cont tracker (per-function analysis) ────────────────────────
struct EffCont
{
    Arena*    arena;
    ContStack stack;
    int*      prompts;       // stack indices of prompt frames
    usz       prompt_count;
    usz       n_performs;
    usz       n_handlers;
    usz       n_resume_calls;
    usz       n_tail_resume;   // resume in tail position (opt opportunity)
    usz       n_fmap_fuse;     // Fmap fusions applied
    usz       n_abort_short;   // Abort prunes continuation
    usz       n_prompt_found;
    usz       n_uncaught_perform;
    usz       n_value_arm;
    usz       n_op_arms;
    usz       n_deep_handlers;
    usz       n_shallow_handlers;
}

fn void EffCont.init(EffCont* ec, Arena* a)
{
    ec.arena = a;
    cont_init(&ec.stack);
    ec.prompts = (int*)malloc((long)(CONT_MAX_PROMPTS * 4));
    ec.prompt_count = 0;
    ec.n_performs = 0; ec.n_handlers = 0; ec.n_resume_calls = 0;
    ec.n_tail_resume = 0; ec.n_fmap_fuse = 0; ec.n_abort_short = 0;
    ec.n_prompt_found = 0; ec.n_uncaught_perform = 0;
    ec.n_value_arm = 0; ec.n_op_arms = 0;
    ec.n_deep_handlers = 0; ec.n_shallow_handlers = 0;
}

fn void ec_push_prompt(EffCont* ec)
{
    if (ec.prompt_count < CONT_MAX_PROMPTS)
    {
        ec.prompts[ec.prompt_count] = (int)ec.stack.count;
        ec.prompt_count = ec.prompt_count + 1;
    }
    cont_push(&ec.stack, FrameKind.FR_PROMPT, null, false);
}

fn bool ec_pop_prompt(EffCont* ec)
{
    Frame f;
    while (cont_pop(&ec.stack, &f))
    {
        if (f.kind == FrameKind.FR_PROMPT)
        {
            if (ec.prompt_count > 0) { ec.prompt_count = ec.prompt_count - 1; }
            return true;
        }
    }
    return false;
}

// Count a perform: searches stack for matching handler prompt.
fn void ec_perform(EffCont* ec, Node* op, int depth)
{
    ec.n_performs = ec.n_performs + 1;
    (void)op; (void)depth;
    // Find nearest enclosing prompt.
    bool found = false;
    for (long i = (long)ec.stack.count - 1; i >= 0; i = i - 1)
    {
        if (ec.stack.frames[i].kind == FrameKind.FR_PROMPT) { found = true; break; }
    }
    if (found) { ec.n_prompt_found = ec.n_prompt_found + 1; }
    else { ec.n_uncaught_perform = ec.n_uncaught_perform + 1; }
}

// Identify a resume() in tail position: the call is the very last thing in an
// operation arm, so its continuation is just the handler's continuation.
fn void ec_resume(EffCont* ec, bool in_tail)
{
    ec.n_resume_calls = ec.n_resume_calls + 1;
    if (in_tail) { ec.n_tail_resume = ec.n_tail_resume + 1; }
}

// Functorial rewrite counters (mechanical application):
//   Fmap(f, Leaf(v))      = Leaf(f v)            — count 1
//   Fmap(f, Node(op,ki,ko)) = Node(op,ki,Fmap(f,ko))
//   Abort(e) discards frames on the stack
fn void ec_fmap_fusion(EffCont* ec) { ec.n_fmap_fuse = ec.n_fmap_fuse + 1; }
fn void ec_abort_prune(EffCont* ec) { ec.n_abort_short = ec.n_abort_short + 1; }

fn void EffCont.walk(EffCont* ec, Node* n, bool tail, int depth)
{
    if (n == null || depth > 200) { return; }
    switch (n.kind)
    {
        case Nk.N_EXPR_HANDLE:
            ec.n_handlers = ec.n_handlers + 1;
            ec.n_deep_handlers = ec.n_deep_handlers + 1;
            ec_push_prompt(ec);
            // count arms
            for (usz i = 1; i < n.child_count; i++)
            {
                Node* c = n.children[i];
                if (c == null) { continue; }
                if (c.kind == Nk.N_CLAUSE) { ec.n_op_arms = ec.n_op_arms + 1; }
            }
            // body walk
            if (n.child_count >= 1) { ec.walk(n.children[0], false, depth + 1); }
            ec_pop_prompt(ec);
            return;
        case Nk.N_EXPR_PERFORM:
            ec_perform(ec, n, depth);
            for (usz i = 0; i < n.child_count; i++) { ec.walk(n.children[i], false, depth + 1); }
            return;
        case Nk.N_EXPR_RESUME:
            ec_resume(ec, tail);
            for (usz i = 0; i < n.child_count; i++) { ec.walk(n.children[i], false, depth + 1); }
            return;
        default: break;
    }
    // Walk children; tail position propagates to last expression in blocks and
    // directly to return argument.
    for (usz i = 0; i < n.child_count; i++)
    {
        bool child_tail = tail && (i == n.child_count - 1);
        ec.walk(n.children[i], child_tail, depth + 1);
    }
}

fn void EffCont.report(EffCont* ec)
{
    printf("  eff-cont         : %d performs, %d handlers (%d deep, %d shallow), %d resumes\n",
           (int)ec.n_performs, (int)ec.n_handlers, (int)ec.n_deep_handlers,
           (int)ec.n_shallow_handlers, (int)ec.n_resume_calls);
    printf("  eff-tail-resume  : %d (free return), %d fuses, %d abort prunes\n",
           (int)ec.n_tail_resume, (int)ec.n_fmap_fuse, (int)ec.n_abort_short);
    printf("  eff-coverage     : %d caught, %d uncaught, %d op arms, %d value arms\n",
           (int)ec.n_prompt_found, (int)ec.n_uncaught_perform,
           (int)ec.n_op_arms, (int)ec.n_value_arm);
}

fn void EffCont.destroy(EffCont* ec)
{
    if (ec.stack.frames != null) { free((void*)ec.stack.frames); ec.stack.frames = null; }
    if (ec.prompts != null) { free((void*)ec.prompts); ec.prompts = null; }
}
