#!/usr/bin/env python3
"""pride-lint.py -- static checks on a Pride (.pie) program.

These are the mistakes that cost the most time when a program is written from
docs/pride/ and then handed to a compiler: a tab where the layout parser needs
spaces, a `print` that does not exist, a byte count that disagrees with the
literal next to it, a reserved word used as a name.

Nothing here replaces the compiler. If ./pfrontc exists, the last step runs it
with --emit-air-low, which is the only authoritative answer.

    python3 scripts/pride-lint.py prog.pie [more.pie ...]
    python3 scripts/pride-lint.py --no-compile prog.pie
    python3 scripts/pride-lint.py --docs docs/pride

--docs lints every ```pride block in a directory of markdown, which is how the
documented examples are kept from drifting: 77 blocks, 0 errors.

Exit status: 0 when there are no errors (warnings allowed), 1 otherwise.
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile

# ── rules ───────────────────────────────────────────────────────────────────
# (pattern, severity, message). Severity "error" fails the run.
FORBIDDEN = [
    (r"\bprint\s*\(", "error", "there is no `print` -- write bytes with syscall(1, 1, ptr as i64, len)"),
    (r"\bprintln\s*\(", "error", "there is no `println` -- see syscall(1, 1, ...)"),
    (r"\bformat\s*!", "error", "there is no formatting macro -- print fields one at a time"),
    (r"\bformat\s*\(", "error", "there is no `format` function"),
    (r"\bfunc\b", "error", "the declaration keyword is `fn`, not `func`"),
    (r"::", "error", "Pride has no `::` path syntax -- methods are called with `.`"),
    (r"\bVec\s*<", "error", "the stdlib is not linked -- use [T; N] or a hand-rolled buffer"),
    (r"\bString\b", "error", "the stdlib is not linked -- use *u8 + a length, or [u8]"),
    (r"\buse\s+[A-Za-z_]", "warn", "modules are not exercised in a runnable build -- keep one file"),
    (r"\bdefer\b", "warn", "`defer` is function-scoped, not block-scoped; free explicitly"),
    (r"\bunreachable\b", "warn", "`unreachable` is a promise, not a statement -- a wrong one is UB"),
    (r"\bub\b", "warn", "`ub` is a promise, not a statement"),
    (r"\bmacro\b", "warn", "the metaprogramming layer is not on the executable path"),
    (r"\bquote\b|\bsplice\b", "warn", "quote/splice are not on the executable path"),
    (r"\btensor\b", "warn", "tensors are not on the executable path"),
    (r"\bthread_local\b", "warn", "TLS needs a runtime; single-threaded programs only"),
    (r"\basync\b|\bawait\b", "warn", "no async runtime in a self-contained program"),
]

RESERVED_NAMES = set(
    """macro quote splice stage reify pattern pgen rewrite rule dialect graph
    hyperedge invariant region freeze generate eval lower meta node edge opcode
    constexpr fixpoint tail with by newtype poison runtime irdl unquote
    unchecked""".split()
)

CALL_LIT = re.compile(r'syscall\s*\(\s*1\s*,\s*1\s*,\s*"((?:[^"\\]|\\.)*)"\s*as\s+i64\s*,\s*(\d+)\s*\)')
CALL_RAW = re.compile(r'syscall\s*\(\s*1\s*,\s*1\s*,\s*"')
DECL = re.compile(r"^\s*(?:pub\s+)?(?:fn|struct|enum|union|type|effect|interface|impl|let|const|static)\s+([A-Za-z_][A-Za-z0-9_]*)")
BINDER = re.compile(r"^\s*(?:pub\s+)?(?:let|const|static)\s+(?:mut\s+)?([A-Za-z_][A-Za-z0-9_]*)")


def decode_bytes(text):
    """Byte length of a Pride string literal body, with escapes decoded."""
    out = bytearray()
    i = 0
    while i < len(text):
        c = text[i]
        if c != "\\":
            out.extend(c.encode("utf-8"))
            i += 1
            continue
        i += 1
        if i >= len(text):
            return None
        e = text[i]
        if e == "n":
            out.append(10)
        elif e == "t":
            out.append(9)
        elif e == "r":
            out.append(13)
        elif e == "0":
            out.append(0)
        elif e == "\\":
            out.append(92)
        elif e in '"\'"':
            out.append(ord(e))
        elif e == "x" and i + 2 < len(text):
            try:
                out.append(int(text[i + 1 : i + 3], 16))
            except ValueError:
                return None
            i += 2
        else:
            return None
        i += 1
    return len(out)


def lint(path, findings, text=None, skip_shape=False, line_offset=0):
    if text is None:
        try:
            with open(path, "r", encoding="utf-8") as f:
                text = f.read()
        except OSError as exc:
            findings.append((path, 0, "error", "cannot read: %s" % exc))
            return
    lines = text.split("\n")

    def add(no, sev, msg):
        findings.append((path, no + line_offset if no else 0, sev, msg))

    seen_main = seen_test = seen_header = False
    for no, line in enumerate(lines, 1):
        stripped = line.strip()

        # 1. tabs in indentation: the lexer rejects them outright
        lead = line[: len(line) - len(line.lstrip(" \t"))]
        if "\t" in lead:
            add(no, "error", "tab in indentation -- the lexer rejects it (pfront_lex.c3:749); use spaces")

        if no == 1 and stripped.startswith("-- EXIT:") or stripped.startswith("-- EXIT:"):
            seen_header = True
        if re.match(r"^\s*fn\s+main\b", line):
            seen_main = True
        if re.match(r"^\s*fn\s+self_test\b", line):
            seen_test = True

        code = line.split("--", 1)[0] if "--" in line and '"' not in line.split("--", 1)[0] else line

        # 2. reserved words used as declaration names
        b = BINDER.match(line)
        if b and b.group(1) in RESERVED_NAMES:
            add(no, "error", "`%s` is a reserved word and cannot bind a variable" % b.group(1))
        else:
            m = DECL.match(line)
            if m and m.group(1) in RESERVED_NAMES:
                add(no, "warn", "`%s` is a reserved word: it parses here, but not as a variable or parameter" % m.group(1))

        # 3. syscall(1, 1, "literal" as i64, N): N must be the byte length
        for lm in CALL_LIT.finditer(code):
            body, stated = lm.group(1), int(lm.group(2))
            actual = decode_bytes(body)
            if actual is not None and actual != stated:
                add(
                    no,
                    "error",
                    'byte count %d does not match the literal "%s" (%d bytes)'
                    % (stated, body, actual),
                )
        if CALL_RAW.search(code) and not CALL_LIT.search(code):
            add(no, "warn", 'string buffer passed without `as i64` -- write `"..." as i64`')

    # 4. program shape
    if skip_shape:
        pass
    elif not seen_header:
        findings.append((path, 0, "warn", "no `-- EXIT:` header line -- the test gate reads it"))
    if skip_shape:
        pass
    elif not seen_main:
        findings.append((path, 0, "error", "no `fn main :` declaration"))
    if skip_shape:
        pass
    elif not seen_test:
        findings.append((path, 0, "warn", "no `fn self_test :` -- the only harness a program has is its exit code"))

    # 5. forbidden constructs, over the whole file, line by line
    for no, line in enumerate(lines, 1):
        code = line
        for pat, sev, msg in FORBIDDEN:
            if re.search(pat, code):
                add(no, sev, msg)


def compile_check(path, findings):
    pfrontc = shutil.which("./pfrontc") or ("./pfrontc" if os.path.exists("./pfrontc") else None)
    if pfrontc is None:
        return False

    out = os.path.join(tempfile.gettempdir(), os.path.basename(path) + ".low.air")
    env = dict(os.environ, PFRONT_LOW_OUT=out)
    try:
        proc = subprocess.run(
            [pfrontc, path, "--emit-air-low", "--quiet"],
            capture_output=True,
            text=True,
            timeout=120,
            env=env,
        )
    except OSError as exc:
        findings.append((path, 0, "warn", "pfrontc could not run: %s" % exc))
        return False
    text = (proc.stdout or "") + (proc.stderr or "")
    if proc.returncode != 0 or "errors=0" not in text:
        first = ""
        for line in text.split("\n"):
            if "error" in line.lower():
                first = line.strip()[:160]
                break
        findings.append((path, 0, "error", "pfrontc rejected it: %s" % (first or text.strip()[:160])))
        return True
    return True


BLOCK = re.compile(r"```pride\n(.*?)```", re.S)


def lint_docs(directory, findings):
    """Lint every ```pride block in every .md file under `directory`."""
    import glob

    blocks = 0
    for md in sorted(glob.glob(os.path.join(directory, "*.md"))):
        try:
            with open(md, "r", encoding="utf-8") as f:
                text = f.read()
        except OSError as exc:
            findings.append((md, 0, "error", "cannot read: %s" % exc))
            continue
        for m in BLOCK.finditer(text):
            blocks += 1
            start_line = text[: m.start()].count("\n") + 2   # first line of the block body
            lint(md, findings, text=m.group(1), skip_shape=True, line_offset=start_line - 1)
    return blocks


def main(argv):
    compile_too = True
    docs_dir = None
    paths = []
    args = argv[1:]
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--no-compile":
            compile_too = False
        elif a == "--docs":
            if i + 1 >= len(args):
                print("--docs needs a directory", file=sys.stderr)
                return 2
            docs_dir = args[i + 1]
            i += 1
        elif a in ("-h", "--help"):
            print(__doc__)
            return 0
        elif a.startswith("-"):
            print("unknown option %s" % a, file=sys.stderr)
            return 2
        else:
            paths.append(a)
        i += 1
    if not paths and docs_dir is None:
        print(__doc__)
        return 2
    if docs_dir is not None:
        findings = []
        blocks = lint_docs(docs_dir, findings)
        errors = [f for f in findings if f[2] == "error"]
        findings.sort(key=lambda f: (f[0], f[1]))
        for path, no, sev, msg in findings:
            where = "%s:%d" % (path, no) if no else path
            print("%s: %s: %s" % (where, sev, msg))
        print("\n%d pride block(s) in %s: %d error(s), %d warning(s)"
              % (blocks, docs_dir, len(errors), len(findings) - len(errors)))
        return 1 if errors else 0

    findings = []
    for p in paths:
        lint(p, findings)
        if compile_too:
            compile_check(p, findings)

    errors = [f for f in findings if f[2] == "error"]
    findings.sort(key=lambda f: (f[0], f[1]))
    for path, no, sev, msg in findings:
        where = "%s:%d" % (path, no) if no else path
        print("%s: %s: %s" % (where, sev, msg))
    print(
        "\n%d file(s): %d error(s), %d warning(s)"
        % (len(paths), len(errors), len(findings) - len(errors))
    )
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
