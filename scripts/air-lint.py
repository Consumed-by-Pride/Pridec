#!/usr/bin/env python3
"""AIR "low profile" progress meter.

Compiles every program of the working corpus with pfrontc --emit-air and runs
`airtool lint -e` (entry module only) on the result. Prints, per rule of
pfront/pear_ir/air_lint.c3, the total number of deficiencies and the number of
programs that still have at least one. Target (docs/pear2/AIR3_PLAN.md): every row 0.

Usage: python3 scripts/air-lint.py [-v] [--save tests/air/LINT_BASELINE.tsv] [--check tests/air/LINT_BASELINE.tsv]
  --check  exit 1 if any rule got WORSE than the recorded baseline (improvements are reported, not failed)
"""
import glob, os, re, shutil, subprocess, sys, tempfile
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(root)
env = dict(os.environ, LD_LIBRARY_PATH=os.path.expanduser("~/.cache/llvm23") + ":/usr/lib/x86_64-linux-gnu")
srcs = sorted(glob.glob("tests/exec/*.pie") + glob.glob("tests/exec/pear/*.pie") + glob.glob("tests/lowering/*.pie"))
work = tempfile.mkdtemp(prefix="airlint-")
tot, progs, verbose = {}, {}, "-v" in sys.argv
n = skipped = 0
for s in srcs:
    name = s.replace("/", "_")[:-4]
    d = os.path.join(work, name + ".pie"); shutil.copy(s, d)
    subprocess.run(["./pfrontc", d, "--emit-air", "--quiet"], env=env, capture_output=True, timeout=120)
    a = d[:-4] + ".air"
    if not os.path.exists(a): skipped += 1; continue
    r = subprocess.run(["tmp/airtool", "lint", a, "-e"], env=env, capture_output=True, text=True)
    m = re.match(r"lint: (\d+) \|(.*)", r.stdout.strip())
    if not m: skipped += 1; continue
    n += 1
    for part in m.group(2).split(";"):
        part = part.strip()
        if not part: continue
        k, v = part.rsplit("=", 1); v = int(v)
        tot[k] = tot.get(k, 0) + v
        if v: progs[k] = progs.get(k, 0) + 1
        if verbose and v: print(f"  {name}: {k} = {v}")
shutil.rmtree(work, ignore_errors=True)
print(f"AIR lint: {n} programs linted ({skipped} emit no .air), entry modules only")
print(f"{'rule':34} {'total':>7} {'programs':>9}")
rows = []
for k in tot:
    print(f"{k:34} {tot[k]:7d} {progs.get(k,0):9d}"); rows.append((k, tot[k], progs.get(k, 0)))
print(f"{'ALL':34} {sum(tot.values()):7d}")
def load(p):
    b = {}
    for l in open(p):
        if l.startswith("#") or not l.strip(): continue
        k, t, g = l.rstrip("\n").split("\t"); b[k] = (int(t), int(g))
    return b
if "--save" in sys.argv:
    p = sys.argv[sys.argv.index("--save") + 1]
    with open(p, "w") as f:
        f.write("# tests/air/LINT_BASELINE.tsv -- scripts/air-lint.py result. Columns: rule | deficiencies | programs affected.\n# Only ever goes DOWN (docs/pear2/AIR3_PLAN.md); regenerate with --save after a real improvement.\n")
        for k, t, g in rows: f.write(f"{k}\t{t}\t{g}\n")
if "--check" in sys.argv:
    b = load(sys.argv[sys.argv.index("--check") + 1]); bad = 0
    for k, t, g in rows:
        bt, bg = b.get(k, (0, 0))
        if t > bt: print(f"WORSE {k}: {t} > baseline {bt}"); bad += 1
        elif t < bt: print(f"better {k}: {t} < baseline {bt} (run --save)")
    sys.exit(1 if bad else 0)
