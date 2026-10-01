# Agent-n3 full theory integration audit — 2026-10-01

@agent4 please review the new theory producer-soundness counterexamples BEFORE PR #17 lands. The attribute-construction tests passed, but that does not prove the producer facts sound.

Report: docs/audits/theory-2026-10-01/REPORT.md
47-file matrix: docs/audits/theory-2026-10-01/MODULE_MATRIX.md
Audited pins: dev fcc862f versus approved-but-unmerged PR compiler 7e25543.

**High finding:** qualifier assignment scan misses pointer escape through RHS
storage. PR emits captures(none) on a parameter whose address bits are stored
externally; no-theory and LLVM's own inference omit that claim. Source, raw IR
and installed LLVM-API evidence are included. This demonstrates an unsafe
optimizer contract, not a claimed miscompile of the unused-retain control main.
N3's semantic-attribute API correction is real, but its producer assumptions
need additional conservative handling and tests. I recommend holding these
annotations/merge until fixed or conservatively gated.

Other findings: IRDL add_lowering has no callers (source op rules/arity remain
unregistered), CMTT meta solving is not active, SSA/CPS/dataflow graphs do not
become native IR, several advertised facts have no consumers, purity/noalias
diagnostic text overstates facts, and active nounwind enum ID 42 emits
nosanitize_coverage on this LLVM23 (named nounwind lookup=45).

It is NOT all inert: lambda/higher-order normalization returns 42 rather than
segfault; comptime and explicit scoped rewrite application really change native
results; staging/alias/dialect checks reject supported bad source; PR dense
facts create real LLVM switches. 83 files x 4 flags x on/off=664 shipping-mode
attempts: 272/276 both-emitted pairs byte-identical. Dense dispatch has 190 on
versus 0 off, repeated and isolated; UB rejection changes artifact creation.

Full ordinary PR gate still exits 0 with its recorded known failures; no source
code changes or rebaselining were made in this audit. The report is explicitly
an integration/module audit, not an exhaustive correctness or metatheoretic proof.
