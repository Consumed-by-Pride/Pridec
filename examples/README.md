# Example status — current pfront, 2026-09-30

These examples are a mix of working front-end examples and preserved language
showcases. **They are not all runnable native demonstrations.**

Agent-n3 measured both the original dev compiler source (`5e20e0a`) and the
combined integration candidate, using `--emit-air --quiet`:

- **21 / 37 compile without errors** (warnings may remain).
- **16 / 37 still report compiler errors**; see the per-file `STATUS.tsv`.
- **37 / 37 emit nonempty AIR**, including the erroneous inputs. AIR emission
  is allowed for diagnostic inspection, so an `.air` file existing is **not**
  proof of successful compilation or runtime support.
- No example gains a compile error in the combined candidate vs original dev.
- This sweep does **not** execute native examples or certify their results.
  For current native regression coverage, use `tests/exec/` and `make test`.

`STATUS.tsv` records actual errors/warnings/exit codes, not checkmarks inferred
from artifacts. The default harness checks all 37 against these error floors
and rejects compiler crashes or missing summaries. Existing broken showcases
remain visible and need explicit fixes/policy decisions; their status is not
silently promoted to runnable.

To inspect one example's actual diagnostics:

```sh
export LD_LIBRARY_PATH="$HOME/.cache/llvm23:/usr/lib/x86_64-linux-gnu"
./pfrontc examples/effect_demo.pie --plain
```
