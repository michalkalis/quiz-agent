"""Choosing the day's five questions (#205 205.1). Pure: the caller loads the
candidates and persists the pick, so everyone plays the same set."""

from __future__ import annotations

import random
from typing import List, Sequence

from quiz_shared.models.question import Question

SET_SIZE = 5
MCQ_TYPE = "text_multichoice"
# MCQ ratio rule (~20-30 % of a set): one multiple-choice question in five.
MCQ_PER_SET = 1
# Play position of the multiple-choice question (middle of the round).
MCQ_POSITION = 2


def pick_daily_set(
    candidates: Sequence[Question],
    *,
    language: str,
    seed: str,
    used_ids: Sequence[str] = (),
    size: int = SET_SIZE,
) -> List[str]:
    """Question ids in play order: one MCQ, the rest open questions, each from a
    different category while the pool allows it.

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
    seen_categories = {q.category for q in picked}
    for q in open_:
        if len(picked) >= size:
            break
        if q.category not in seen_categories:
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
