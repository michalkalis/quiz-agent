"""Unit tests for the free surprise heuristic + ranking wiring (#72 P3.2).

RC-2 of the question-fun review: every source stamped a flat fabricated
`surprise_rating` (5.0-ish) and `top_by_surprise()` had **zero call sites**, so
the generation prompt's "prefer surprising facts" was a no-op — boring recall
facts ranked identically to genuinely surprising ones. These tests encode WHY
the heuristic matters: an extreme/quantified fact must outrank a plain recall
fact, which must outrank the known-dull OpenTDB re-wrap shape (RC-1), and the
score must be a real differentiator (not the old flat default) so ranking bites.

A test that only checked the score stayed in [1, 10] could not fail when the
ranking signal is wrong, so each test asserts a relative ordering.
"""

from __future__ import annotations

import pytest

from app.sourcing.models import Fact, FactBatch, heuristic_surprise


def test_heuristic_ranks_extreme_above_plain_above_rewrap() -> None:
    """The core signal: extreme > plain recall > OpenTDB re-wrap. If this
    inverts, ranking by surprise would surface the dull facts first — the exact
    regression P3.2 fixes."""
    extreme = heuristic_surprise(
        "The blue whale is the largest animal, up to 30 m long."
    )
    plain = heuristic_surprise("Lisbon is the capital of Portugal.")
    rewrap = heuristic_surprise(
        "The answer to 'Who painted the Mona Lisa?' is Leonardo da Vinci."
    )

    assert extreme > plain > rewrap
    # Plain recall sits just under the prompt's "surprise ≥ 5 preferred" line;
    # the extreme fact clears it. That threshold is what makes ranking useful.
    assert plain < 5.0 <= extreme


def test_heuristic_caps_markers_and_stays_in_range() -> None:
    """The marker bonus is capped so a fact stuffed with adjectives can't
    dominate purely on loud language, and the score never leaves [1, 10]."""
    # 6 distinct markers (only 3 count) + a number.
    loud = heuristic_surprise("oldest largest fastest only first rarest, 9 found")
    assert loud == pytest.approx(9.5)  # 4.0 baseline + 3×1.5 marker cap + 1.0 number
    assert 1.0 <= loud <= 10.0

    # A re-wrap with no positive signal is penalised below the neutral baseline
    # but never under the floor.
    quiet = heuristic_surprise("The answer to 'x' is y")
    assert 1.0 <= quiet < 4.0


def test_score_surprise_heuristic_replaces_flat_defaults() -> None:
    """The batch method must overwrite the flat fabricated default (RC-2) with
    a differentiated score and be chainable (returns self)."""
    dull = Fact(text="The answer to 'Q?' is A.", surprise_rating=5.0)
    extreme = Fact(
        text="It is the largest of its kind, with 12 confirmed records.",
        surprise_rating=5.0,
    )
    batch = FactBatch(facts=[dull, extreme])

    returned = batch.score_surprise_heuristic()

    assert returned is batch  # chainable: .score_surprise_heuristic().top_by_surprise()
    assert dull.surprise_rating != 5.0  # the flat default is gone
    assert extreme.surprise_rating > dull.surprise_rating  # now differentiated


def test_top_by_surprise_orders_by_heuristic_score() -> None:
    """The wiring contract: scoring then top_by_surprise() yields most-surprising
    first and drops the dull tail when n < len. This is the pairing that was
    dead (zero call sites) before P3.2."""
    dull = Fact(text="The answer to 'Q?' is A.")
    plain = Fact(text="Mercury is a planet.")
    extreme = Fact(text="It is the tallest building, at 828 metres.")
    batch = FactBatch(facts=[dull, plain, extreme]).score_surprise_heuristic()

    top = batch.top_by_surprise(2)

    assert [f.text for f in top] == [extreme.text, plain.text]  # dull tail dropped
