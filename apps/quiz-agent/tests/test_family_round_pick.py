"""#236 — family mode „S deťmi“: the catalog, the switches' stored values and
the pure round pick (plan docs/issues/issue-236-family-mode-build.md, S1).

Why: a played topic must keep playing by repeating what the family heard
longest ago (founder 2026-11-18). Ordering by first play would loop forever
on the same few questions, so the pick reads the app's history order, which
the app keeps with a replayed question moved to its end (plan step A1).
"""

from __future__ import annotations

import random

import pytest

from app import app_switches
from app.config import Settings
from app.family.rounds import pick_round
from app.family.topics import BAND_TOPICS, TOPIC_NAMES
from quiz_shared.models.question import AGE_BANDS


def test_every_catalog_topic_has_a_name_in_every_family_language():
    for band in AGE_BANDS:
        assert BAND_TOPICS[band], band
        for key in BAND_TOPICS[band]:
            assert key.startswith("family-")
            assert set(TOPIC_NAMES[key]) == {"sk", "cs", "en"}


def test_unplayed_questions_come_first_in_random_order():
    pool = [f"q{i}" for i in range(20)]
    history = pool[:10]
    random.seed(1)
    first, repeats = pick_round(pool, history, 6)
    random.seed(2)
    second, _ = pick_round(pool, history, 6)

    assert not repeats
    assert set(first) <= set(pool[10:]) and set(second) <= set(pool[10:])
    assert first != second  # shuffled, not the store's order


def test_a_short_pool_refills_from_the_longest_ago_played():
    pool = ["new", "b", "a", "c"]
    history = ["x", "a", "y", "b", "c"]  # oldest first; x, y are off-topic

    picked, repeats = pick_round(pool, history, 3)

    assert picked == ["new", "a", "b"] and repeats


def test_two_rounds_on_a_fully_played_topic_do_not_repeat_each_other():
    """The app moves a replayed question to the end of its history (plan A1);
    the next round must then reach the ones heard longest ago."""
    pool = [f"q{i}" for i in range(10)]
    history = list(pool)

    first, repeats_1 = pick_round(pool, history, 6)
    history = [q for q in history if q not in first] + first
    second, repeats_2 = pick_round(pool, history, 6)

    assert first == pool[:6] and repeats_1 and repeats_2
    assert second == ["q6", "q7", "q8", "q9", "q0", "q1"]


def test_hidden_storefronts_store_as_codes_and_refuse_typos():
    """A typo must be refused at write time: a code the app never matches
    would silently leave the mode on in the country it was meant to hide."""
    key = "family_mode_hidden_storefronts"
    assert app_switches.encode(key, ["usa", " GBR ", "USA"]) == "USA,GBR"
    assert app_switches.encode(key, []) is None
    assert app_switches.encode(key, None) is None
    with pytest.raises(ValueError):
        app_switches.encode(key, ["US"])
    with pytest.raises(ValueError):
        app_switches.encode(key, "USA")
    served = app_switches.effective(Settings(), {key: "USA,GBR"})
    assert served[key] == ["USA", "GBR"]
    assert app_switches.effective(Settings(), {})[key] == []
