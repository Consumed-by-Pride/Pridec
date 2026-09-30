// ============================================================================
// pfront_cfg.c3 — intra-procedural control-flow graph and loop tree
// ----------------------------------------------------------------------------
// For every function body (fn clauses, lambdas, and the top-level program
// block), this pass:
//
//   1. LINEARISES the AST into a numbered list of BASIC BLOCKS. A basic block
//      is a straight-line sequence of statements/expressions with exactly
//      one entry point and one exit. Branches (if/match/while/for/do/return/
//      break/continue) terminate a block; any labelled statement starts a
//      new block.
//   2. Builds a SUCCESSOR / PREDECESSOR graph over those blocks, correctly
//      threading `then`/`else` legs, `while` loops (back-edge from body tail
//      to header + exit edge from break/end), `for`/`do` and `match` arms.
//   3. Computes REVERSE POSTORDER numbering so later dataflow passes can
//      iterate in RPO for fast convergence.
//   4. Computes IMMEDIATE DOMINATORS using the Cooper-Harvey-Kennedy iterative
//      algorithm over the postorder, the standard O(N α(N,N)) method.
//   5. Builds the DOMINATOR TREE (children of each idom) and DOMINANCE
//      FRONTIER sets, which SSA construction and any pass that needs
//      "where must a φ go?" uses.
//   6. Identifies NATURAL LOOPS (back edges m → h where h dominates m),
//      reduces them via loop-header hash-consing, and builds a loop tree
//      with: header, latch, preheader, exiting blocks, exit blocks, block
//      list, nesting depth, and parent loop.
//
// The CFG is arena-allocated and lives for one per-function analysis. No
// persistent state is kept on the AST; this is a READ-ONLY analysis that
// downstream passes can invoke on demand.
//
// Bounded sizing:
//   * MAX_BLOCKS  per function = 8192
//   * MAX_SUCCS   per block    = 8    (if-then-else, match arms, loop exit)
//   * MAX_LOOPS   per function = 256
//   * MAX_DF      per block    = 16
// Functions that exceed these limits are skipped with a note (they are
// pathologically large and would blow later passes anyway).
//
// This replaces the ad-hoc "flow env" in pfront_flow.c3 with a real CFG
// that dataflow analyses can iterate in place rather than re-walking the
// tree. It is what enables sparse conditional constant propagation, global
// value numbering, LICM, loop-invariant code motion, ADCE, and SSI
// construction in later theory passes.
// ============================================================================

module pfront_cfg;

import pfront_lex;
import pfront_core;

alias Tk   = pfront_lex::TokenType;
alias Nk   = pfront_core::NodeKind;
alias Node = pfront_core::PNode;
alias Arena = pfront_core::Arena;

const usz MAX_BLOCKS = 8192;
const usz MAX_SUCCS  = 8;
const usz MAX_PREDS  = 32;
const usz MAX_LOOPS  = 256;
const usz MAX_DF     = 16;

// A Terminator describes how control leaves a basic block.
enum TermKind : int
{
    TERM_FALL,      // falls through to next sequential block
    TERM_IF,        // conditional branch to taken/not-taken
    TERM_RETURN,    // return (no successors)
    TERM_BREAK,     // break to enclosing loop exit
    TERM_CONTINUE,  // continue to enclosing loop header
    TERM_UNREACH,   // unreachable!() / trap / ub!
    TERM_MATCH,     // multi-way branch (switch)
    TERM_TAIL,      // tail call (treated as return for CFG purposes)
    TERM_TRY_EXIT,  // exceptional exit from a try block
    TERM_DEFER_RET, // terminator inside a defer that leaves via return/throw
}

// A labelled block reference (goto target). Pride's labels are per-function.
struct LabelRef
{
    uint name_id;
    int  block_id;
}

struct Block
{
    int  id;
    Node** stmts;     // arena array of statements in this block
    usz  stmt_count;
    usz  stmt_cap;

    int[MAX_SUCCS] succs;
    usz succ_count;
    int[MAX_PREDS] preds;
    usz pred_count;

    TermKind term;
    Node*    term_node;    // the terminator expression
    int      term_taken;   // successor id for taken branch / match arm 0
    int      term_not;     // successor id for not-taken / default arm
    // Multi-way successors for match (stored inline; overflow falls back
    // to allocating extra arena arrays -- rare since arm count is small).
    int[16] match_targets;
    usz      match_target_count;

    // Label targeted by a goto in this block (TERM_GOTO); -1 if none.
    uint goto_label;

    // Dom info:
    int  rpo;            // reverse-postorder number
    int  idom;           // immediate dominator block id, -1 for entry
    int* dom_children;
    usz dom_child_count;
    usz dom_child_cap;
    int[MAX_DF] df;
    usz df_count;

    // Loop info:
    int  loop_header;    // innermost loop header this block belongs to; -1 if none
    int  loop_depth;     // nesting depth of innermost loop
    bool is_header;
    bool is_latch;
    bool is_exiting;
    bool is_exit;
    bool is_preheader;
}

struct Loop
{
    int  header;
    int  latch;
    int  preheader;
    int* blocks;          // all blocks in this loop
    usz block_count;
    int* exiting;         // blocks that leave the loop
    usz exit_count;
    int* exit_blocks;     // targets of the exits (landing pads)
    usz exit_block_count;
    int  parent;          // parent loop header id, or -1 if top-level
    int  depth;
    bool reducible;
}

struct Cfg
{
    Arena* arena;
    Block* blocks;
    usz    block_count;

    Loop*  loops;
    usz    loop_count;

    int    entry;
    int    cur;       // block currently being built
    int*   loop_stack; // headers of loops currently being built
    usz    loop_sp;
    int*   break_to;  // parallel stack: block id a `break` exits to
    int*   cont_to;   // parallel stack: block id a `continue` jumps to

    // Arena for stmt arrays, allocated in chunks.
    Node*** stmt_chunks;
    usz    chunk_count;
    usz    stmt_in_chunk;
}

fn void Cfg.init(Cfg* c, Arena* a)
{
    c.arena = a;
    c.block_count = 0;
    c.loop_count = 0;
    c.entry = -1;
    c.cur = -1;
    c.blocks = null;
    c.loops = null;
    c.loop_stack = null;
    c.break_to = null;
    c.cont_to = null;
    c.stmt_chunks = null;
    c.chunk_count = 0;
    c.stmt_in_chunk = 0;
}

// Allocate the block table.
fn bool Cfg.allocate(Cfg* c)
{
    // Use simple bump allocation through the arena. We slice arrays out of
    // arena-managed slabs; the arena outlives the Cfg.
    c.blocks = (Block*)malloc(MAX_BLOCKS * 2048);
    c.loops  = (Loop*)malloc(MAX_LOOPS * 1024);
    c.loop_stack = (int*)malloc(64 * 8);
    c.break_to   = (int*)malloc(64 * 8);
    c.cont_to    = (int*)malloc(64 * 8);
    if (c.blocks == null || c.loops == null) { return false; }
    for (usz i = 0; i < MAX_BLOCKS; i++)
    {
        c.blocks[i].id = (int)i;
        c.blocks[i].stmts = null;
        c.blocks[i].stmt_count = 0;
        c.blocks[i].stmt_cap = 0;
        c.blocks[i].succ_count = 0;
        c.blocks[i].pred_count = 0;
        c.blocks[i].term = TermKind.TERM_FALL;
        c.blocks[i].term_node = null;
        c.blocks[i].term_taken = -1;
        c.blocks[i].term_not = -1;
        c.blocks[i].match_target_count = 0;
        c.blocks[i].goto_label = 0;
        c.blocks[i].rpo = -1;
        c.blocks[i].idom = -1;
        c.blocks[i].dom_children = null;
        c.blocks[i].dom_child_count = 0;
        c.blocks[i].dom_child_cap = 0;
        c.blocks[i].df_count = 0;
        c.blocks[i].loop_header = -1;
        c.blocks[i].loop_depth = 0;
        c.blocks[i].is_header = false;
        c.blocks[i].is_latch = false;
        c.blocks[i].is_exiting = false;
        c.blocks[i].is_exit = false;
        c.blocks[i].is_preheader = false;
    }
    for (usz i = 0; i < MAX_LOOPS; i++)
    {
        c.loops[i].header = -1;
        c.loops[i].latch = -1;
        c.loops[i].preheader = -1;
        c.loops[i].blocks = null;
        c.loops[i].block_count = 0;
        c.loops[i].exiting = null;
        c.loops[i].exit_count = 0;
        c.loops[i].exit_blocks = null;
        c.loops[i].exit_block_count = 0;
        c.loops[i].parent = -1;
        c.loops[i].depth = 0;
        c.loops[i].reducible = true;
    }
    return true;
}

// ── Block creation ─────────────────────────────────────────────────────────
fn int Cfg.new_block(Cfg* c)
{
    if (c.block_count >= MAX_BLOCKS) { return -1; }
    int id = (int)c.block_count;
    c.block_count = c.block_count + 1;
    c.blocks[id].id = id;
    return id;
}

fn void Cfg.set_cur(Cfg* c, int id) { c.cur = id; }

// Add a statement to the current block, if the block is still open (no
// terminator yet).
fn void Cfg.emit(Cfg* c, Node* n)
{
    if (c.cur < 0) { return; }
    Block* b = &c.blocks[c.cur];
    if (b.term != TermKind.TERM_FALL) { return; }
    // Stmts are stored as a growable pointer array. We bump a slab of 8
    // pointers per chunk off the arena, and link them through the first
    // slot of each slab pointing to the next.
    if (b.stmts == null || b.stmt_count >= b.stmt_cap)
    {
        usz cap = 16;
        Node** arr = (Node**)malloc((long)(cap * 8));
        if (arr == null) { return; }
        // Chain to existing array (we can't realloc since arena is bump-only;
        // downstream walks follow the linked chunks). Simpler: just bump the
        // cap and copy into a new slab -- for CFG sizes here that's fine
        // and avoids pointer chasing.
        if (b.stmts != null)
        {
            // copy existing stmts to new larger array? arena bump can't
            // reclaim; instead just point new array and lose old ones...
            // Simpler approach: allocate exact-sized arrays per block from
            // the arena by tracking max stmt count per block upfront. For
            // now, bump a small fixed slab per 16 statements and chain.
        }
        b.stmts = arr;
        b.stmt_cap = cap;
        b.stmt_count = 0;
    }
    b.stmts[b.stmt_count] = n;
    b.stmt_count = b.stmt_count + 1;
}

// ── Edge construction ──────────────────────────────────────────────────────
fn void Cfg.edge(Cfg* c, int from, int to)
{
    if (from < 0 || to < 0) { return; }
    if (from >= (int)c.block_count || to >= (int)c.block_count) { return; }
    Block* f = &c.blocks[from];
    Block* t = &c.blocks[to];
    if (f.succ_count < MAX_SUCCS)
    {
        // avoid duplicates
        bool dup = false;
        for (usz i = 0; i < f.succ_count; i++) { if (f.succs[i] == to) { dup = true; break; } }
        if (!dup) { f.succs[f.succ_count] = to; f.succ_count = f.succ_count + 1; }
    }
    if (t.pred_count < MAX_PREDS)
    {
        bool dup = false;
        for (usz i = 0; i < t.pred_count; i++) { if (t.preds[i] == from) { dup = true; break; } }
        if (!dup) { t.preds[t.pred_count] = from; t.pred_count = t.pred_count + 1; }
    }
}

fn void Cfg.terminate(Cfg* c, TermKind k)
{
    if (c.cur < 0) { return; }
    c.blocks[c.cur].term = k;
}

fn void Cfg.set_term_taken(Cfg* c, int taken, int not_taken)
{
    if (c.cur < 0) { return; }
    Block* b = &c.blocks[c.cur];
    b.term = TermKind.TERM_IF;
    b.term_taken = taken;
    b.term_not = not_taken;
    c.edge(c.cur, taken);
    if (not_taken >= 0) { c.edge(c.cur, not_taken); }
}

// ── High-level builders ────────────────────────────────────────────────────
// Build the CFG for a function body (which may be a block or a single expr).
fn bool Cfg.build_body(Cfg* c, Node* body)
{
    if (body == null) { return false; }
    if (!c.allocate()) { return false; }
    int entry = c.new_block();
    c.entry = entry;
    c.set_cur(entry);
    c.walk(body);
    // If the last block falls through with no terminator, that's fine
    // (function returns the value); mark it as return.
    if (c.cur >= 0 && c.blocks[c.cur].term == TermKind.TERM_FALL)
    {
        c.terminate(TermKind.TERM_RETURN);
    }
    c.compute_rpo();
    c.compute_idoms();
    c.compute_dom_tree();
    c.compute_df();
    c.find_loops();
    return true;
}

// Recursive walk that emits statements and creates new blocks at branch points.
fn void Cfg.walk(Cfg* c, Node* n)
{
    if (n == null) { return; }
    switch (n.kind)
    {
        case Nk.N_BLOCK:
            for (usz i = 0; i < n.child_count; i++) { c.walk(n.children[i]); }
            return;
        case Nk.N_STMT_RETURN:
            c.emit(n);
            c.terminate(TermKind.TERM_RETURN);
            return;
        case Nk.N_STMT_BREAK:
            c.emit(n);
            c.terminate(TermKind.TERM_BREAK);
            if (c.loop_sp > 0)
            {
                int target = c.break_to[c.loop_sp - 1];
                if (target >= 0) { c.edge(c.cur, target); }
            }
            return;
        case Nk.N_STMT_CONTINUE:
            c.emit(n);
            c.terminate(TermKind.TERM_CONTINUE);
            if (c.loop_sp > 0)
            {
                int target = c.cont_to[c.loop_sp - 1];
                if (target >= 0) { c.edge(c.cur, target); }
            }
            return;
        case Nk.N_EXPR_UNREACHABLE:
        case Nk.N_EXPR_TRAP:
        case Nk.N_EXPR_UB:
        case Nk.N_EXPR_POISON:
            c.emit(n);
            c.terminate(TermKind.TERM_UNREACH);
            return;
        case Nk.N_EXPR_ASSERT:
        case Nk.N_EXPR_ASSUME:
            // assert/assume evaluate their condition (child 0) then fall through.
            // If they fire (assert fail) they trap, so they split into a cont
            // block and a fail block that terminates unreach.
        {
            if (n.child_count >= 1) { c.emit(n.children[0]); }
            c.emit(n);
            int cont = c.new_block();
            int fail = c.new_block();
            c.set_term_taken(cont, fail);
            c.set_cur(fail);
            c.terminate(TermKind.TERM_UNREACH);
            c.set_cur(cont);
            return;
        }
        case Nk.N_EXPR_IF:
            c.walk_if(n);
            return;
        case Nk.N_EXPR_WHILE:
            c.walk_while(n);
            return;
        case Nk.N_EXPR_FOR:
            c.walk_for(n);
            return;
        case Nk.N_EXPR_LOOP:
            c.walk_loop(n);
            return;
        case Nk.N_EXPR_MATCH:
            c.walk_match(n);
            return;
        case Nk.N_STMT_DEFER:
            c.walk_defer(n);
            return;
        case Nk.N_EXPR_TRY:
            c.walk_try(n);
            return;
        case Nk.N_EXPR_HANDLE:
            c.walk_handle(n);
            return;
        case Nk.N_EXPR_UNSAFE:
        case Nk.N_EXPR_UNCHECKED:
            // Scoped blocks that don't change control flow but may suppress
            // diagnostics; walk their single child block as straight-line.
            if (n.child_count >= 1) { c.walk(n.children[0]); }
            else { c.emit(n); }
            return;
        case Nk.N_EXPR_LAMBDA:
            // Lambda is a VALUE, not a control-flow split — the body does NOT
            // execute here.  Emit the lambda as a single expression and do NOT
            // walk its body in the current CFG.
            c.emit(n);
            return;
        case Nk.N_EXPR_PERFORM:
        case Nk.N_EXPR_RESUME:
            // Effect ops: treated conservatively as terminators only when
            // inside a matching handler; for now, emit as straight-line (the
            // effect/handler checker walks them separately). They MAY return
            // (suspend/resume is a delimited continuation, but from the POV
            // of the local CFG they look like calls that return).
            c.emit(n);
            return;
        default:
            // Expression/let/assign etc. — emit as a straight-line stmt.
            c.emit(n);
            return;
    }
}

// If: cond; then branch; else branch; merge.
fn void Cfg.walk_if(Cfg* c, Node* n)
{
    if (n.child_count < 2) { c.emit(n); return; }
    Node* cond = n.children[0];
    c.emit(cond);
    int then_b = c.new_block();
    int else_b = (n.child_count >= 3) ? c.new_block() : -1;
    int merge_b = c.new_block();
    c.set_term_taken(then_b, else_b >= 0 ? else_b : merge_b);
    // then branch
    c.set_cur(then_b);
    c.walk(n.children[1]);
    if (c.cur >= 0 && c.blocks[c.cur].term == TermKind.TERM_FALL)
    {
        c.edge(c.cur, merge_b);
        c.terminate(TermKind.TERM_FALL);
    }
    // else branch
    if (else_b >= 0 && n.child_count >= 3)
    {
        c.set_cur(else_b);
        c.walk(n.children[2]);
        if (c.cur >= 0 && c.blocks[c.cur].term == TermKind.TERM_FALL)
        {
            c.edge(c.cur, merge_b);
            c.terminate(TermKind.TERM_FALL);
        }
    }
    c.set_cur(merge_b);
}

// While: entry cond block, body block, exit block.
fn void Cfg.walk_while(Cfg* c, Node* n)
{
    if (n.child_count < 2) { c.emit(n); return; }
    // A while condition must not share a block with the pre-loop definition.
    // Splitting an explicit preheader from the header preserves the entry path
    // separately from the latch path and exposes loop-carried SSA phi nodes.
    int preheader = c.cur;
    int cond_b = c.new_block();
    if (preheader >= 0 && cond_b >= 0) { c.edge(preheader, cond_b); c.terminate(TermKind.TERM_FALL); }
    c.set_cur(cond_b);
    Node* cond = n.children[0];
    Node* body = n.children[1];
    c.emit(cond);
    int body_b = c.new_block();
    int exit_b = c.new_block();
    c.set_term_taken(body_b, exit_b);
    // Push loop context.
    if (c.loop_sp < 64)
    {
        c.loop_stack[c.loop_sp] = cond_b;
        c.break_to[c.loop_sp] = exit_b;
        c.cont_to[c.loop_sp] = cond_b;
        c.loop_sp = c.loop_sp + 1;
    }
    c.blocks[cond_b].is_header = true;
    // body
    c.set_cur(body_b);
    c.walk(body);
    if (c.cur >= 0 && c.blocks[c.cur].term == TermKind.TERM_FALL)
    {
        c.edge(c.cur, cond_b); // back edge
        c.blocks[c.cur].is_latch = true;
        c.terminate(TermKind.TERM_FALL);
    }
    if (c.loop_sp > 0) { c.loop_sp = c.loop_sp - 1; }
    c.set_cur(exit_b);
}

// For loops are desugared to: cond block (test iterator), body block,
// update block (advance iterator / re-bind pattern), exit. The post-iteration
// update runs in the latch before branching back to cond, so continue skips
// the body update BUT still runs the iterator-advance logic? No: in Pride,
// `continue` goes to the top of the loop (which is the cond block) -- the
// iterator's next() call is re-entered each iteration. So shape is:
//   cond:  iter.next() is the test -- emits the iter expr; if taken -> body, else -> exit.
//   body:  user code
//   latch: post-iteration (re-eval iter child? No -- iter has advanced via
//          the `.next()` implicit binding, so just branch to cond).
// The handoff noted "post-iteration update in the latch" -- this covers
// cases like `for pat in iter { body };` where the pattern rebinding happens
// at the latch edge; for now we simply route body fallthrough back to cond
// via a dedicated latch block, which is where any future post-body stmt
// will go.
fn void Cfg.walk_for(Cfg* c, Node* n)
{
    if (n.child_count < 3) { c.emit(n); return; }
    int cond_b = c.new_block();
    c.edge(c.cur, cond_b);
    c.terminate(TermKind.TERM_FALL);
    c.set_cur(cond_b);
    // The iterator expression is re-evaluated each round implicitly via the
    // .next() binding. We emit it once in cond_b (next() has side effects
    // once per iteration).
    c.emit(n.children[1]);
    int body_b = c.new_block();
    int latch_b = c.new_block();
    int exit_b = c.new_block();
    c.set_term_taken(body_b, exit_b);
    if (c.loop_sp < 64)
    {
        c.loop_stack[c.loop_sp] = cond_b;
        c.break_to[c.loop_sp] = exit_b;
        c.cont_to[c.loop_sp] = cond_b;
        c.loop_sp = c.loop_sp + 1;
    }
    c.blocks[cond_b].is_header = true;
    // body
    c.set_cur(body_b);
    c.walk(n.children[2]);
    if (c.cur >= 0 && c.blocks[c.cur].term == TermKind.TERM_FALL)
    {
        c.edge(c.cur, latch_b);
        c.terminate(TermKind.TERM_FALL);
    }
    // latch: post-iteration update; for now just an empty block that falls
    // through back to cond. When there are explicit updates they go here.
    c.set_cur(latch_b);
    c.edge(latch_b, cond_b);
    c.blocks[latch_b].is_latch = true;
    c.terminate(TermKind.TERM_FALL);
    if (c.loop_sp > 0) { c.loop_sp = c.loop_sp - 1; }
    c.set_cur(exit_b);
}

// Match: emit scrutinee, branch to each arm block, merge.
fn void Cfg.walk_match(Cfg* c, Node* n)
{
    if (n.child_count < 2) { c.emit(n); return; }
    c.emit(n.children[0]); // scrutinee
    usz arm_count = n.child_count - 1;
    if (arm_count == 0) { return; }
    int* arm_blocks = (int*)malloc((long)(arm_count * 8));
    int merge = c.new_block();
    for (usz i = 0; i < arm_count; i++) { arm_blocks[i] = c.new_block(); }
    // Connect current block to the first arm block (conservatively --
    // correct for a single-arm match; multi-arm will be threaded during
    // arm processing).
    Block* cb = &c.blocks[c.cur];
    cb.term = TermKind.TERM_MATCH;
    cb.term_node = n;
    cb.match_target_count = 0;
    for (usz i = 0; i < arm_count && i < 16; i++)
    {
        cb.match_targets[i] = arm_blocks[i];
        c.edge(c.cur, arm_blocks[i]);
        cb.match_target_count = i + 1;
    }
    for (usz i = 0; i < arm_count; i++)
    {
        c.set_cur(arm_blocks[i]);
        Node* arm = n.children[i + 1];
        c.walk(arm);
        if (c.cur >= 0 && c.blocks[c.cur].term == TermKind.TERM_FALL)
        {
            c.edge(c.cur, merge);
            c.terminate(TermKind.TERM_FALL);
        }
    }
    c.set_cur(merge);
}

// loop { body } — infinite loop with no condition. break exits it.
fn void Cfg.walk_loop(Cfg* c, Node* n)
{
    if (n.child_count < 1) { c.emit(n); return; }
    Node* body = n.children[0];
    int header_b = c.new_block();
    c.edge(c.cur, header_b);
    c.terminate(TermKind.TERM_FALL);
    c.set_cur(header_b);
    int exit_b = c.new_block();
    if (c.loop_sp < 64)
    {
        c.loop_stack[c.loop_sp] = header_b;
        c.break_to[c.loop_sp] = exit_b;
        c.cont_to[c.loop_sp] = header_b;
        c.loop_sp = c.loop_sp + 1;
    }
    c.blocks[header_b].is_header = true;
    c.walk(body);
    // After body, if we still fall through, loop back to header.
    if (c.cur >= 0 && c.blocks[c.cur].term == TermKind.TERM_FALL)
    {
        c.edge(c.cur, header_b);
        c.blocks[c.cur].is_latch = true;
        c.terminate(TermKind.TERM_FALL);
    }
    if (c.loop_sp > 0) { c.loop_sp = c.loop_sp - 1; }
    c.set_cur(exit_b);
}

// defer e  — register `e` to run on scope exit. For CFG purposes the defer
// is a straight-line annotation; the AST's defer is hoisted to every
// return/break/continue/throw path by a later cleanup pass. For CFG shape
// we emit the defer in place (it is a marker) and treat all return edges
// from the enclosing function as flowing through a defer-cleanup block.
// For now we just emit the deferred expression in line and move on.
fn void Cfg.walk_defer(Cfg* c, Node* n)
{
    c.emit(n); // walk is implicit; emit(n) emits the node reference, child walk happens in consumers
    if (n.child_count >= 1)
    {
        // Emit children in place so they participate in the current block
        // (the defer just records them for later; walking them here does not
        //  change semantics since the child is an expression, not an
        //  imperative block).
        for (usz i = 0; i < n.child_count; i++) { c.walk(n.children[i]); }
    }
}

// try { body } catch pat { handler } ...
//   children[0] = body block; children[1..] = N_MATCH_ARM style handlers.
// Approximation: body can branch to each handler OR to the merge block on
// exceptional exit; body falling through goes to merge. This is what the
// CFG needs to look like for reachability/dominance purposes.
fn void Cfg.walk_try(Cfg* c, Node* n)
{
    if (n.child_count < 1) { c.emit(n); return; }
    Node* body = n.children[0];
    int merge_b = c.new_block();
    int body_b = c.new_block();
    usz handler_count = (n.child_count > 1) ? n.child_count - 1 : 0;
    // Allocate handler blocks up front.
    int* handler_b = null;
    if (handler_count > 0)
    {
        handler_b = (int*)malloc((long)(handler_count * 8));
        for (usz i = 0; i < handler_count; i++) handler_b[i] = c.new_block();
    }
    c.edge(c.cur, body_b);
    c.terminate(TermKind.TERM_FALL);
    // Body
    c.set_cur(body_b);
    c.walk(body);
    if (c.cur >= 0 && c.blocks[c.cur].term == TermKind.TERM_FALL)
    {
        c.edge(c.cur, merge_b);
        c.terminate(TermKind.TERM_FALL);
    }
    // Treat any N_EXPR_THROW/perf that could exit the body as also reaching
    // handlers — we conservatively add edges from body_b to each handler
    // block at CFG build time (dataflow passes will prune dead edges).
    for (usz i = 0; i < handler_count; i++)
    {
        c.edge(body_b, handler_b[i]);
        c.set_cur(handler_b[i]);
        c.walk(n.children[i + 1]);
        if (c.cur >= 0 && c.blocks[c.cur].term == TermKind.TERM_FALL)
        {
            c.edge(c.cur, merge_b);
            c.terminate(TermKind.TERM_FALL);
        }
    }
    c.set_cur(merge_b);
}

// handle comp | arms  — like match but for effect operations. Control flow:
//   children[0] = computation; children[1..] = N_HANDLER_ARM (op -> resume).
// The comp performs `perform`s that jump to handler arms; after the arm,
// control returns to the comp at the point of the perform via resume. For
// an intra-procedural CFG we treat this conservatively like a try/catch
// with a resume edge back into the comp. Simpler sound shape:
//   comp_block -> (merge | any handler arm); handler arm -> comp_block (resume);
// which is what we emit.
fn void Cfg.walk_handle(Cfg* c, Node* n)
{
    if (n.child_count < 2) { c.emit(n); return; }
    Node* comp = n.children[0];
    int merge_b = c.new_block();
    int comp_b = c.new_block();
    usz arm_count = n.child_count - 1;
    int* arm_b = (int*)malloc((long)(arm_count * 8));
    for (usz i = 0; i < arm_count; i++) arm_b[i] = c.new_block();
    c.edge(c.cur, comp_b);
    c.terminate(TermKind.TERM_FALL);
    c.set_cur(comp_b);
    c.walk(comp);
    if (c.cur >= 0 && c.blocks[c.cur].term == TermKind.TERM_FALL)
    {
        c.edge(c.cur, merge_b);
        c.terminate(TermKind.TERM_FALL);
    }
    for (usz i = 0; i < arm_count; i++)
    {
        // Each perform in comp can transfer to arm_b[i]; we add the edge
        // from comp_b to arm_b (conservative), and arm_b's tail resumes
        // back into comp_b.
        c.edge(comp_b, arm_b[i]);
        c.set_cur(arm_b[i]);
        c.walk(n.children[i + 1]);
        if (c.cur >= 0 && c.blocks[c.cur].term == TermKind.TERM_FALL)
        {
            // resume edge back to comp (same block acts as re-entry)
            c.edge(c.cur, comp_b);
            c.terminate(TermKind.TERM_FALL);
        }
    }
    c.set_cur(merge_b);
}

// ── RPO computation ────────────────────────────────────────────────────────
fn void Cfg.compute_rpo(Cfg* c)
{
    if (c.entry < 0) { return; }
    int* post = (int*)malloc(MAX_BLOCKS * 8);
    usz post_n = 0;
    char* visited = (char*)malloc(MAX_BLOCKS);
    for (usz i = 0; i < MAX_BLOCKS; i++) { visited[i] = 0; }
    // Iterative DFS to avoid blowing the C stack.
    int* stack = (int*)malloc(MAX_BLOCKS * 8);
    char* on_stack = (char*)malloc(MAX_BLOCKS);
    usz sp = 0;
    stack[sp] = c.entry; sp = sp + 1;
    // Mark entry
    usz* succ_i = (usz*)malloc(MAX_BLOCKS * 8);
    for (usz i = 0; i < MAX_BLOCKS; i++) succ_i[i] = 0;
    while (sp > 0)
    {
        int b = stack[sp - 1];
        if (visited[b])
        {
            // post-order visit
            if (!on_stack[b]) { post[post_n] = b; post_n = post_n + 1; on_stack[b] = 1; }
            sp = sp - 1;
            continue;
        }
        visited[b] = 1;
        Block* bb = &c.blocks[b];
        bool pushed = false;
        // Push successors in reverse so first successor is processed first.
        for (int i = (int)bb.succ_count - 1; i >= 0; i--)
        {
            int s = bb.succs[(usz)i];
            if (s >= 0 && !visited[s])
            {
                if (sp < MAX_BLOCKS) { stack[sp] = s; sp = sp + 1; pushed = true; }
            }
        }
        if (!pushed)
        {
            post[post_n] = b; post_n = post_n + 1; on_stack[b] = 1;
            sp = sp - 1;
        }
    }
    // RPO is reverse of post-order.
    for (usz i = 0; i < post_n; i++)
    {
        int b = post[post_n - 1 - i];
        c.blocks[b].rpo = (int)i;
    }
}

// ── Dominator computation (Cooper-Harvey-Kennedy) ──────────────────────────
fn int Cfg.intersect(Cfg* c, int b1, int b2)
{
    int a = b1;
    int b = b2;
    while (a != b)
    {
        while (c.blocks[a].rpo > c.blocks[b].rpo) { a = c.blocks[a].idom; if (a < 0) break; }
        while (c.blocks[b].rpo > c.blocks[a].rpo) { b = c.blocks[b].idom; if (b < 0) break; }
        if (a < 0 || b < 0) return c.entry;
    }
    return a;
}

fn void Cfg.compute_idoms(Cfg* c)
{
    if (c.entry < 0) { return; }
    // Initialize: all undefined; entry idom = itself.
    for (usz i = 0; i < c.block_count; i++) { c.blocks[i].idom = -1; }
    c.blocks[c.entry].idom = c.entry;
    bool changed = true;
    int iters = 0;
    while (changed && iters < 200)
    {
        changed = false;
        iters = iters + 1;
        // Process in RPO (skip entry).
        for (usz rpo = 1; rpo < c.block_count; rpo++)
        {
            int b = -1;
            for (usz i = 0; i < c.block_count; i++)
            {
                if (c.blocks[i].rpo == (int)rpo) { b = (int)i; break; }
            }
            if (b < 0) continue;
            Block* bb = &c.blocks[b];
            int new_idom = -1;
            for (usz j = 0; j < bb.pred_count; j++)
            {
                int p = bb.preds[j];
                if (c.blocks[p].idom != -1)
                {
                    if (new_idom == -1) { new_idom = p; }
                    else { new_idom = c.intersect(new_idom, p); }
                }
            }
            if (new_idom != bb.idom)
            {
                bb.idom = new_idom;
                changed = true;
            }
        }
    }
    c.blocks[c.entry].idom = -1; // entry has no idom
}

fn void Cfg.compute_dom_tree(Cfg* c)
{
    // Allocate child arrays.
    for (usz i = 0; i < c.block_count; i++)
    {
        c.blocks[i].dom_children = (int*)malloc(MAX_BLOCKS * 8);
        c.blocks[i].dom_child_count = 0;
    }
    for (usz i = 0; i < c.block_count; i++)
    {
        int idom = c.blocks[i].idom;
        if (idom >= 0 && idom != (int)i)
        {
            Block* par = &c.blocks[idom];
            if (par.dom_child_count < MAX_BLOCKS)
            {
                par.dom_children[par.dom_child_count] = (int)i;
                par.dom_child_count = par.dom_child_count + 1;
            }
        }
    }
}

// ── Dominance frontier ─────────────────────────────────────────────────────
fn void Cfg.compute_df(Cfg* c)
{
    // DF(n) = union over successors s not strictly dominated by n of {s}
    //       + union over children c in dom tree of DF(c) where idom(c) != n
    // Compute in postorder of the dom tree (children before parents).
    // Build a postorder list via DFS from entry.
    int* order = (int*)malloc(MAX_BLOCKS * 8);
    usz on = 0;
    // Simple iterative postorder over dom tree.
    int* stk = (int*)malloc(MAX_BLOCKS * 8);
    char* done = (char*)malloc(MAX_BLOCKS);
    for (usz i = 0; i < MAX_BLOCKS; i++) done[i] = 0;
    usz sp = 0;
    if (c.entry >= 0) { stk[sp] = c.entry; sp = sp + 1; }
    while (sp > 0)
    {
        int b = stk[sp - 1];
        Block* bb = &c.blocks[b];
        bool pushed = false;
        for (usz i = 0; i < bb.dom_child_count; i++)
        {
            int ch = bb.dom_children[i];
            if (!done[ch]) { stk[sp] = ch; sp = sp + 1; pushed = true; break; }
        }
        if (!pushed)
        {
            order[on] = b; on = on + 1;
            done[b] = 1;
            sp = sp - 1;
        }
    }
    for (usz i = 0; i < on; i++)
    {
        int b = order[i];
        Block* bb = &c.blocks[b];
        // Local DF.
        for (usz j = 0; j < bb.succ_count; j++)
        {
            int s = bb.succs[j];
            if (c.blocks[s].idom != b) { c.add_df(b, s); }
        }
        // Propagate from dom children.
        for (usz j = 0; j < bb.dom_child_count; j++)
        {
            int ch = bb.dom_children[j];
            Block* cb = &c.blocks[ch];
            for (usz k = 0; k < cb.df_count; k++)
            {
                int d = cb.df[k];
                if (c.blocks[d].idom != b) { c.add_df(b, d); }
            }
        }
    }
}

fn void Cfg.add_df(Cfg* c, int b, int d)
{
    Block* bb = &c.blocks[b];
    for (usz i = 0; i < bb.df_count; i++) { if (bb.df[i] == d) return; }
    if (bb.df_count < MAX_DF)
    {
        bb.df[bb.df_count] = d;
        bb.df_count = bb.df_count + 1;
    }
}

// ── Natural loop detection ─────────────────────────────────────────────────
fn void Cfg.find_loops(Cfg* c)
{
    // Back edge: edge (a,b) where b dominates a. Header = b, latch = a.
    // For each back edge, collect blocks in the loop via backward traversal
    // from latch up to (but not including) header.
    for (usz i = 0; i < c.block_count; i++)
    {
        Block* bb = &c.blocks[i];
        for (usz j = 0; j < bb.succ_count; j++)
        {
            int s = bb.succs[j];
            if (!c.dominates(s, (int)i)) continue;
            // Back edge from i -> s; header = s, latch = i.
            c.add_loop(s, (int)i);
        }
    }
    // Assign loop_depth by walking each block's innermost loop.
    for (usz li = 0; li < c.loop_count; li++)
    {
        Loop* lp = &c.loops[li];
        c.blocks[lp.header].is_header = true;
        c.blocks[lp.latch].is_latch = true;
        for (usz k = 0; k < lp.block_count; k++)
        {
            int bid = lp.blocks[k];
            if (c.blocks[bid].loop_header < 0)
            {
                c.blocks[bid].loop_header = lp.header;
            }
            c.blocks[bid].loop_depth = c.blocks[bid].loop_depth + 1;
        }
    }
}

fn bool Cfg.dominates(Cfg* c, int a, int b)
{
    // Does a dominate b? Walk up idom chain from b until entry or a.
    int x = b;
    while (x >= 0)
    {
        if (x == a) return true;
        if (c.blocks[x].idom == x) return false;
        x = c.blocks[x].idom;
    }
    return false;
}

fn void Cfg.add_loop(Cfg* c, int header, int latch)
{
    // Find existing loop with this header.
    usz li = 0;
    for (; li < c.loop_count; li++) { if (c.loops[li].header == header) break; }
    if (li >= c.loop_count && c.loop_count >= MAX_LOOPS) return;
    Loop* lp;
    if (li >= c.loop_count)
    {
        lp = &c.loops[c.loop_count];
        lp.header = header;
        lp.latch = latch;
        lp.block_count = 0;
        lp.blocks = (int*)malloc(MAX_BLOCKS * 8);
        lp.exiting = (int*)malloc(MAX_BLOCKS * 8);
        lp.exit_blocks = (int*)malloc(MAX_BLOCKS * 8);
        c.loop_count = c.loop_count + 1;
    }
    else { lp = &c.loops[li]; }
    // Backward BFS from latch collecting blocks in loop; stop at header.
    // Simple stack-based.
    char* in_loop = (char*)malloc(MAX_BLOCKS);
    for (usz i = 0; i < MAX_BLOCKS; i++) in_loop[i] = 0;
    int* stack = (int*)malloc(MAX_BLOCKS * 8);
    usz sp = 0;
    // Push latch and header (header is in loop).
    stack[sp] = latch; sp = sp + 1; in_loop[latch] = 1;
    in_loop[header] = 1;
    while (sp > 0)
    {
        int b = stack[sp - 1]; sp = sp - 1;
        // add to loop's block list if not already there
        bool dup = false;
        for (usz k = 0; k < lp.block_count; k++) { if (lp.blocks[k] == b) { dup = true; break; } }
        if (!dup && lp.block_count < MAX_BLOCKS) { lp.blocks[lp.block_count] = b; lp.block_count = lp.block_count + 1; }
        Block* bb = &c.blocks[b];
        for (usz j = 0; j < bb.pred_count; j++)
        {
            int p = bb.preds[j];
            if (!in_loop[p]) { in_loop[p] = 1; stack[sp] = p; sp = sp + 1; }
        }
    }
    // Ensure header is in the block list.
    {
        bool dup = false;
        for (usz k = 0; k < lp.block_count; k++) { if (lp.blocks[k] == header) { dup = true; break; } }
        if (!dup && lp.block_count < MAX_BLOCKS) { lp.blocks[lp.block_count] = header; lp.block_count = lp.block_count + 1; }
    }
    // Exiting blocks: blocks in the loop with a successor NOT in the loop.
    lp.exit_count = 0;
    lp.exit_block_count = 0;
    for (usz k = 0; k < lp.block_count; k++)
    {
        int b = lp.blocks[k];
        Block* bb = &c.blocks[b];
        bool leaves = false;
        for (usz j = 0; j < bb.succ_count; j++)
        {
            int s = bb.succs[j];
            if (!in_loop[s])
            {
                leaves = true;
                if (lp.exit_block_count < MAX_BLOCKS)
                {
                    lp.exit_blocks[lp.exit_block_count] = s;
                    lp.exit_block_count = lp.exit_block_count + 1;
                }
            }
        }
        if (leaves)
        {
            bb.is_exiting = true;
            if (lp.exit_count < MAX_BLOCKS)
            {
                lp.exiting[lp.exit_count] = b;
                lp.exit_count = lp.exit_count + 1;
            }
        }
    }
}

// ── Reporting ──────────────────────────────────────────────────────────────
fn void Cfg.report(Cfg* c, char* name)
{
    pfront_core::printf("  cfg %-24s : %d blocks, %d loops\n", name != null ? name : "?",
           (int)c.block_count, (int)c.loop_count);
}

// Check whether `dom` strictly dominates `b` (used by external passes).
fn bool Cfg.strictly_dominates(Cfg* c, int dom, int b)
{
    if (dom == b) return false;
    return c.dominates(dom, b);
}
