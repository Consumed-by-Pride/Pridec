"""Adversarial source->final analysis->AIR producer and lifetime contracts."""
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
BIN = ROOT / 'pfrontc'
ENV = {**os.environ, 'LD_LIBRARY_PATH': str(Path.home()/'.cache/llvm23') + ':/usr/lib/x86_64-linux-gnu'}


@unittest.skipUnless(BIN.is_file(), 'build pfrontc first')
class TheoryAirProducerTests(unittest.TestCase):
    def compile_air(self, text, options=()):
        with tempfile.TemporaryDirectory(prefix='n3-theory-air-') as folder:
            source = Path(folder)/'probe.pie'
            source.write_text(text)
            run = subprocess.run([str(BIN), str(source), '--emit-air', '--plain', '--lint', *options],
                                 cwd=ROOT, env=ENV, capture_output=True, text=True, timeout=20)
            self.assertIn(run.returncode, (0,1), run.stdout[-1500:]+run.stderr[-1500:])
            return source.with_suffix('.air').read_text(), run.stdout+run.stderr

    def facts(self, air, function):
        lines=air.splitlines()
        for index,line in enumerate(lines):
            if re.match(r'(?:pub )?(?:fn|def) '+re.escape(function)+r'(?:\W|$)',line):
                return lines[index-1] if index and lines[index-1].startswith('; air facts:') else ''
        self.fail('function not emitted: '+function)

    def test_external_storage_does_not_claim_no_retention(self):
        air,_=self.compile_air('fn retain(out: **i64, p: *i64) -> i64 { out[0] = p; return 0; }\n')
        facts=self.facts(air,'retain')
        self.assertNotIn('captures(none):p',facts)
        self.assertNotIn('memory(read)',facts)

    def test_returned_address_and_cast_aliases_escape(self):
        for body in ('return p as i64;', 'let x = p as i64; return x;',
                     'return if flag { p as i64 } else { 0 };'):
            with self.subTest(body=body):
                air,_=self.compile_air('fn address(p: *i64, flag: bool) -> i64 { '+body+' }\n')
                self.assertNotIn('captures(none):p',self.facts(air,'address'))

    def test_selected_pointer_write_is_not_readonly(self):
        air,diagnostics=self.compile_air('''fn write_choice(p: *i64, q: *i64, flag: bool) -> i64 {
  let chosen: *i64 = if flag { p } else { q };
  chosen[0] = 9; return 0;
}
''')
        self.assertNotIn('memory(read)',self.facts(air,'write_choice'))
        self.assertNotIn('`write_choice` has no proven external writes',diagnostics)

    def test_valid_read_keeps_weak_memory_and_capture_facts(self):
        air,diagnostics=self.compile_air('fn read_first(p: *i64) -> i64 { return p[0]; }\n')
        facts=self.facts(air,'read_first')
        self.assertIn('checked memory(read)',facts)
        self.assertIn('captures(none):p',facts)
        self.assertNotIn('safe to memoise',diagnostics)
        self.assertNotIn('noalias readonly',diagnostics)

    def test_unknown_foreign_calls_do_not_export_proofs(self):
        air,_=self.compile_air('''extern fn unknown(p: *i64) -> i64
fn wrapper(p: *i64) -> i64 { return unknown(p); }
''')
        facts=self.facts(air,'wrapper')
        self.assertNotIn('memory(read)',facts)
        self.assertNotIn('captures(none)',facts)

    def test_no_theory_does_not_resurrect_source_candidates(self):
        air,_=self.compile_air('fn read_first(p: *i64) -> i64 { return p[0]; }\n',('--no-theory',))
        self.assertEqual('',self.facts(air,'read_first'))

    def test_parameter_analysis_budget_is_unknown(self):
        params=', '.join('p'+str(i)+': *i64' for i in range(33))
        air,_=self.compile_air('fn many('+params+') -> i64 { return 0; }\n')
        facts=self.facts(air,'many')
        self.assertNotIn('memory(read)',facts)
        self.assertNotIn('captures(none)',facts)

    def test_post_rewrite_facts_are_recomputed(self):
        air,diagnostics=self.compile_air('''extern fn unknown(x: i64) -> i64
rewrite call_foreign
  | x * 3i64 ↦ unknown(x)
fn transformed(x: i64) -> i64 { return (x * 3i64) |> call_foreign; }
''')
        self.assertIn('call',air)
        self.assertNotIn('memory(read)',self.facts(air,'transformed'))
        self.assertNotIn('`transformed` has no proven external writes',diagnostics)

    def test_dense_hint_is_not_required_for_correct_dispatch(self):
        text=(ROOT/'tests/exec/pear/p110_dense_switch.pie').read_text()
        with tempfile.TemporaryDirectory(prefix='n3-dispatch-') as folder:
            source=Path(folder)/'dispatch.pie';source.write_text(text)
            for theory in (True,False):
                options=[] if theory else ['--no-theory']
                run=subprocess.run([str(BIN),str(source),'--emit-exe','-O2','--quiet',*options],
                                   cwd=ROOT,env=ENV,capture_output=True,text=True,timeout=20)
                self.assertEqual(0,run.returncode,run.stdout+run.stderr)
                value=subprocess.run([str(source.with_suffix(''))],env=ENV,capture_output=True,timeout=2)
                self.assertEqual(190,value.returncode)

    def test_character_codepoint_survives_air_without_theory(self):
        text="fn main(_) -> i64 { return 'λ'; }\n"
        with tempfile.TemporaryDirectory(prefix='n3-char-') as folder:
            source=Path(folder)/'character.pie';source.write_text(text)
            for theory in (True,False):
                run=subprocess.run([str(BIN),str(source),'--emit-air','--emit-exe','-O2','--quiet',
                                    * ([] if theory else ['--no-theory'])],cwd=ROOT,env=ENV,
                                   capture_output=True,text=True,timeout=20)
                self.assertIn(run.returncode,(0,1),run.stdout+run.stderr)
                native=subprocess.run([str(source.with_suffix(''))],env=ENV,capture_output=True,timeout=2)
                self.assertEqual(955%256,native.returncode)
                if not theory:self.assertIn("'λ'",source.with_suffix('.air').read_text())


    def test_character_escapes_and_ambiguous_literals(self):
        with tempfile.TemporaryDirectory(prefix='n3-char-contract-') as folder:
            source=Path(folder)/'character.pie'
            for literal,value in ((r"'\n'",10),(r"'\x41'",65),("'λ'",955),("'😀'",128512)):
                with self.subTest(literal=literal):
                    source.write_text("fn main(_) -> i64 { return "+literal+"; }\n")
                    run=subprocess.run([str(BIN),str(source),'--emit-exe','--no-theory','--quiet'],
                        cwd=ROOT,env=ENV,capture_output=True,text=True,timeout=20)
                    self.assertIn(run.returncode,(0,1),run.stdout+run.stderr)
                    native=subprocess.run([str(source.with_suffix(''))],env=ENV,capture_output=True,timeout=2)
                    self.assertEqual(value%256,native.returncode)
            source.write_text("fn main(_) -> i64 { return 'λx'; }\n")
            source.with_suffix('').unlink(missing_ok=True)
            run=subprocess.run([str(BIN),str(source),'--emit-exe','--plain'],cwd=ROOT,env=ENV,
                               capture_output=True,text=True,timeout=20)
            self.assertEqual(2,run.returncode)
            self.assertIn('exactly one Unicode scalar',run.stdout)
            self.assertFalse(source.with_suffix('').exists())


if __name__=='__main__':
    unittest.main()
