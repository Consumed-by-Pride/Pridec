#!/usr/bin/env python3
"""Run `pfrontc --emit-air --air-audit` over a source list and aggregate the
constructs the AIR lowering never consumed (see pfront/pear_ir/air_audit.c3).

usage: air-audit.py [--list FILE] [--all] [--show KIND] [--jobs N] [--json OUT]
  default list: every source of tests/exec, tests/exec/pear, tests/pfront, examples
  --all    include library modules (prelude/stdlib) in the aggregate
"""
import subprocess, sys, os, re, collections, argparse, concurrent.futures as cf, json, glob

ap = argparse.ArgumentParser()
ap.add_argument('--list'); ap.add_argument('--all', action='store_true')
ap.add_argument('--show'); ap.add_argument('--jobs', type=int, default=2)
ap.add_argument('--json'); ap.add_argument('--pfrontc', default='./pfrontc')
a = ap.parse_args()
env = dict(os.environ, LD_LIBRARY_PATH=os.path.expanduser('~/.cache/llvm23') + ':/usr/lib/x86_64-linux-gnu')
if a.list:
    srcs = [l.strip() for l in open(a.list) if l.strip()]
else:
    srcs = []
    for g in ('tests/exec/*.pie', 'tests/exec/pear/*.pie', 'tests/pfront/*.pie', 'examples/*.pie'):
        srcs += sorted(glob.glob(g))

def run(src):
    try:
        r = subprocess.run([a.pfrontc, src, '--emit-air', '--air-audit', '--quiet'], capture_output=True, text=True, env=env, timeout=120)
    except subprocess.TimeoutExpired:
        return src, None, 'timeout'
    pend, out, compiled, skp = [], [], True, []
    for l in r.stdout.splitlines():
        m = re.match(r'air-audit: UNLOWERED (\S+) (\d+):(\d+) under (\S+) in (.*)', l)
        if m: pend.append((m.group(1) + '<' + m.group(4), int(m.group(2)), int(m.group(3)), m.group(5))); continue
        m = re.match(r'air-audit: SKIPPED (\S+) (\S+) (\d+):(\d+)', l)
        if m: skp.append((m.group(1), m.group(2), int(m.group(3)))); continue
        m = re.match(r'air-audit: MODULE (entry|library) (\S+) examined=(\d+) unlowered=(\d+)', l)
        if m:
            out.append((m.group(1), m.group(2), int(m.group(3)), pend, skp)); pend = []; skp = []
    return src, out, None if out else 'no-air'

agg = collections.Counter(); files = collections.defaultdict(set); ex = collections.defaultdict(list)
examined = 0; nprog = 0; skipped = []; skipped_by = collections.Counter()
with cf.ThreadPoolExecutor(a.jobs) as pool:
    for src, mods, err in pool.map(run, srcs):
        if err: skipped.append((src, err)); continue
        nprog += 1
        for kind, name, n, items, skips in mods:
            if kind == 'library' and not a.all: continue
            examined += n
            for why, _k, _l in skips: skipped_by[why] += 1
            for k, l, c, m in items:
                agg[k] += 1; files[k].add(src if kind == 'entry' else m)
                if kind == 'library': k = k
                key = (kind[0] + ':' + k)
                if len(ex[k]) < 400: ex[k].append(f'{src if kind == "entry" else m}:{l}:{c}')
print(f'programs audited: {nprog}   skipped (front-end errors / no .air): {len(skipped)}   constructs examined: {examined}')
tot = sum(agg.values())
print(f'UNLOWERED constructs: {tot}')
print('deliberately not lowered (entry modules): ' + ', '.join(f'{k} {v}' for k, v in sorted(skipped_by.items())) + '   [compile-time-only = rewrite/IRDL rule clauses; name-collision = libc write/malloc/free]')
for k, n in agg.most_common():
    print(f'  {k:18} {n:6}  in {len(files[k])} programs   e.g. {ex[k][0]}')
if a.show:
    for e in ex[a.show]: print(e)
if a.json: json.dump({'programs': nprog, 'examined': examined, 'unlowered': dict(agg), 'examples': ex}, open(a.json, 'w'), indent=1)
