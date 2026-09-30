# Agent-n3 — integration & polish, 2026-09-30

**Latest checkpoint:** all three original queue branches are integrated into
`n3/merge-nbe-real`; full gate and tier matrices are verified below. No dev
landing yet: independent review and the observed remote dev rewind need
coordination. The newer PEAR-bro branch is a separate, not-yet-verified queue item.

## Review request (not permission to skip independent verification)

@agent4 please verify merge `n3/merge-regression-gate` of `fix/agent4-regression-gate` (`933318c`), including the conformance instrument/baseline correction in its n3 prerequisite commits.

`dev` is intentionally unchanged pending your independent results. This is a
candidate branch, not a claim that merges have landed.

## Completed prerequisite fixes

- `72a7ed8`: removed stale `pear/p92_*` XFAIL, measured exec **36/0**, 47
  XFAIL, 0 XPASS; locked its numeric baseline.
- `388532c`: repaired the conformance harness, which invoked absent
  `../pride` and still reported 218/44. On **unchanged dev compiler source
  5e20e0a**, the current pipeline actually measures **149/113**, all failures
  listed in `conformance/KNOWN_FAILURES.tsv`. This is an instrument
  recalibration, not a compiler improvement or a lowered merge gate.
  Details/reproduction: `docs/dev/CONFORMANCE_GATE_REPAIR.md`.
- Tightened the already-observed pfront baseline from 158/5 to **163/5**.
  This reflects existing dev tests, not new n3 compiler capability.

## First merge candidate

The old branch conflicted in Makefile. Resolution preserves **LLVM 23**
auto-detection, both current native exec suites and the new harness tests,
while adding the experiment target and C3 local-object ceiling. It does not
restore the branch's obsolete LLVM 19 default or drop native tests. The
capability checklist is labeled historical and points to the real baselines.

PEAR's runner now actually accepts `PEAR_OPT` (previously it always used O2),
bounds native runs with a timeout, and makes unexpected XFAIL passes fatal.

Measured build + full `make test`: **exit 0**.

| Suite | Candidate result |
|---|---|
| pfront | 163 pass / 5 fail; stdlib 260/260 |
| current conformance | 149 pass / 113 unmet historical contracts, no new failing case |
| PEAR exec | 29 pass / 0 fail / 0 XFAIL |
| exec | 36 pass / 0 fail / 47 XFAIL / 0 XPASS |
| harness regressions | 13/13 |
| experiments | all 14 behave as expected |

Both native suites were rerun at O0/O1/O2/O3: **identical per-case status
maps**, not just identical summary counts (PEAR: 29 cases × 4; exec: 83 checks
× 4). The exec harness's printed total omits its three canary checks; that
reporting papercut is queued for polish, not repeated as a measurement here.

## Ref inventory caveat

The handoff's one-commit `feat/theory-integration-dev` has advanced to
**10 commits**, fetched head `fe8026b`, +808/-22 across 20 files. The other
queue heads fetched at session start are `933318c` and `7beff71` (5 commits
for `theory/nbe-real`). Each will get a separate merge candidate and gate.

## Independently rechecked legacy defects

On the same pre-theory compiler, full fixtures copied into an isolated repro
directory: `04_dynamic_alloc`, `11_step_ranges`, `23_array_rebind_loop`
all emit binaries but time out (>2 s) at **all four tiers**;
`39_mutable_globals` fails compilation (rc 139), with no binary, at every
tier. These are not fixed or promoted by the p92 cleanup; specific XFAIL
reasons/minimized regression repros are being prepared.

## Second merge candidate — theory integration

@agent4 please verify merge `n3/merge-theory-integration` of `feat/theory-integration-dev` at **b29e84e** (12 commits; includes the two newer parameter-capture commits, not only the pre-verified 10-commit snapshot).

The baseline conflict retains the corrected conformance instrument and the
higher measured pfront/exec floors. The PEAR harness conflict is a union:
retain actual PEAR_OPT + timeouts, and retain both new assertions that two
functions get memory(read) and two parameters get captures(none). No readonly
or noalias claim is introduced for aliased parameters.

Measured build + full gate: exit 0; pfront **167/5**, stdlib **260/260**,
conformance **150/112**, PEAR **31/0**, exec **39/0**, 48 XFAIL / 0 XPASS,
harness **26/26**, experiments **14/14**, subtype **47/47**. The corrected
conformance runner proves `45_match_literal_adapts.pie` now passes; its known-
failure entry is removed and the conformance floor tightened in this merge.

Both native suites pass at O0/O1/O2/O3 with **identical per-case outcomes**:
31 PEAR cases and 87 exec checks per tier. Runs used isolated copies of the
same built tree/binary to avoid artifact races; the committed harnesses were
run unchanged, including the qualifier-attribute assertions.

The n3 polish prerequisite also addresses the eight handoff items; see
`docs/dev/AGENT_N3_POLISH.md` for dispositions and limits. Three full legacy
fixtures still hang and the mutable-global fixture still crashes compilation;
these remain explicit XFAIL, not claimed fixes. A small compound-assignment
hang now has its own runtime test. Default gate protects all four canary tiers,
reports real check totals, and runs the semantic subtype specification.

`origin/dev` has advanced by documentation-only `7ce61ec`, with Agent-4's
pre-verification addendum. That is useful evidence for the old queue snapshot,
but is not independent signoff on n3's conformance repair, CLI changes, or the
two newer parameter-capture commits. Final dev landing remains gated on review.

## Third merge candidate — NBE / combined original queue

@agent4 please verify merge `n3/merge-nbe-real` of `theory/nbe-real` at **7beff71**, stacked on the first two verified candidates and the n3 polish commits.

Resolution keeps the NBE side's complete owned/sorted/deduplicated record
constructor, and adds explicit post-allocation ID bounds/type validation with
field-entry cleanup/rollback. Harness-label conflicts retain literal quoting;
all new NBE semantic/record checks remain present.

**Real regression caught and fixed:** NBE's new input guard rejected `tail=-1`,
the existing closed-record API sentinel. The protected semantic subtype spec
failed 2 existing cases (45/47), because both closed records became bottom and
false containment proofs resulted. The constructor now allows -1, still
rejects less-than--1/out-of-range tails, and a dedicated regression tests it.
The 47-case spec is restored to **47/47**, not weakened or rebaselined.

A standalone C3 unit linked against the real compiler modules tests ownership,
sorting, duplicate-field intersections, invalid/null/oversized inputs, node
and field-entry exhaustion, late allocation cleanup, and closed-tail API
compatibility: **10/10**. It is part of make test.

Final build + full gate: exit 0; pfront **172/5**, stdlib **260/260**,
conformance **150/112**, PEAR **31/0**, exec **39/0** (48 XFAIL, 0 XPASS),
harness regressions **27/27**, experiments **14/14**, semantic subtype **47/47**,
record-constructor checks **10/10**. The pfront floor is tightened to 172/5.
Both native suites again have identical per-case outcomes at O0/O1/O2/O3:
31 PEAR cases + 87 exec checks per tier. Nine selected malformed/CLI probes
return their expected non-crashing exit codes.

**Examples measured honestly:** 37/37 emit nonempty AIR, but only **21/37**
compile without errors. Rebuilt original dev source 5e20e0a in an isolated
worktree: the same 21 are error-free and no example's error count regresses.
The 16 erroneous examples are labeled individually in `examples/STATUS.tsv`
and `examples/README.md`; a default harness test now protects the error floors.
This is not a claim that all examples run or produce correct native results.

## Remote coordination blocker — do not silently restore dev history

During the final fetch, origin/dev was **force-rewound from 7ce61ec to a65f86b**.
That drops the mission/pre-verification and other A2A audit docs (10 commits
between a65f86b and original base 5e20e0a; compiler source there is unchanged).
Agent-n3 did not push, force-push, or reset dev. The tested candidate preserves
its original history; landing it would also restore the dropped documents, so
the owner's intended base must be confirmed before doing that.

A new `pear-bro/v0.9.1-multiarg-clause` branch appeared at **8330f31**. It adds
expression-bodied tuple-clause parameter lowering and nullary const auto-call,
with known block/multi-clause limitations. It is **not** in the original
three-branch candidate and has not been verified by n3; queue it explicitly
rather than imply that the live remote has no remaining work.

Independent review requested especially for conformance recalibration, the
newer parameter-capture integration, record bounds/closed-tail compatibility,
and the documented dev-history/base choice. No baseline was lowered to hide a
merge regression; the invalid legacy conformance instrument is separately
explained and its replacement failures remain visible by case.
