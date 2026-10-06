"""Why these rules matter (#188 — unified design system, track E): the code is the
source of truth, yet a value the founder edits in the catalog is a proposal that
must never be silently lost, and when both sides changed nothing may pick a
winner on its own. Run: python3 -m unittest scripts.design_catalog.test_sync
"""

import unittest

from scripts.design_catalog.build import keep_proposals, pending_section
from scripts.design_catalog.pen import code_view, payload, pen_view
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


PEN_TOKENS = {
    "color": {"tokens": [
        {"name": "bg", "value": {"light": "#f6f7f9", "dark": "#161616"}},
        {"name": "palette-pink500", "value": "#ff3d8f"},
    ]},
    "spacing": {"tokens": [{"name": "space-md", "value": "16px"}]},
    "radius": {"tokens": [{"name": "radius-card", "value": "18px"}]},
    "shadow": {"tokens": [{"name": "shadow-card", "value": "0 4px 20px #0e1a2b14"}]},
    "type": {"groups": [{"name": "Display (Anton)", "family": "display",
                         "styles": [{"name": "question", "fontSize": "26px", "fontWeight": 400}]}]},
}


class PenTests(unittest.TestCase):
    """Track F: Pen variables follow the same rules as the catalog. Designs start from
    the values the app really uses, and a value changed in Pen is a proposal."""

    def written(self):
        return {k: {"type": v["type"], "value": v["value"]} for k, v in payload(PEN_TOKENS, "main@abc1234").items()}

    def test_values_written_to_pen_read_back_as_the_code(self):
        # otherwise every sync would report phantom differences right after a write
        self.assertEqual(pen_view(self.written()), code_view(PEN_TOKENS))

    def test_pen_does_not_carry_palette_or_shadows(self):
        names = set(self.written())
        self.assertNotIn("palette-pink500", names)  # views never use the private palette
        self.assertNotIn("shadow-card", names)  # a Pen variable cannot hold a shadow

    def test_old_names_and_pen_helpers_never_show_up_as_differences(self):
        variables = {**self.written(), "bg-page": {"type": "color", "value": "$bg"},
                     "radius-pill": {"type": "number", "value": 100}}
        self.assertEqual(classify(code_view(PEN_TOKENS), pen_view(variables), code_view(PEN_TOKENS)), [])

    def test_value_changed_in_pen_is_a_proposal(self):
        variables = {**self.written(), "type-question-size": {"type": "number", "value": 28}}
        base = code_view(PEN_TOKENS)
        self.assertEqual(kinds(base, pen_view(variables), base), {"type.question": "proposal"})

    def test_new_variable_in_pen_is_proposed_for_the_code(self):
        variables = {**self.written(), "space-huge": {"type": "number", "value": 48}}
        base = code_view(PEN_TOKENS)
        self.assertEqual(kinds(base, pen_view(variables), base), {"space-huge": "added-in-catalog"})

    def test_app_change_reaches_pen_on_the_next_write(self):
        base = code_view(PEN_TOKENS)
        code = {**base, "space-md": "18px"}
        self.assertEqual(kinds(base, pen_view(self.written()), code), {"space-md": "code"})

    def test_undecided_pen_proposal_is_not_overwritten(self):
        self.assertNotIn("type-question-size", payload(PEN_TOKENS, "main@abc1234", {"type.question"}))
        self.assertNotIn("bg-page", payload(PEN_TOKENS, "main@abc1234", {"bg"}))
        # founder edited the legacy alias itself: the report names the alias, not its target
        self.assertNotIn("bg-page", payload(PEN_TOKENS, "main@abc1234", {"bg-page"}))


if __name__ == "__main__":
    unittest.main()
