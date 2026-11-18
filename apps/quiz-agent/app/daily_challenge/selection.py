"""Choosing the day's five questions (#205 205.1). Pure: the caller loads the
candidates and persists the pick, so everyone plays the same set."""

from __future__ import annotations

import random
from datetime import UTC, datetime
from typing import List, Optional, Sequence

from quiz_shared.models.question import Question

SET_SIZE = 5
MCQ_TYPE = "text_multichoice"
# MCQ ratio rule (~20-30 % of a set): one multiple-choice question in five.
MCQ_PER_SET = 1
# Play position of the multiple-choice question (middle of the round).
MCQ_POSITION = 2
# One place a day goes to a question about something people talk about right
# now (the weekly fresh top-up, #202), so the challenge feels current.
TIMELY_PER_SET = 1
# #195 stores a permanent boost as 9999-01-01: boosted forever is not timely.
_PERMANENT_BOOST_FLOOR = datetime(9000, 1, 1, tzinfo=UTC)


def is_timely(q: Question, now: datetime) -> bool:
    """Inside a boost window that ends (the fresh top-up sets one on questions
    tied to a current film, show or event)."""
    until = q.boost_until
    if until is None:
        return False
    if until.tzinfo is None:
        until = until.replace(tzinfo=UTC)
    return now < until < _PERMANENT_BOOST_FLOOR


def pick_daily_set(
    candidates: Sequence[Question],
    *,
    language: str,
    seed: str,
    used_ids: Sequence[str] = (),
    size: int = SET_SIZE,
    now: Optional[datetime] = None,
) -> List[str]:
    """Question ids in play order: one MCQ, the rest open questions, each from a
    different category while the pool allows it.

    With ``now``, one open place goes to a timely question (``is_timely``) that
    no earlier set used, when the pool has one.

    Questions already used by an earlier daily set in this language are avoided
    until the pool runs dry. In sk/cs, questions written in that language come
    before translated English ones.
    """
    rng = random.Random(seed)
    used = set(used_ids)
    fresh = [q for q in candidates if q.id not in used]
    pool = fresh if len(fresh) >= size else list(candidates)

    native = [q for q in pool if q.language == language]
    other = [q for q in pool if q.language != language]
    rng.shuffle(native)
    rng.shuffle(other)
    ordered = native + other

    mcq = [q for q in ordered if q.type == MCQ_TYPE]
    open_ = [q for q in ordered if q.type != MCQ_TYPE]

    picked: List[Question] = mcq[:MCQ_PER_SET]
    if now is not None:
        timely = [q for q in open_ if q.id not in used and is_timely(q, now)]
        picked += timely[:TIMELY_PER_SET]
    seen_categories = {q.category for q in picked}
    for q in open_:
        if len(picked) >= size:
            break
        if q.category not in seen_categories and q not in picked:
            picked.append(q)
            seen_categories.add(q.category)
    # Not enough distinct categories (or open questions): fill from what is left.
    picked_ids = {q.id for q in picked}
    for q in open_ + mcq[MCQ_PER_SET:]:
        if len(picked) >= size:
            break
        if q.id not in picked_ids:
            picked.append(q)
            picked_ids.add(q.id)

    open_picked = [q for q in picked if q.type != MCQ_TYPE]
    mcq_picked = [q for q in picked if q.type == MCQ_TYPE]
    order = open_picked
    for q in mcq_picked:
        order.insert(min(MCQ_POSITION, len(order)), q)
    return [q.id for q in order]
