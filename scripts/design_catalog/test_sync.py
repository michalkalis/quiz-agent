"""Why these rules matter (#188 — unified design system, track E): the code is the
source of truth, yet a value the founder edits in the catalog is a proposal that
must never be silently lost, and when both sides changed nothing may pick a
winner on its own. The catalog shows what the app renders (#194 — font + logo
change), never the argument a view passes. Run: python3 -m unittest scripts.design_catalog.test_sync
"""

import subprocess
import tempfile
import unittest
from pathlib import Path

from scripts.design_catalog.build import keep_proposals, pending_section
from scripts.design_catalog.cover import cover_html, read_brand
from scripts.design_catalog.pen import code_view, payload, pen_view
from scripts.design_catalog.swift_tokens import build_tokens, build_type
from scripts.design_catalog.sync import base_tokens, classify

ROOT = Path(__file__).resolve().parents[2]

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
    "type": {"groups": [{"name": "Display (Rethink Sans)", "family": "display",
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


# Theme.Hangs.Fonts in its real shape, with its own numbers: the tests check the
# resolution steps, not today's values. The cuts are the bundled font files.
FONTS = """
enum Fonts {
    static func display(_ size: CGFloat) -> Font {
        switch size {
        case ..<30: return content(24, weight: .bold, relativeTo: .title2)
        default: return content(50, weight: .heavy, relativeTo: .largeTitle)
        }
    }
    static func content(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        content(size, weight: weight, relativeTo: textStyle(for: size))
    }
    private static func content(_ size: CGFloat, weight: Font.Weight, relativeTo style: Font.TextStyle) -> Font {
        .custom(RethinkSans.name(for: weight), size: size, relativeTo: style)
    }
    nonisolated enum RethinkSans {
        static let all = ["RethinkSans-SemiBold", "RethinkSans-Bold", "RethinkSans-ExtraBold"]
        static func name(for weight: Font.Weight) -> String {
            switch weight {
            case .heavy, .black: return "RethinkSans-ExtraBold"
            case .bold: return "RethinkSans-Bold"
            default: return "RethinkSans-SemiBold"
            }
        }
    }
    static func body(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(textStyle(for: size), weight: weight)
    }
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(textStyle(for: size), weight: weight == .regular ? .regular : .semibold).monospacedDigit()
    }
    static func textStyle(for size: CGFloat) -> Font.TextStyle {
        switch size {
        case ..<14: return .footnote // 13
        case ..<18.5: return .body // 17
        default: return .largeTitle // 34
        }
    }
}
extension Font {
    static func hangsDisplay(_ size: CGFloat, weight _: Font.Weight = .black) -> Font {
        Theme.Hangs.Fonts.display(size)
    }
    static func hangsMono(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        Theme.Hangs.Fonts.mono(size, weight: weight)
    }
    static func hangsBody(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        Theme.Hangs.Fonts.body(size, weight: weight)
    }
    static var hangsHero: Font { .hangsDisplay(80) }
    static var hangsSmall: Font { .hangsDisplay(20, weight: .regular) }
    static var hangsCounter: Font { .hangsMono(13) }
    static var hangsRow: Font { .hangsBody(16, weight: .semibold) }
    static var hangsAnswer: Font { Theme.Hangs.Fonts.content(17) }
    static var hangsMark: Font { Theme.Hangs.Fonts.content(28, weight: .heavy) }
}
"""


def styles(src=FONTS):
    return {s["name"]: s for g in build_type(ROOT, src)["groups"] for s in g["styles"]}


class TypeTests(unittest.TestCase):
    """The catalog's type styles are what Theme.swift renders, so a designer never
    works from a size or a font the app does not show."""

    def test_display_size_is_the_scale_step_it_snaps_to(self):
        hero, small = styles()["hero"], styles()["small"]
        self.assertEqual((hero["fontSize"], hero["fontWeight"]), ("50px", 800))  # asks 80, the scale has 50 heavy
        self.assertIn("asks for 80", hero["usage"])
        self.assertEqual((small["fontSize"], small["fontWeight"]), ("24px", 700))  # the weight argument is ignored

    def test_controls_take_their_text_style_size(self):
        self.assertEqual(styles()["row"]["fontSize"], "17px")  # 16 snaps to .body
        self.assertEqual(styles()["row"]["fontWeight"], 600)

    def test_mono_weight_follows_the_semibold_rule(self):
        counter = styles()["counter"]  # the wrapper's default .medium is not .regular, so semibold
        self.assertEqual((counter["fontSize"], counter["fontWeight"]), ("13px", 600))
        self.assertIn("tabular digits", counter["usage"])

    def test_content_weight_is_the_bundled_cut_it_loads(self):
        self.assertEqual(styles()["answer"]["fontWeight"], 600)
        self.assertEqual(styles()["mark"]["fontWeight"], 800)

    def test_groups_name_the_face_and_bundle_its_files(self):
        t = build_type(ROOT, FONTS)
        self.assertEqual([g["name"] for g in t["groups"]],
                         ["Display (Rethink Sans)", "Content (Rethink Sans)", "Body (SF Pro)", "Mono (SF Pro)"])
        self.assertEqual({f["weight"] for f in t["fonts"]}, {"600", "700", "800"})  # read from the font files
        self.assertTrue(all((ROOT / "apps/ios-app/Hangs/Hangs" / f["file"].replace("fonts/", "Fonts/")).exists() for f in t["fonts"]))
        self.assertIn("system UI font", next(g["note"] for g in t["groups"] if g["family"] == "body"))

    def test_a_preset_the_catalog_cannot_read_fails_the_build(self):
        # #194 added presets the old reader skipped without a word; the catalog lost them.
        odd = FONTS.replace("static var hangsHero", "static var hangsOdd: Font { .system(size: 12) }\n    static var hangsHero")
        with self.assertRaisesRegex(ValueError, "Odd"):
            build_type(ROOT, odd)


class CoverTests(unittest.TestCase):
    """The cover is the app's own logo: the icon on its token ground and the in-app lockup."""

    def test_logo_is_drawn_from_the_icon_and_the_mascot_master(self):
        tokens, brand = build_tokens(ROOT), read_brand(ROOT)
        html = cover_html(tokens, brand)
        self.assertIn(f"{brand.word}</p>", html)
        # the icon ground follows the palette token, so a theme change reaches the cover
        self.assertRegex(html, r'<rect class="f-[\w-]+" width="100" height="100"')
        # the mascot appears twice, once in the icon and once in the lockup: a lost layer or mark shows here
        self.assertEqual(html.count('d="M100 52 '), 2)
        self.assertIn(f'viewBox="{" ".join(map(str, brand.crop))}"', html)  # the lockup crops to the head

    def test_a_logo_colour_without_a_token_fails(self):
        tokens, brand = build_tokens(ROOT), read_brand(ROOT)
        brand.ground = "#123457"
        with self.assertRaisesRegex(ValueError, "#123457"):
            cover_html(tokens, brand)


class BaseTests(unittest.TestCase):
    def test_base_is_built_with_the_generator_of_that_commit(self):
        # The catalog was generated by the code at its ref. Rebuilding that ref with
        # today's generator would turn every generator fix into a fake founder proposal.
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            gen = repo / "scripts/design_catalog/swift_tokens.py"
            gen.parent.mkdir(parents=True)
            gen.write_text("def build_tokens(root):\n    return {'generator': 'old'}\n")
            git = ["git", "-C", tmp, "-c", "user.name=t", "-c", "user.email=t@t"]
            subprocess.run([*git, "init", "-q"], check=True)
            subprocess.run([*git, "add", "."], check=True)
            subprocess.run([*git, "commit", "-qm", "old"], check=True)
            sha = subprocess.run([*git, "rev-parse", "HEAD"], capture_output=True, text=True, check=True).stdout.strip()
            self.assertEqual(base_tokens(repo, f"main@{sha}"), {"generator": "old"})


if __name__ == "__main__":
    unittest.main()
