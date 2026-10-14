"""The fresh-entertainment brief (#202 task 202.3).

Why: the brief is the recipe the founder's blind ratings validated (#201) —
own-country scene first, no awards or crew, numbers only as multiple choice.
A cs run that still says "Slovak", a stale freshness window, or a brief that
drops the seeds or the covered facts would silently regress the quality bar.
"""

from __future__ import annotations

from datetime import date

from app.corpus.covered import COVERED_HEADER
from app.corpus.fresh_brief import build_fresh_brief, freshness_window
from app.corpus.seed_filters import Seed

SEED = Seed(
    subject="Zrádci",
    fact="The second season was won by a traitor.",
    angle="she was a traitor from day one",
    source_url="https://cs.wikipedia.org/wiki/Zr%C3%A1dci",
    scope="domestic",
    event_date="2026-09-20",
    views=12000,
)
COVERED = ["- Who won Absolutní slavík 2025? -> Ewa Farna"]


def test_cs_brief_is_about_czechia_not_slovakia():
    brief = build_fresh_brief("cs", date(2026, 10, 14), [SEED], COVERED)
    assert "Czech entertainment scene" in brief and "people in Czechia" in brief
    assert "play in Czech" in brief
    assert "Do not ask about the Slovak scene" in brief
    assert "Slovak celebrities" not in brief and "Slovakia" not in brief


def test_sk_brief_keeps_the_slovak_scene():
    brief = build_fresh_brief("sk", date(2026, 10, 14), [SEED], COVERED)
    assert (
        "Slovak entertainment scene" in brief
        and "Do not ask about the Czech scene" in brief
    )


def test_dates_follow_the_run_day():
    assert "between August and October 2026 (today is 2026-10-14)" in freshness_window(
        date(2026, 10, 14)
    )
    assert "between November 2026 and January 2027" in freshness_window(
        date(2027, 1, 20)
    )
    brief = build_fresh_brief("en", date(2027, 1, 20), [SEED], [])
    assert "today is 2027-01-20" in brief and "web research on 2027-01-20" in brief


def test_seeds_covered_and_quality_rules_are_present():
    brief = build_fresh_brief("en", date(2026, 10, 14), [SEED], COVERED)
    assert "The second season was won by a traitor." in brief
    assert SEED.source_url in brief and "12000 views" in brief
    assert COVERED_HEADER in brief and COVERED[0] in brief
    assert "Do not build questions around awards" in brief
    assert "people behind the camera" in brief
    assert "Never ask an open question whose answer is a number" in brief
    assert "multiple-choice question with 3 clearly different options" in brief
    assert "not only in the US" in brief


def test_brief_limits_questions_per_subject():
    """Founder 2026-10-14 ("Max. 2 na tému"): the seed cap alone cannot stop the
    generator from writing four questions off one seed's subject."""
    brief = build_fresh_brief("en", date(2026, 10, 14), [SEED], COVERED)
    assert "At most 2 questions about the same person, band, film" in brief
