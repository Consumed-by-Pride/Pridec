# Tokei-Pride

A Tokei-inspired source statistics program written in Pride. The source is
split into small modules so it is useful both as a sizeable front-end workload
and as a realistic example of directory traversal, file I/O, aggregate state,
lexical scanning, CLI parsing, and text/JSON reporting.

## Build and run

From the repository root:

```sh
make
make test-tokei                       # front-end stress/compile contract
scripts/pie-exe.sh examples/tokei/main.pie -O0 -I examples -I stdlib
./examples/tokei/main --self-test     # after building the executable
./examples/tokei/main --json .
./examples/tokei/main --files --sort=code src
```

The Pride modules themselves are over five thousand lines, including the
reachable `stress.pie` module: 350 distinct functions feed seven batched call
graphs so the normal compile path exercises parsing, type checking, name lookup,
and lowering at scale. The 97 files under `fixtures/` are a separate, diverse
lexer input corpus, not all intended to be valid executable programs. Running
Tokei-Pride on that directory exercises the extension catalogue and scanner over
more than three thousand additional lines of input.

## Current feature set

- Recursive Linux directory traversal through `fs.dir_iter`, `fs.meta` and
  `fs.file`; depth is bounded to avoid symlink and pathological-tree recursion.
- Default exclusions for common VCS, dependency, build and cache directories;
  `--hidden` and `--no-ignore` make the traversal policy explicit.
- 97 language families and 189 extension aliases, with language-specific line
  and block comment markers, nested-block handling where applicable, quoted
  delimiter protection, CRLF handling, and TODO/FIXME/HACK/XXX detection.
- Per-file and per-language code/comment/blank/byte/TODO counts, stable sorting,
  aggregate text output, and JSON output.
- `--self-test` runs scanner invariants plus a marker probe across the complete
  language catalogue.

## Deliberate scope limits

This is a test-oriented clone, not a claim of byte-for-byte Tokei parity. It
uses a compact lexical state machine rather than full parsers, so language
constructs such as Python docstrings, raw/interpolated strings, and embedded
languages can be ambiguous. The initial implementation counts UTF-8 bytes for
lexical delimiters, does not read `.tokeignore` or `.gitignore`, has no glob
exclude syntax, and retains whole file contents while scanning. Those are
excellent follow-up stress tasks once this source compiles and runs on the
current toolchain.
