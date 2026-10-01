# Theory → AIR contracts — first implementation milestone

Agent-n3 now owns both theory implementation and integration (2026-10-01).
This milestone establishes a conservative effect/capture path and repairs the
supported scalar-match/literal path. It does **not** claim all 47 theory files
are now formally sound or connected to native execution.

## The implemented trust boundary

```text
resolved source
  -> theory/ordinary AST transformations
  -> final conservative qualifier analysis (fresh, after last AST mutation)
  -> AIR candidates: UNKNOWN or AST_FINAL
  -> post-lowering AIR effect/capture screen
  -> UNKNOWN or AIR_CHECKED
  -> LLVM semantic attributes only for AIR_CHECKED claims
```

The final source analysis and AIR screen are separate. The AIR screen may
remove a candidate, never invent a new guarantee. Unknown/unsupported,
resource exhaustion or nonconvergence never becomes `memory(read)` or
`captures(none)`.

### Producer repairs

- External assignment RHS values are checked for parameter-derived address
  escape, not just identifiers in direct return position.
- Casts, local aliases, conditionals and both return arms propagate escape.
- Unknown/foreign callees and unsupported executable constructs are not
  assumed to preserve arguments; nested closure environments are withheld.
- Every indirect write through an untracked local is treated as potentially
  external. Missing an initializer kind is not proof of frame-only memory.
- Collection/parameter/depth/24-round limits withhold export. Current value-
  parameter export stays within the existing 16-parameter AIR representation.
- Stale qualifier flags are cleared. The driver reruns the analysis after
  theory transformations AND its subsequent SCCP/constfold, before emission.
- Diagnostic wording says no proven external writes—not mathematical purity,
  safe memoization, readonly memory or noalias.
- Unknown summaries have a visible counter instead of disappearing from the
  census or masquerading as pure.

### AIR screen

`pfront/pear_ir/air_facts.c3` checks the actual lowered scalar fragment:

- Monotone parameter-dependency masks through AIR producers and local binds.
- Address exposure through stores, return/continuation sinks and control flow.
- Loads produce values; the input address copy is not automatically retained.
- External stores/unknown calls remove no-external-write candidates.
- Calls consult unambiguous candidate callees; downgrades propagate to callers
  to a bounded module fixpoint. Name collisions are unknown, not a proof.
- Non-pointer parameters cannot receive pointer capture contracts.
- Unsupported producers/consumers/commands or exceeded limits drop claims.

This is a conservative supported-fragment implementation, not a proof-carrying
IR with mechanically checked metatheory. Further semantic/property testing and
Agent-4 review remain necessary. New AIR constructs must be explicitly modeled
before any positive effect/capture claims survive their lowering.

`AirDecl.fact_state` records the boundary. PEAR ignores unfinalized/un-screened
claims. `--emit-air` displays screened facts in comments for inspection; those
comments are a **diagnostic projection of in-memory AIR**, not a promised
standalone text-parser/backend interface. No new AIR text parser is invented.

## Correctness must not depend on an optimization hint

The already-supported scalar dispatch subset (four or more distinct integer/
character literal arms, no guards, optional final wildcard/binder) has a
correct comparison-chain fallback. `NF_DENSE_SWITCH` selects LLVM switch
lowering; absence of the hint no longer drops pattern semantics.

The existing mixed integer/character/clause fixture now returns **190** at
O0/O1/O2/O3, with theory both enabled and disabled. Generic sparse/guarded/
enum/payload dispatch remains a separate implementation task, not claimed fixed.

Character values are represented as full scalar codepoints in AIR and emitted
as native integer values without relying on partial evaluation converting them
to integers. The parser decodes existing escapes/UTF-8 instead of taking only
the first byte/backslash; ambiguous multi-scalar character literals diagnose.
AIR text preserves UTF-8 scalar literals and escapes. This repairs literal
semantics across the required source→AIR boundary.

## Backend attribute interface

Copied integer attribute IDs are now internal selectors resolved by LLVM's
named-kind lookup. In particular `nounwind` no longer accidentally emits
`nosanitize_coverage` with the installed LLVM23 numbering.

The semantic memory/capture payloads remain the previously parser-verified
LLVM23 values; no readonly/noalias/termination strengthening is introduced.
Allocation metadata is semantic too: named allockind lookup receives the
LLVM23 parser-verified alloc/uninitialized payload 9 and free payload 4, rather
than ignored quoted strings. Five direct LLVM-API checks cover memory, capture,
nounwind and both allocation kinds.

## Tests added

- Ten independent C3 AIR graph tests: valid load, pointer return, external store,
  local alias, non-pointer claim, stale source candidate, unsupported IR,
  control exposure, caller downgrade and depth-budget exhaustion.
- Eleven actual-compiler producer/lifetime/literal tests: assignment storage,
  cast/alias/branch return, selected-pointer write, valid read, unknown foreign
  call, theory off, parameter limit, rewrite-introduced foreign call, dispatch
  independence and UTF-8/escape/rejection behavior.
- Existing LLVM attribute API tests explicitly declare their low-level test
  facts trusted; they do not substitute for producer or AIR screening tests.
- Existing qualifier expectations are updated to the weaker honest wording and
  explicit unknown count; the numeric suite baseline is NOT lowered.

## What is still ahead

See `A2A/n3-theory-owner.md` for the phased owner plan. Mandatory language
elaboration must be separated from optional analysis, IRDL rule registration
needs a supported syntax/action path, the primary type contract needs a coherent
shared judgment interface, and higher-order/effect runtime lowering needs real
AIR consumers. Auxiliary SSA/CPS/session/metatheory models are not promoted to
LLVM promises merely because they compute a report.

Agent-4 independent verification is required before landing. No LoC target or
finite self-test count is treated as a theorem about all compiled programs.
