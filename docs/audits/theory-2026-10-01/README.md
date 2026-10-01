# Theory audit — pinned targets and evidence

Read [REPORT.md](REPORT.md) first, then [MODULE_MATRIX.md](MODULE_MATRIX.md).
Targets: current dev `fcc862f`, proposed PR #17 compiler `7e25543`.
This is an audit/report branch: compiler code and normal baselines are unchanged.

The TSV/JSON files are measured results and the IR files are consumer witnesses.
Raw IR is from a separately built audit-only compiler with the one-line
`raw-instrumentation.diff`; no theory code is instrumented. Native tests and
performance use the shipping compiler. The complete local logs/scripts/data
are under `/home/user/theory-audit` in the shared workspace.

Minimal source repros are in `repros/`. From a clone with the documented toolchain:

```sh
bash scripts/agent3-env.sh
bash scripts/agent3-build.sh
export LD_LIBRARY_PATH="$HOME/.cache/llvm23:/usr/lib/x86_64-linux-gnu"
./pfrontc docs/audits/theory-2026-10-01/repros/capture_store.pie --emit-bc --lint
./pfrontc docs/audits/theory-2026-10-01/repros/capture_store.pie --emit-bc --lint --no-theory
```

Inspect the function's parameter capture attributes and the outgoing pointer-address
store; a main returning 42 is only a control and not a soundness test for retention.
The REPORT distinguishes observed bad contracts, demonstrated runtime behavior,
unsupported backend behavior, and conclusions supported only by source tracing.
