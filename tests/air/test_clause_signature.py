#!/usr/bin/env python3
"""Guard the facts about what the 2.2 clause path does to signatures.

This file exists because a claim in tests/pfront/bug/known/README.md was WRONG
and shipped: it said a value-matching clause emitted "no parameters at all",
which would have been an arity mismatch inside one artifact. The artifact
actually said `(_ : infer)` -- ONE parameter named `_`. The arity was correct all
along; only the name was lost.

That is the failure mode this file prevents: reasoning about emitted text from
memory instead of reading it. Every assertion below is a textual invariant over
the lowerer source that a reviewer can check against a real artifact.

If you are changing the clause parameter path, run the oracle:

    pfrontc x.pie --emit-air --quiet   &&   grep -o 'def f([^)]*)' x.air

and confirm the arity first. Do not trust a summary -- including this one.
"""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
LOWER = ROOT / "pfront" / "pear_ir" / "air_lower.c3"


class ClauseSignatureTests(unittest.TestCase):
    def test_non_binder_clause_params_fall_back_to_a_name_but_stay_a_param(self):
        """A literal/wildcard head must still produce ONE parameter.

        The single-arg branch calls node_text(cp); for `| 0i64 ->` that yields
        nothing and falls back to "_". The important half is that add_param is
        still reached -- dropping the parameter entirely would change arity.
        """
        text = LOWER.read_text()
        m = re.search(r"fn AirDecl\* AirLower\.decl_fn\([^)]*\)\s*\{", text)
        self.assertIsNotNone(m, "decl_fn not found")
        body = re.match(r"[\s\S]*?\n\}", text[m.start():]).group(0)

        # The fallback name for a head with no text.
        self.assertIn('pnm = (char*)"_"', body,
                      "the no-text fallback name changed; check what a literal "
                      "clause head emits before updating this test")
        # ...and the param is still registered.
        self.assertRegex(
            body, r'pnm = \(char\*\)"_"[\s\S]{0,400}?add_param\(',
            "a param name fallback no longer reaches add_param, which WOULD be "
            "an arity bug -- verify against a real artifact with "
            "`pfrontc x.pie --emit-air`",
        )

    def test_return_type_adoption_is_restricted_to_64_bit_ints(self):
        """bool/ptr/unit results deliberately stay `infer` under PEAR 1.

        `decl_fn` adopts only ATYP_I64/U64/ISZ/USZ, because PEAR 1 represents
        every value as i64 and a narrower type produces `ret i64` in an `i1`
        function. This is a documented limitation, not a defect, and the README
        must not describe it as one.
        """
        text = LOWER.read_text()
        m = re.search(r"Only the 64-bit integer results are adopted[\s\S]{0,1200}", text)
        self.assertIsNotNone(
            m,
            "the comment explaining why non-i64 results stay `infer` was "
            "removed; restore it or update tests/pfront/bug/known/README.md",
        )
        adopt = m.group(0)
        for tag in ("ATYP_I64", "ATYP_U64", "ATYP_ISZ", "ATYP_USZ"):
            self.assertIn(tag, adopt, f"{tag} no longer adopted for clause results")
        self.assertNotIn(
            "ATYP_BOOL", adopt,
            "ATYP_BOOL is now adopted for clause results; that reintroduces the "
            "`ret i64` in an `i1` function miscompile the comment warns about",
        )


if __name__ == "__main__":
    unittest.main()
