"""IRDL dialect lowering is real, mandatory, and refuses what it cannot lower.

Each case compiles Pride source to a native executable at O0-O3 with the theory
layer on AND off. Lowering is semantics, so both modes must agree.
"""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
BIN = ROOT / 'pfrontc'
ENV = {**os.environ, 'LD_LIBRARY_PATH': str(Path.home()/'.cache/llvm23') + ':/usr/lib/x86_64-linux-gnu'}
MODES = [(tier, theory) for tier in ('-O0', '-O1', '-O2', '-O3') for theory in (True, False)]


@unittest.skipUnless(BIN.is_file(), 'build pfrontc first')
class IrdlLoweringTests(unittest.TestCase):
    def build(self, text, tier='-O2', theory=True):
        folder = tempfile.TemporaryDirectory(prefix='n3-irdl-')
        self.addCleanup(folder.cleanup)
        source = Path(folder.name)/'probe.pie'
        source.write_text(text)
        args = [str(BIN), str(source), '--emit-exe', '--plain', tier] + ([] if theory else ['--no-theory'])
        run = subprocess.run(args, cwd=ROOT, env=ENV, capture_output=True, text=True, timeout=60)
        exe = source.with_suffix('')
        return run, exe

    def expect_exit(self, text, want):
        for tier, theory in MODES:
            with self.subTest(tier=tier, theory=theory):
                run, exe = self.build(text, tier, theory)
                self.assertEqual(run.returncode, 0, run.stdout[-1500:] + run.stderr[-800:])
                self.assertTrue(exe.is_file(), 'no executable emitted')
                got = subprocess.run([str(exe)], timeout=10).returncode
                self.assertEqual(got, want)

    def expect_error(self, text, code):
        for tier, theory in MODES:
            with self.subTest(tier=tier, theory=theory):
                run, exe = self.build(text, tier, theory)
                self.assertNotEqual(run.returncode, 0, 'must be rejected: ' + run.stdout[-800:])
                self.assertFalse(exe.exists(), 'must not emit a binary for a rejected dialect use')
                self.assertIn(str(code), run.stdout + run.stderr)

    def test_registered_rule_computes_the_value(self):
        self.expect_exit('''dialect D
  opcode add
irdl
  D.add [a, b] ↦ a + b
fn main(_) -> i64 { return D.add(20, 22); }
''', 42)

    def test_dialect_to_dialect_fixpoint(self):
        self.expect_exit('''dialect High
  opcode twice
dialect Low
  opcode add
irdl
  High.twice [a] ↦ Low.add(a, a)
  Low.add [a, b] ↦ a + b
fn main(_) -> i64 { return High.twice(21); }
''', 42)

    def test_literal_patterns_are_first_match_and_wildcard_works(self):
        self.expect_exit('''dialect A
  opcode mul
irdl
  A.mul [a, 0] ↦ 0
  A.mul [a, 1] ↦ a
  A.mul [a, b] ↦ a * b
  A.mul [_, _] ↦ 99
fn f(x: i64) -> i64 { return A.mul(x, 1); }
fn g(x: i64) -> i64 { return A.mul(x, 0); }
fn main(_) -> i64 { return f(40) + g(7) + A.mul(1, 2); }
''', 42)

    def test_operand_order_is_simultaneous_not_textual(self):
        self.expect_exit('''dialect D
  opcode sub
irdl
  D.sub [a, b] ↦ a - b
fn f(a: i64, b: i64) -> i64 { return D.sub(b, a); }
fn main(_) -> i64 { return f(10, 52); }
''', 42)

    def test_pure_operand_may_be_duplicated(self):
        self.expect_exit('''dialect D
  opcode sq
irdl
  D.sq [a] ↦ a * a
fn main(_) -> i64 { return D.sq(6) + 6; }
''', 42)

    def test_effectful_operand_used_exactly_once_is_allowed(self):
        self.expect_exit('''dialect D
  opcode inc
irdl
  D.inc [a] ↦ a + 1
fn forty_one() -> i64 { return 41; }
fn main(_) -> i64 { return D.inc(forty_one()); }
''', 42)

    def test_use_without_a_rule_is_an_error_not_a_zero(self):
        self.expect_error('''dialect D
  opcode add : i64
fn main(_) -> i64 { return D.add(20, 22); }
''', 3412)

    def test_no_rule_for_these_operands_is_an_error(self):
        self.expect_error('''dialect D
  opcode add
irdl
  D.add [a, 0] ↦ a
fn main(_) -> i64 { return D.add(20, 22); }
''', 3412)

    def test_wrong_operand_count_is_rejected(self):
        self.expect_error('''dialect D
  opcode add
irdl
  D.add [a, b] ↦ a + b
fn main(_) -> i64 { return D.add(1, 2, 3); }
''', 3211)

    def test_rule_for_undeclared_dialect_or_opcode(self):
        self.expect_error('''dialect D
  opcode add
irdl
  Nope.add [a] ↦ a
fn main(_) -> i64 { return 0; }
''', 3413)
        self.expect_error('''dialect D
  opcode add
irdl
  D.sub [a] ↦ a
fn main(_) -> i64 { return 0; }
''', 3413)

    def test_duplicate_operand_name_is_rejected(self):
        self.expect_error('''dialect D
  opcode add
irdl
  D.add [a, a] ↦ a
fn main(_) -> i64 { return D.add(1, 2); }
''', 3414)

    def test_rule_arity_must_agree(self):
        self.expect_error('''dialect D
  opcode add
irdl
  D.add [a, b] ↦ a + b
  D.add [a] ↦ a
fn main(_) -> i64 { return D.add(1, 2); }
''', 3416)

    def test_capturing_templates_are_outside_the_fragment(self):
        self.expect_error('''dialect D
  opcode f
irdl
  D.f [a] ↦ if a > 0 { 1 } else { 2 }
fn main(_) -> i64 { return 0; }
''', 3415)

    def test_effectful_operand_duplicated_dropped_or_reordered(self):
        for rule, use in (('D.m [a] ↦ a * a', 'D.m(src())'),             # duplicated
                          ('D.m [a, _] ↦ a', 'D.m(1, src())'),            # dropped
                          ('D.m [a, b] ↦ b - a', 'D.m(src(), src())')):   # reordered
            with self.subTest(rule=rule):
                self.expect_error('dialect D\n  opcode m\nirdl\n  ' + rule +
                                  '\nfn src() -> i64 { return 3; }\n'
                                  'fn main(_) -> i64 { return ' + use + '; }\n', 3417)

    def test_call_in_template_before_effectful_operand_is_rejected(self):
        self.expect_error('''dialect D
  opcode m
irdl
  D.m [a] ↦ src() + a
fn src() -> i64 { return 1; }
fn main(_) -> i64 { return D.m(src()); }
''', 3417)

    def test_nonterminating_rules_are_diagnosed_not_hung(self):
        self.expect_error('''dialect D
  opcode loop
irdl
  D.loop [a] ↦ D.loop(a)
fn main(_) -> i64 { return D.loop(1); }
''', 3418)

    def test_template_may_call_a_toplevel_function(self):
        self.expect_exit('''dialect D
  opcode h
irdl
  D.h [a] ↦ helper(a, 2)
fn helper(x: i64, y: i64) -> i64 { return x * y; }
fn main(_) -> i64 { return D.h(21); }
''', 42)

    def test_template_naming_something_undeclared_is_rejected(self):
        self.expect_error('''dialect D
  opcode h
irdl
  D.h [a] ↦ nosuchfn(a)
fn main(_) -> i64 { return D.h(21); }
''', 3420)

    def test_template_name_shadowed_by_a_local_is_rejected(self):
        self.expect_error('''dialect D
  opcode h
irdl
  D.h [a] ↦ helper(a)
fn helper(x: i64) -> i64 { return x + 1; }
fn main(_) -> i64 {
  let helper = 5
  return D.h(helper);
}
''', 3421)

    def test_emit_asm_template_is_declarable_but_not_usable(self):
        # declaring it only warns (spec syntax); using it must not yield a binary
        self.expect_error('''dialect T
  opcode add
irdl
  T.add [a : i64, b : i64] ↦ emit_asm("addq %{b:reg}, %{a:reg}")
fn main(_) -> i64 { return T.add(20, 22); }
''', 3419)
        run, exe = self.build('''dialect T
  opcode add
irdl
  T.add [a : i64, b : i64] ↦ emit_asm("addq %{b:reg}, %{a:reg}")
fn main(_) -> i64 { return 7; }
''')
        out = run.stdout + run.stderr
        # (the driver exits 1 whenever a warning exists; what matters is no error)
        self.assertIn('errors=0', out, 'an unused emit_asm rule must stay declarable')
        self.assertIn('W3419', out)
        self.assertTrue(exe.is_file())

    def test_guards_and_variadics_are_diagnosed_not_ignored(self):
        self.expect_error('''dialect D
  opcode adj
irdl
  D.adj [a, b], b < 0 ↦ a
  D.adj [a, b] ↦ a + b
fn main(_) -> i64 { return D.adj(1, -1); }
''', 3422)
        self.expect_error('''dialect D
  opcode any
irdl
  D.any [a, ..rest] ↦ a
fn main(_) -> i64 { return D.any(1, 2, 3); }
''', 3422)

    def test_user_defined_emit_asm_is_an_ordinary_call(self):
        self.expect_exit('''fn emit_asm(x: i64) -> i64 { return x + 2; }
dialect T
  opcode add
irdl
  T.add [a] ↦ emit_asm(a)
fn main(_) -> i64 { return T.add(40); }
''', 42)


if __name__ == '__main__':
    unittest.main()
