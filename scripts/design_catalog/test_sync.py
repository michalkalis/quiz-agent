"""Why these rules matter (#188 — unified design system, track E): the code is the
source of truth, yet a value the founder edits in the catalog is a proposal that
must never be silently lost, and when both sides changed nothing may pick a
winner on its own. Run: python3 -m unittest scripts.design_catalog.test_sync
"""

import unittest

from scripts.design_catalog.build import keep_proposals, pending_section
from scripts.design_catalog.sync import classify

BASE = {"pink": {"light": "#ff3d8f", "dark": "#ff3d8f"}, "space-md": "16px"}


def kinds(base, live, code):
    return {r["token"]: r["kind"] for r in classify(base, live, code)}


class ClassifyTests(unittest.TestCase):
    def test_founder_edit_in_catalog_is_a_proposal(self):
        live = {**BASE, "pink": {"light": "#ff0080", "dark": "#ff0080"}}
        self.assertEqual(kinds(BASE, live, BASE), {"pink": "proposal"})

    def test_app_change_is_republished_not_proposed(self):
        code = {**BASE, "space-md": "18px"}
        self.assertEqual(kinds(BASE, BASE, code), {"space-md": "code"})

    def test_both_sides_changed_differently_is_a_conflict(self):
        live = {**BASE, "space-md": "20px"}
        code = {**BASE, "space-md": "18px"}
        self.assertEqual(kinds(BASE, live, code), {"space-md": "conflict"})

    def test_proposal_that_landed_is_settled(self):
        both = {**BASE, "space-md": "20px"}
        self.assertEqual(kinds(BASE, both, both), {"space-md": "settled"})

    def test_without_a_base_a_difference_is_never_attributed(self):
        live = {**BASE, "space-md": "20px"}
        self.assertEqual(kinds(None, live, BASE), {"space-md": "differs"})

    def test_agreement_reports_nothing(self):
        self.assertEqual(classify(BASE, BASE, BASE), [])


class KeepProposalTests(unittest.TestCase):
    def tokens(self):
        return {
            "color": {"tokens": [{"name": "pink", "value": {"light": "#ff3d8f", "dark": "#ff3d8f"}, "usage": "Brand."}]},
            "spacing": {"tokens": [{"name": "space-md", "value": "16px", "usage": ""}]},
            "radius": {"tokens": []},
            "shadow": {"tokens": []},
            "type": {"groups": []},
        }

    def test_undecided_proposal_stays_in_the_catalog_and_says_so(self):
        tokens = self.tokens()
        rows = [{"token": "pink", "kind": "proposal", "catalog": {"light": "#ff0080", "dark": "#ff0080"},
                 "code": {"light": "#ff3d8f", "dark": "#ff3d8f"}}]
        kept = keep_proposals(tokens, rows)
        pink = tokens["color"]["tokens"][0]
        self.assertEqual(len(kept), 1)
        self.assertEqual(pink["value"]["light"], "#ff0080")
        self.assertIn("Waiting for the app", pink["usage"])
        self.assertIn("`pink`", pending_section(rows, 0))

    def test_code_change_is_not_kept_as_a_proposal(self):
        tokens = self.tokens()
        rows = [{"token": "space-md", "kind": "code", "catalog": "16px", "code": "18px"}]
        self.assertEqual(keep_proposals(tokens, rows), [])
        self.assertIn("Nothing", pending_section(rows, 0))


if __name__ == "__main__":
    unittest.main()
