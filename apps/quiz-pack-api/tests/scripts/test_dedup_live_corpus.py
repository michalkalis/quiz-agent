"""`scripts/dedup_live_corpus.py` — one-time live-corpus duplicate cleanup.

Why: the run archives approved questions on prod without a human looking at
each pair (founder 2026-10-22: "verím nášmu systému"). The guarantees that
make that safe live in the pure decision code, so they are pinned here:
every archived question keeps a live twin testing the same fact, the later /
lower-rated twin is the one that goes, an English row is never archived for a
native-language pool (it still serves English players), and a native pool
does not re-judge English pairs the English pool already decided.
"""

from __future__ import annotations

from datetime import UTC, datetime, timedelta

import numpy as np
import scripts.dedup_live_corpus as cleanup

T0 = datetime(2026, 9, 1, tzinfo=UTC)


def _item(qid, day=0, rating=None, language="en", emb=(1.0, 0.0), emb_qa=None):
    return cleanup.Item(
        id=qid,
        language=language,
        question=f"q {qid}",
        answer="a",
        created_at=T0 + timedelta(days=day),
        rating=rating,
        emb=np.array(emb),
        emb_qa=None if emb_qa is None else np.array(emb_qa),
    )


def test_never_chains_so_a_different_fact_survives():
    # A~B and B~C are same-fact verdicts, A vs C is not: archiving both B and
    # C would delete C's fact from the game, with no twin left serving it.
    items = [_item("A", 0), _item("B", 1), _item("C", 2)]
    archived = cleanup.choose_archive(
        items, {("A", "B"), ("B", "C")}, native_pool=False
    )
    assert archived == {"B": "A"}


def test_later_question_goes_unless_founder_rated_it_higher():
    # Mirrors the generation gate: the earlier question was there first.
    assert cleanup.choose_archive(
        [_item("old", 0), _item("new", 5)], {("old", "new")}, native_pool=False
    ) == {"new": "old"}
    # A founder rating is the only quality signal we trust over age.
    assert cleanup.choose_archive(
        [_item("old", 0, rating=0.2), _item("new", 5, rating=0.9)],
        {("old", "new")},
        native_pool=False,
    ) == {"old": "new"}


def test_native_pool_archives_the_native_row_not_the_english_one():
    # The English row also serves English (and other-language) players;
    # archiving it to fix a Slovak duplicate would cost them a question.
    en = _item("en", 9, rating=0.1)
    sk = _item("sk", 0, rating=1.0, language="sk")
    assert cleanup.choose_archive([sk, en], {("sk", "en")}, native_pool=True) == {
        "sk": "en"
    }


def test_unjudged_or_no_verdict_pairs_archive_nothing():
    items = [_item("A", 0), _item("B", 1)]
    assert cleanup.choose_archive(items, set(), native_pool=False) == {}


def test_candidate_pairs_floor_and_qa_branch():
    near = _item("near", emb=(1.0, 0.1))
    base = _item("base", emb=(1.0, 0.0))
    far = _item("far", emb=(0.0, 1.0))
    pairs = cleanup.candidate_pairs([base, near, far], skip_en_en=False)
    assert [(i, j) for i, j, _, _ in pairs] == [(0, 1)]

    # Same fact, disjoint wording: question vectors far apart, Q+A vectors close.
    a = _item("a", emb=(1.0, 0.0), emb_qa=(1.0, 0.0))
    b = _item("b", emb=(0.0, 1.0), emb_qa=(1.0, 0.2))
    assert len(cleanup.candidate_pairs([a, b], skip_en_en=False)) == 1


def test_native_pool_skips_english_pairs_already_judged():
    en1 = _item("en1")
    en2 = _item("en2")
    sk = _item("sk", language="sk")
    pairs = cleanup.candidate_pairs([en1, en2, sk], skip_en_en=True)
    assert {(i, j) for i, j, _, _ in pairs} == {(0, 2), (1, 2)}
