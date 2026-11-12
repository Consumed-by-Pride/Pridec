# Running a Pride program

The documents in this directory describe code; this one describes how to make it
execute. Two consumers exist, and both read the same AIR:

```
prog.pie --pfrontc--> prog.low.air --airtool emit-ll--> prog.ll --LLVM--> prog
                                  \--pear2c-------------------------------> prog
```

`pfrontc` and `airtool` never link LLVM. Only the consumers do, so the front end
can be exercised on any machine while the runnable path needs LLVM 23.

---

## 1. Toolchain (once per machine)

```sh
bash scripts/agent3-env.sh                 # c3c 0.8.4 + C3 stdlib + libLLVM 23 into ~/.cache
bash scripts/agent3-build.sh               # builds ./pfrontc and legacy/pear1/pear1c
export LD_LIBRARY_PATH="$HOME/.cache/llvm23:/usr/lib/x86_64-linux-gnu"
```

`scripts/agent3-env.sh` fetches a static `c3c` and unpacks `libLLVM-23.so` from
the `apt.llvm.org` package; it verifies each by version before use. If you
already have `c3c` 0.8.4 on `PATH`, `make C3C=$(command -v c3c) C3C_LIB=<c3 stdlib>`
skips that step.

Then:

```sh
make            # ./pfrontc
make airtool    # tmp/airtool
make pear2c     # pear2/pear2c + ./pear2c symlink   (needs libLLVM-23.so)
```

`make pear2c` refuses to start unless `$(LLVM23_LIBDIR)/libLLVM-23.so` exists —
that check is there because a `pear2c` linked against a different LLVM loads and
then corrupts optimisation, which is much harder to diagnose.

**LLVM 23 is not interchangeable with 19 or 20.** The `c3c` 0.8.4 pass pipeline
uses LLVM-23 attribute numbering; against LLVM 19 the compiler links but every
`-O1`/`-O2` build crashes inside `InstCombinePass`. See the comment block at the
top of the `Makefile`.

---

## 2. One program, end to end

```sh
# 1. parse, resolve, type check, lower  (no LLVM; the artifact is FILE.low.air)
./pfrontc prog.pie --emit-air-low --quiet

# 2. the AIR 3.0 low profile is well formed
tmp/airtool verify-low prog.low.air

# 3. the reference consumer: AIR -> LLVM IR -> object -> executable
tmp/airtool emit-ll prog.low.air -o prog.ll
python3 scripts/ll-exe.py prog.ll -o prog -O2
./prog; echo "exit=$?"
```

Step 1 is the cheapest possible feedback and the only one that works without
LLVM: if `pfrontc` prints `errors=0` and writes `prog.low.air`, the program is
inside the language. Steps 2 and 3 answer "does it run".

When step 1 fails, it prints the source construct the lowering has not reached
yet. That diagnostic is the definition of "outside the executable subset" — it is
the same check `docs/pride/EXECUTABLE_SUBSET.md` was written against.

`prog.low.air` lands next to the source. Set `PFRONT_LOW_OUT=path.air` to put it
elsewhere, which is what `tests/air3/low_corpus.sh` does.

---

### 2b. Before that: the static checks

```sh
python3 scripts/pride-lint.py prog.pie            # checks + pfrontc, if ./pfrontc exists
python3 scripts/pride-lint.py --no-compile prog.pie
```

It catches the mistakes that cost the most turns — a tab in indentation (the lexer
rejects it outright), `func` instead of `fn`, `print`/`println`/`format`, `::`,
a `syscall` string whose byte count disagrees with the literal next to it, a
keyword used as a variable, a missing `main`, no `-- EXIT:` header. Over the 35
must-pass programs in `tests/air3/prog/` it reports zero errors; that is the
false-positive budget it was written to.

---

## 3. The same AIR through the `.bc` backend (`pear2c`)

```sh
make pear2c
./pear2c prog.low.air                  # default mode is --emit-exe: writes prog.low, a linked executable
./pear2c prog.low.air --emit-ll        # writes prog.low.ll
./pear2c prog.low.air --emit-bc        # writes prog.low.bc
./pear2c prog.low.air --check          # verifier only, no artifact
./pear2c prog.low.air --probe          # run the whole emitter, write nothing
```

There is **no `-o`**: every output name is derived from the input by swapping the
extension (`pear2/pear2c_main.c3:6584`). `--emit-exe` produces the executable
directly (it links with the runtime it was built against).

`pear2c` also has a native path that never enters LLVM:

```sh
./pear2c prog.low.air --emit-native --native-entry   # writes prog.low.o
ld prog.low.o -o prog.low && ./prog.low              # no libc, no crt
```

`--native-entry` adds a `_start` that calls `main` and exits with its result, so
`ld` alone produces a runnable binary. This is the path the project exists for;
the LLVM path is what its correctness is measured against.

---

## 4. The gates

```sh
make test-air3        # 35 air3 programs must pass; exec corpus floor 84/96; stdlib floor 260
make test-lowering    # tests/lowering: exit code + verifier counts per case
make test-exec        # legacy PEAR 1 chain, tests/exec + XFAIL.tsv
make check-pear2      # type-check + fixture gate for the pear2 sources
make test-pear2-corpus   # run the corpus through pear2c and diff against the gate
```

`make test-air3` is the one that decides whether a program written to these
documents is real: `tests/air3/gate.sh` fails on any `VERIFY`, `LLVM`, or
`WRONG` result, on any `prog/` program that does not pass, and on a drop below
the recorded floors in `tests/air3/GATE_FLOORS`.

`make test-pear2-corpus` is the one that decides whether the `.bc` backend can
carry such a program. Until that target has been run green, a program here is
proven for the `airtool emit-ll` consumer only.

---

## 5. What was and was not possible where these documents were written

The sandbox that produced `SYNTAX.md`, `EXECUTABLE_SUBSET.md`, `AI_BRIEF.md`,
`COOKBOOK.md`, and `examples/pride/template.pie` had no LLVM and no way to fetch
it: `c3c` there could type-check, but not link. So:

* **done there:** every claim was checked against `pfront/pfront_lex.c3`,
  `pfront/pfront_parse.c3`, the lowering in `pfront/pear_ir/air_low.c3`, and the
  test corpus — i.e. against source, not against a run.
* **not done there:** no `.pie` file from these documents has been compiled,
  lowered, or executed.
* **first thing to run here:** `./pfrontc examples/pride/template.pie --emit-air-low`,
  then the four steps in §2.

Treat the example as a hypothesis that the first real run confirms or refutes.
The subset document marks which parts are strong (backed by a must-pass test) and
which are narrow.

---

## 6. When it breaks

| symptom | cause | fix |
|---|---|---|
| `error while loading shared libraries: libLLVM-23.so` | `LD_LIBRARY_PATH` not set | export it, as in §1 |
| `No backends available` from `c3c compile` | that `c3c` was built without LLVM | use the static release `c3c` from `scripts/agent3-env.sh`; it can link programs |
| `PEAR2 requires LLVM 23 C API at …` | `libLLVM-23.so` missing where the Makefile looks | run `scripts/agent3-env.sh`, or `make pear2c LLVM23_DIR=…` |
| `pfrontc` prints `errors=N` and writes no `.low.air` | the program uses a construct outside the executable subset | read the diagnostic; `EXECUTABLE_SUBSET.md` §2 lists the known ones |
| `airtool verify-low` rejects the file | a lowering bug, not a program bug | report it with the `.low.air` attached |
| the program builds and exits 0 but prints nothing | output went somewhere else, or `syscall` argument order is wrong | `syscall(1, 1, ptr as i64, len)`; see `SYNTAX.md` §9.3 |
| exit status is 0 but a `self_test` check failed | the failure code was added to a local that was never returned | return the accumulator; see `AI_BRIEF.md` §10 |
