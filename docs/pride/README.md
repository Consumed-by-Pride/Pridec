# Pride language documentation

Four files, in the order you should read them.

| file | what it is | when to read it |
|---|---|---|
| [`AI_BRIEF.md`](AI_BRIEF.md) | a self-contained, paste-ready brief: the language, the runnable subset, the required program shape, and the rules | when another model (or a person) is about to write a Pride program |
| [`SYNTAX.md`](SYNTAX.md) | the syntax book: lexical structure, types, declarations, statements, expressions, operators and precedence, patterns, builtins, modules, grammar | when you need to know what the language *is* |
| [`EXECUTABLE_SUBSET.md`](EXECUTABLE_SUBSET.md) | what actually compiles and runs, with the test that proves each feature, and an explicit do-not-use list | before writing anything meant to run |
| [`COOKBOOK.md`](COOKBOOK.md) | recipes: printing, collections, sorting, hashing, strings, error codes | while writing the body of a program |

Start with `EXECUTABLE_SUBSET.md`. `SYNTAX.md` describes the whole language;
the subset describes the part of it a program can currently be built from, and
the difference between the two is the single most important fact in this
directory.

## Ground rules

These apply to every file here.

1. **Grounded in the implementation.** Statements about syntax come from
   `pfront/pfront_lex.c3` and `pfront/pfront_parse.c3`; statements about what runs
   come from the programs under `tests/` that a gate executes.
2. **No aspirational syntax.** If a form is documented here as runnable, a test
   in this repository builds and runs it. Where a construct parses but is not on
   the execution path, it is marked as such.
3. **The gap is named.** Missing capability is listed rather than glossed over —
   the standard library, growable strings, run-time allocation sizes from source,
   and the `.bc` backend's unexecuted state are all stated where they matter.

## What is proven, in one paragraph

`pfrontc --emit-air-low` lowers a `.pie` file to AIR 3.0; an LLVM consumer turns
that into a module and a program. 35 programs in `tests/air3/prog/` must pass
that gate completely, and at least 84 of the 96 in `tests/exec/` must pass, with
no wrong answers, no verifier rejections, and no link failures. Those 119
programs — largest 211 lines (`tests/air3/prog_os/mini_os.pie`) — are the
standard the documents here are written against. The `pear2c` `.bc` backend
reads the same AIR and covers every tag the lowering emits, but no LLVM exists in
the workspace it was written in, so it has never run a program;
`make test-pear2-corpus` is the command that would close that gap.

## Related documents

* `docs/reference/v.md` — the long-form design reference. Aspirational in places;
  useful for intent, not for what compiles.
* `docs/pear2/COMPLETENESS.md` — what "the backend is complete" means, measured.
* `docs/pear2/AIR3_PLAN.md` — the AIR 3.0 low profile the backend consumes.
* `examples/pride/template.pie` — a starter program built from the proven subset.
