"""#205 205.1 — the day's five questions: one multiple-choice question (MCQ
ratio rule), mixed categories, no repeats of earlier days while the pool lasts,
and in sk/cs native questions before translated English ones."""

from datetime import UTC, datetime, timedelta

from app.daily_challenge.selection import pick_daily_set
from quiz_shared.models.question import Question


def _q(qid, category, type_="text", language="en"):
    return Question(
        id=qid,
        question=f"Q {qid}?",
        type=type_,
        correct_answer="a",
        possible_answers={"a": "A", "b": "B"} if type_ == "text_multichoice" else None,
        topic="t",
        category=category,
        difficulty="medium",
        language=language,
    )


def _pool():
    cats = ["science", "history", "geography", "music", "film", "sport"]
    pool = [_q(f"o{i}", cats[i % len(cats)]) for i in range(30)]
    pool += [_q(f"m{i}", cats[i % len(cats)], "text_multichoice") for i in range(10)]
    return pool


def test_one_mcq_mixed_categories_in_the_middle():
    ids = pick_daily_set(_pool(), language="en", seed="en:2026-10-15")
    by_id = {q.id: q for q in _pool()}
    picked = [by_id[i] for i in ids]
    assert len(ids) == 5 and len(set(ids)) == 5
    assert [q.type for q in picked].count("text_multichoice") == 1
    assert picked[2].type == "text_multichoice"
    assert len({q.category for q in picked}) == 5


def test_same_seed_same_set_and_earlier_days_are_avoided():
    pool = _pool()
    first = pick_daily_set(pool, language="en", seed="en:2026-10-15")
    assert first == pick_daily_set(pool, language="en", seed="en:2026-10-15")
    nxt = pick_daily_set(pool, language="en", seed="en:2026-10-16", used_ids=first)
    assert not set(first) & set(nxt)


def test_pool_running_dry_allows_repeats_rather_than_no_challenge():
    pool = _pool()[:5]
    assert (
        len(
            pick_daily_set(pool, language="en", seed="x", used_ids=[q.id for q in pool])
        )
        == 5
    )


def test_native_questions_come_first_in_slovak():
    pool = [_q(f"en{i}", f"c{i}") for i in range(10)]
    pool += [_q(f"sk{i}", f"c{i}", language="sk") for i in range(10)]
    pool += [_q("skm", "cm", "text_multichoice", language="sk")]
    ids = pick_daily_set(pool, language="sk", seed="sk:2026-10-15")
    assert all(i.startswith("sk") for i in ids)


NOW = datetime(2026, 11, 18, 12, tzinfo=UTC)


def _timely(qid, until, category="film"):
    return _q(qid, category).model_copy(update={"boost_until": until})


def test_one_place_goes_to_a_question_about_what_people_talk_about_now():
    """Why: the fresh top-up writes a few questions a week about a current
    film, show or event. Among thousands of evergreen ones a random pick would
    almost never show them, and the challenge would never feel current."""
    pool = _pool() + [_timely("hot", NOW + timedelta(days=10))]
    for day in range(1, 8):
        ids = pick_daily_set(pool, language="en", seed=f"en:{day}", now=NOW)
        assert "hot" in ids and len(set(ids)) == 5
        types = [q.type for q in pool if q.id in ids]
        assert types.count("text_multichoice") == 1


def test_a_timely_question_is_not_repeated_on_a_later_day():
    pool = _pool() + [_timely("hot", NOW + timedelta(days=10))]
    ids = pick_daily_set(pool, language="en", seed="en:2", used_ids=["hot"], now=NOW)
    assert "hot" not in ids and len(ids) == 5


def test_only_a_running_boost_window_counts_as_timely():
    """An ended window is old news; a permanent boost (9999-01-01) marks an
    evergreen favourite, not a current topic. Neither may take the place every
    day, so with only such rows the pick is the same as without the rule."""
    stale = [
        _timely("ended", NOW - timedelta(days=1)),
        _timely("forever", datetime(9999, 1, 1, tzinfo=UTC)),
    ]
    pool = _pool() + stale
    with_rule = pick_daily_set(pool, language="en", seed="en:3", now=NOW)
    assert with_rule == pick_daily_set(pool, language="en", seed="en:3")
