"""`scripts/dedup_live_corpus.py` — one-time live-corpus duplicate cleanup.

Why: the run archives questions on prod without a human looking at each pair
(founder 2026-10-22: "verím nášmu systému"). The guarantees that make that
safe live in the pure decision code, so they are pinned here: every archived
question keeps a live twin testing the same fact, the later / lower-rated twin
is the one that goes, and an anchored row is never archived — an English row
in a native-language pool (it still serves English players) or an approved
row in a --pending run (a pending twin must never cost players a live
question).
"""

from __future__ import annotations

from datetime import UTC, datetime, timedelta

import numpy as np
import scripts.dedup_live_corpus as cleanup

T0 = datetime(2026, 9, 1, tzinfo=UTC)


def _item(qid, day=0, rating=None, emb=(1.0, 0.0), emb_qa=None, anchored=False):
    return cleanup.Item(
        id=qid,
        language="en",
        question=f"q {qid}",
        answer="a",
        created_at=T0 + timedelta(days=day),
        rating=rating,
        emb=np.array(emb),
        emb_qa=None if emb_qa is None else np.array(emb_qa),
        anchored=anchored,
    )


def test_never_chains_so_a_different_fact_survives():
    # A~B and B~C are same-fact verdicts, A vs C is not: archiving both B and
    # C would delete C's fact from the game, with no twin left serving it.
    items = [_item("A", 0), _item("B", 1), _item("C", 2)]
    assert cleanup.choose_archive(items, {("A", "B"), ("B", "C")}) == {"B": "A"}


def test_later_question_goes_unless_founder_rated_it_higher():
    # Mirrors the generation gate: the earlier question was there first.
    assert cleanup.choose_archive(
        [_item("old", 0), _item("new", 5)], {("old", "new")}
    ) == {"new": "old"}
    # A founder rating is the only quality signal we trust over age.
    assert cleanup.choose_archive(
        [_item("old", 0, rating=0.2), _item("new", 5, rating=0.9)],
        {("old", "new")},
    ) == {"old": "new"}


def test_anchored_row_is_never_archived_even_when_newer_and_lower_rated():
    # Native pool: the English row serves other players too. Pending run: the
    # approved row is live. Either way the un-anchored twin goes.
    live = _item("live", 9, rating=0.1, anchored=True)
    twin = _item("twin", 0, rating=1.0)
    assert cleanup.choose_archive([twin, live], {("twin", "live")}) == {"twin": "live"}


def test_no_verdict_archives_nothing():
    items = [_item("A", 0), _item("B", 1)]
    assert cleanup.choose_archive(items, set()) == {}


def test_candidate_pairs_floor_and_qa_branch():
    near = _item("near", emb=(1.0, 0.1))
    base = _item("base", emb=(1.0, 0.0))
    far = _item("far", emb=(0.0, 1.0))
    pairs = cleanup.candidate_pairs([base, near, far])
    assert [(i, j) for i, j, _, _ in pairs] == [(0, 1)]

    # Same fact, disjoint wording: question vectors far apart, Q+A vectors close.
    a = _item("a", emb=(1.0, 0.0), emb_qa=(1.0, 0.0))
    b = _item("b", emb=(0.0, 1.0), emb_qa=(1.0, 0.2))
    assert len(cleanup.candidate_pairs([a, b])) == 1
    # A row without a QA vector (translation, some pending rows) must not
    # switch the QA branch off for the whole pool.
    c = _item("c", emb=(0.0, -1.0))
    assert {(i, j) for i, j, _, _ in cleanup.candidate_pairs([a, b, c])} == {(0, 1)}


def test_pairs_of_two_anchored_rows_are_not_rejudged():
    # Both live / both English: neither may be archived, the pair was decided
    # already, so judging it again would only spend calls.
    en1 = _item("en1", anchored=True)
    en2 = _item("en2", anchored=True)
    new = _item("new")
    pairs = cleanup.candidate_pairs([en1, en2, new])
    assert {(i, j) for i, j, _, _ in pairs} == {(0, 2), (1, 2)}
