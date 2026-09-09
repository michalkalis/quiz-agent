"""``report --coverage`` bars (T17, DD4).

Why it matters: the bars are what stands between "some translations exist" and
"a Slovak session cannot run dry in a picker cell". A thin cell must fail the
run loudly and name itself, and a waiver must be visible, per run, never a
config change — otherwise the cutover gate can be passed by accident.
"""

from __future__ import annotations

from scripts.translation_runner import report as rep


def _full(n: int) -> dict[tuple[str, str], int]:
    return {(c, d): n for c in rep.CATEGORIES for d in rep.DIFFICULTIES}


def test_thin_cell_exits_nonzero_and_lists_cells() -> None:
    en = _full(20)
    translated = _full(20)
    translated[("history", "hard")] = 5  # ratio 0.25 and below the cell floor
    cells, cats = rep.evaluate(en, translated)
    report = rep.CoverageReport(
        "sk", cells, cats, ["qid-1", "qid-2"], {"en": 0, "translated": 0}, {}, []
    )

    failing = [c for c in cells if c.failing]
    assert [(c.category, c.difficulty) for c in failing] == [("history", "hard")]
    assert failing[0].failing == ["ratio", "cell_floor"]
    assert report.ok is False
    text = rep.render(report)
    assert "history           hard" in text and "FAIL ratio,cell_floor" in text
    assert "RESULT: FAIL" in text


def test_en_starved_cell_is_excluded_from_bars_and_reported() -> None:
    en = _full(20)
    en[("sports", "hard")] = 4  # EN itself has < 10 rows there
    translated = _full(20)
    translated[("sports", "hard")] = 0
    cells, _ = rep.evaluate(en, translated)
    cell = next(c for c in cells if (c.category, c.difficulty) == ("sports", "hard"))
    assert cell.en_starved is True and cell.failing == []


def test_category_floor_uses_min_of_constant_and_ratio() -> None:
    en = _full(20)  # 60 EN per category → floor min(30, 57) = 30
    translated = _full(20)
    for d in rep.DIFFICULTIES:
        translated[("food-everyday", d)] = 9  # 27 < 30 but every cell en>=10
    _, cats = rep.evaluate(en, translated)
    row = next(r for r in cats if r.category == "food-everyday")
    assert row.floor == 30 and row.failing is True


def test_waiver_is_per_run_and_makes_the_report_pass() -> None:
    en = _full(20)
    translated = _full(20)
    translated[("history", "hard")] = 5
    cells, cats = rep.evaluate(
        en, translated, waivers={"history/hard": "launch without hard history"}
    )
    report = rep.CoverageReport(
        "sk", cells, cats, [], {"en": 0, "translated": 0}, {}, []
    )
    assert report.ok is True
    assert "WAIVED (launch without hard history)" in rep.render(report)


def test_extra_categories_outside_taxonomy_are_still_reported() -> None:
    """A `general` row (no-category mode, #170) must not vanish from the crosstab."""
    en = _full(20)
    en[("general", "easy")] = 12
    translated = _full(20)
    cells, _ = rep.evaluate(en, translated)
    extra = [c for c in cells if c.category == "general"]
    assert extra and extra[0].en == 12 and "ratio" in extra[0].failing
