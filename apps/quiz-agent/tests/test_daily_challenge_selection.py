"""#205 205.1 — the day's five questions: one multiple-choice question (MCQ
ratio rule), mixed categories, no repeats of earlier days while the pool lasts,
and in sk/cs native questions before translated English ones."""

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
