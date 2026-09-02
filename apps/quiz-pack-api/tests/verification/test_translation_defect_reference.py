"""The DD6 translation-defect reference sets are a contract, not loose data.

`scripts/translation_judge_eval.py` (task T9) scores the MQM-Quiz judge against
these two files, and the pass bar is stated in terms of their labels: every
`critical` item caught, zero `critical` findings on the controls. So a silent
edit to a label, a control that quietly carries a defect category, or a reused
#166 fact-check qid would move the bar without anyone noticing. These tests
pin the properties the bar depends on.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

REFERENCE_DIR = Path(__file__).resolve().parents[4] / "docs" / "testing"
SETS = {
    "sk": REFERENCE_DIR / "translation-defect-reference-sk.json",
    "cs": REFERENCE_DIR / "translation-defect-reference-cs.json",
}

#: #166 fact-check reference qids (``scripts/factcheck_eval_166.py:48``). Those
#: are factual errors in *English* questions; a source-vs-target judge is never
#: exercised by them, so DD6 forbids reusing them here.
FACTCHECK_QIDS = frozenset({"q03", "q32", "q48", "q63", "q81", "q89", "q95"})

ORIGINS = {"real", "synthetic", "control"}
SEVERITIES = {"critical", "major", "minor", "none"}
PAYLOAD_KEYS = {
    "question",
    "type",
    "possible_answers",
    "correct_answer",
    "alternative_answers",
    "explanation",
}


def load(language: str) -> dict:
    return json.loads(SETS[language].read_text(encoding="utf-8"))


@pytest.fixture(params=sorted(SETS))
def language(request) -> str:
    return request.param


def test_items_carry_the_dd6_labels(language: str) -> None:
    """Every item is labelled {qid, language, source, target, defect_category,
    severity} — the shape DD6 names and the eval harness reads."""
    for item in load(language)["items"]:
        for key in ("qid", "language", "source", "target", "defect_category", "severity"):
            assert key in item, f"{item.get('qid')} is missing {key}"
        assert item["language"] == language
        assert item["origin"] in ORIGINS
        assert item["severity"] in SEVERITIES
        for side in ("source", "target"):
            missing = PAYLOAD_KEYS - set(item[side])
            assert not missing, f"{item['qid']} {side} is missing {sorted(missing)}"


def test_qids_are_unique_and_never_the_factcheck_set(language: str) -> None:
    """Reusing a #166 qid would certify nothing (DD6), and a duplicate qid would
    silently drop an item from the harness's per-qid resume map."""
    qids = [item["qid"] for item in load(language)["items"]]
    assert len(qids) == len(set(qids))
    assert not FACTCHECK_QIDS & set(qids)


def test_controls_are_defect_free_and_defects_are_not_controls(language: str) -> None:
    """The bar counts critical findings on controls as false positives, so a
    control carrying a real defect category would make the bar unreachable, and
    a defect labelled `none` would make it trivially passable."""
    for item in load(language)["items"]:
        if item["origin"] == "control":
            assert item["severity"] == "none", f"{item['qid']} control has a severity"
            assert item["defect_category"] == "none"
        else:
            assert item["severity"] != "none", f"{item['qid']} defect has no severity"
            assert item["defect_category"] != "none"


def test_controls_are_about_a_third(language: str) -> None:
    """DD6 sizes the control third deliberately: too few and a permissive judge
    passes on recall alone, too many and the critical set stops being a bar."""
    items = load(language)["items"]
    controls = [i for i in items if i["origin"] == "control"]
    assert 0.25 <= len(controls) / len(items) <= 0.40


def test_every_defect_class_dd6_names_is_present(language: str) -> None:
    """The five synthetic classes are what make the set reproducible across
    languages; losing one would leave that failure mode unmeasured."""
    categories = {i["defect_category"] for i in load(language)["items"]}
    for required in (
        "answer_flip",
        "unit_change",
        "untranslated_string",
        "title_mistranslation",
        "register_calque",
    ):
        assert required in categories, f"{language} set no longer covers {required}"


def test_criticals_exist_and_the_meta_counts_match_the_items(language: str) -> None:
    """`_meta` is what the PR body and the judge-eval report quote. If it drifts
    from the items, the reported bar describes a set that does not exist."""
    data = load(language)
    items = data["items"]
    meta = data["_meta"]
    assert meta["item_count"] == len(items)
    for origin, expected in meta["composition"].items():
        assert expected == sum(1 for i in items if i["origin"] == origin)
    for severity, expected in meta["severity_counts"].items():
        assert expected == sum(1 for i in items if i["severity"] == severity)
    assert meta["severity_counts"]["critical"] > 0


def test_real_items_cite_their_evidence() -> None:
    """A `real` item without a repo document or commit behind it is a synthetic
    item wearing a costume, and DD6's SK bar leans on the mined ones being real.
    """
    for item in load("sk")["items"]:
        if item["origin"] == "real":
            assert item["evidence"], f"{item['qid']} claims to be real with no evidence"


def test_cs_set_declares_that_it_mined_no_real_defects() -> None:
    """The CS set is synthetic-only, which is exactly why DD6 gives Czech an
    extra founder spot-check before its cutover. If someone later adds mined CS
    defects, this test fails and forces that note to be rewritten rather than
    left lying.
    """
    data = load("cs")
    assert data["_meta"]["composition"]["real"] == 0
    assert data["_meta"]["no_real_defects"]
    assert data["_meta"]["consequence"]
