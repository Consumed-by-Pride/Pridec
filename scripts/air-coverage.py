#!/usr/bin/env python3
"""Which AIR 2.0 forms the real producer emits, and how often.

Reads .air files (default: tmp/air-test/*.air, the corpus tests/air/run.sh emits) and counts
every production of the grammar in docs/specs/AIR.md in two scopes:

  user     the entry module only (the part of the file before the first `module NAME;` line,
           i.e. the program the author wrote)
  library  everything else (prelude + stdlib, identical in every file; counted once)

A backend (PEAR 2) uses it to see what it must handle first, and which forms the front end
never produces at all (so they cannot be tested against real output yet).
Usage: python3 scripts/air-coverage.py [-o docs/pear2/COVERAGE.md] [files...]
"""
import re, sys, glob, collections

FORMS = [  # (group, label, regex matched against text with strings removed)
 ("command", "cut  <p | k>",            r"<"),
 ("command", "mu NAME.  (command)",     r"(?m)^\s*mu\s+[%\w`]+\.\s*$"),
 ("command", "mu~ NAME.",               r"\bmu~\s"),
 ("command", "seq { c ; c }",           r"\bseq\s*\{"),
 ("command", "if p then c else c",      r"\bif\s"),
 ("command", "match p { ... }",         r"\bmatch\s(?!dense)"),
 ("command", "match dense p { ... }",   r"\bmatch dense\b"),
 ("command", "let x = p in c",          r"\blet\s(?!rec)"),
 ("command", "letrec (...) in c",       r"\bletrec\b"),
 ("command", "while p do { c }",        r"\bwhile\s"),
 ("command", "for x in p do { c }",     r"\bfor\s"),
 ("command", "label L(...). c",         r"\blabel\s"),
 ("command", "jump L(...)",             r"\bjump\s"),
 ("command", "break L / continue L",    r"\b(break|continue)\s"),
 ("command", "block/unsafe/unchecked/comptime/defer { c }", r"\b(block|unsafe|unchecked|comptime|defer)\s*\{"),
 ("command", "handle { c } { ... }",    r"\bhandle\s*\{"),
 ("command", "perform OP(p)",           r"\bperform\s"),
 ("command", "resume(p)",               r"\bresume\("),
 ("command", "assert(p) / assume(p)",   r"\b(assert|assume)\("),
 ("command", "ret(p)",                  r"\bret\("),
 ("command", "ub / trap / nop",         r"\b(ub|trap|nop)\b"),
 ("command", "asm",                     r"\basm\b"),
 ("command", "syscall p(...)",          r"\bsyscall\s"),
 ("command", "atomic OP ORDER(p) / fence", r"\b(atomic|fence)\s"),
 ("producer", "con C(...)",             r"\bcon\s"),
 ("producer", "tuple(...)",             r"\btuple\("),
 ("producer", "array(...)",             r"\barray\("),
 ("producer", "record{f = p}",          r"\brecord\{"),
 ("producer", "inl[T](p) / inr[T](p)",  r"\b(inl|inr)\["),
 ("producer", "lam(...). c",            r"\blam\("),
 ("producer", "mu x. c  (producer)",    r"[|<(,]\s*mu\s"),
 ("producer", "cometa(...). c",         r"\bcometa\("),
 ("producer", "binary operation (op a b)", r"\((add|sub|mul|div|mod|and|or|xor|shl|shr|land|lor|eq|neq|lt|gt|le|ge|pipe)\s"),
 ("producer", "unary operation (op a)", r"\((neg|not|bitnot|deref|ref|addr|comult)\s"),
 ("producer", "coerce / sizeof / alignof / offsetof", r"\b(coerce|sizeof|alignof|offsetof)\("),
 ("producer", "reify / quote / eval / splice", r"\b(reify|quote|eval\(|splice\()"),
 ("producer", "poison(T) / unreachable", r"\bpoison\(|\bunreachable\b"),
 ("producer", "char(N)",                r"\bchar\("),
 ("producer", "string \"...\" / bytes b\"...\"", r"\"|\bb\""),
 ("consumer", "covariable  k",          r"%\w+"),
 ("consumer", "stack  p · k  (call args)", r"call\s"),
 ("consumer", "field NAME #i · k",      r"\bfield\s"),
 ("consumer", "index(p; size) · k",     r"\bindex\("),
 ("consumer", "store(p; size) · k",     r"\bstore\("),
 ("consumer", "as(T) · k",              r"\bas\("),
 ("consumer", "fst/snd/proj i · k",     r"\b(fst|snd|proj)\b"),
 ("consumer", "deref/default/share/erase · k", r"\b(deref|default|share|erase)\s"),
 ("consumer", "case { ... } / case dense", r"\bcase\s"),
 ("consumer", "cocase { ... }",         r"\bcocase\b"),
 ("consumer", "comu x. c",              r"\bcomu\s"),
 ("pattern", "bind x / _ ",             r"\bbind\s"),
 ("pattern", "tuple(...) pattern (clause head)", r"\btuple\([^\n]*\)\s*->"),
 ("pattern", "ctor C(...) pattern",     r"\bctor\s"),
 ("pattern", "or(p, q) / as(p, x) / ref(p) / rest / record{...}", r"\b(or|ref|rest)\b"),
 ("declaration", "def",                 r"^(?:facts \w+ )?(?:readonly )?(?:pub )?def\s"),
 ("declaration", "defco",               r"\bdefco\s"),
 ("declaration", "declare / extern declare", r"\bdeclare\s"),
 ("declaration", "data",                r"^(?:pub )?data\s"),
 ("declaration", "codata",              r"^(?:pub )?codata\s"),
 ("declaration", "effect",              r"^(?:pub )?effect\s"),
 ("declaration", "import",              r"^import\s"),
]

def strip(text):
    text = re.sub(r"//[^\n]*", "", text)
    return re.sub(r'b?"(?:[^"\\\n]|\\.)*"', '""', text)

def split_scopes(text):
    m = re.search(r"(?m)^module\s", text)
    return (text[:m.start()], text[m.start():]) if m else (text, "")

def main(argv):
    out = None
    files = []
    i = 0
    while i < len(argv):
        if argv[i] == "-o": out = argv[i + 1]; i += 2
        else: files.append(argv[i]); i += 1
    files = files or sorted(glob.glob("tmp/air-test/*.air"))
    if not files:
        sys.exit("no .air files (run: bash tests/air/run.sh)")
    user = collections.Counter(); userfiles = collections.Counter(); lib = collections.Counter()
    lib_done = False
    for f in files:
        raw = open(f, encoding="utf-8").read()
        u, l = split_scopes(raw)
        u, l = strip(u), strip(l)
        for g, label, rx in FORMS:
            flags = re.M if rx.startswith("^") else 0
            n = len(re.findall(rx, u, flags))
            user[label] += n
            if n: userfiles[label] += 1
        if not lib_done:
            for g, label, rx in FORMS:
                flags = re.M if rx.startswith("^") else 0
                lib[label] += len(re.findall(rx, l, flags))
            lib_done = True
    lines = ["# AIR forms the front end actually emits", "",
             "_Generated by `scripts/air-coverage.py` from %d `.air` files (the corpus `tests/air/run.sh` emits). "
             "Counts are textual matches of the grammar in `docs/specs/AIR.md`; they are a guide to priorities, "
             "not a proof of absence._" % len(files), "",
             "`user` = the entry module of each program (summed over the corpus; `files` = programs using the form). "
             "`library` = prelude + stdlib, identical in every file (counted once).", "",
             "| group | form | user occurrences | user files | library occurrences |", "|---|---|---:|---:|---:|"]
    for g, label, rx in FORMS:
        lines.append("| %s | `%s` | %d | %d | %d |" % (g, label.replace("|", "\\|"), user[label], userfiles[label], lib[label]))
    never = [l for g, l, rx in FORMS if user[l] == 0 and lib[l] == 0]
    lines += ["", "## Forms never produced (cannot be tested against real front-end output yet)", ""]
    lines += ["- `%s`" % l for l in never] or ["- (none)"]
    text = "\n".join(lines) + "\n"
    if out: open(out, "w", encoding="utf-8").write(text)
    else: sys.stdout.write(text)

main(sys.argv[1:])
