"""Sub-themes of a customer pack (#203 203.9 change 2, ``PACK_SUBTHEMES``).

A customer pack used to be one topic generated round after round, so a
30-question "Harry Potter" pack kept circling the same few stand-out facts.
With the flag on, the order's request is split into ``ceil(target / 3.5)``
narrow sub-themes (founder 2026-10-14: 3-4 questions per sub-theme) and every
round after the first generates on the sub-themes with the most quota left.

How it fits the #182 round walk (1 → 2 → 4 → 8 → 8 → rest, TopUpStage):

- Round 1 generates on the whole topic exactly as before, so the first
  question reaches the player without waiting for a planner call; the planner
  runs concurrently with it (``ctx.subtheme_task``).
- Round 2 awaits the plan. Quotas split ``pack target − unstamped questions``
  (round 1's survivors), so the pack still ends at exactly its target.
- What a sub-theme still owes is counted from the ``subtheme`` stamps on the
  questions already in the pack, never from an in-memory counter, so a
  question dropped by verification is simply owed again and a retried
  attempt resumes from what was delivered. Every stamped question also
  carries the plan (``subtheme_plan``, a few hundred bytes), so a retry
  reuses it instead of re-planning a pack that is half-built.
- A planner failure (``None``) leaves the plan empty and the pack runs on the
  whole topic, as before. The order never fails because of the planner.

Arithmetic only, no model calls: the planner is the one judgment call.
"""

from __future__ import annotations

import asyncio
import logging
import math
from collections import Counter
from collections.abc import Sequence
from typing import Any, Protocol

from quiz_shared.models.question import GenerationProvenance, Question

from app.audience import is_child
from app.orchestrator.context import OrderContext

logger = logging.getLogger(__name__)

QUESTIONS_PER_SUBTHEME = 3.5
MIN_QUOTA = 3
MAX_QUOTA = 4

# #236 (second trial 2026-11-17): a child-band pack follows the kids prompt's
# "Range" rule (no two questions feel like siblings), so its sub-themes carry
# 1-2 questions each, about two sub-themes per three questions. The adult 3-4
# shape put every question after round 1 of a 4-question "Harry Potter
# through the real world: owls, potion chemistry, ..." pack on the first
# sub-theme (`budget // MIN_QUOTA` = 1 used): 3 of 4 were about owls.
CHILD_QUESTIONS_PER_SUBTHEME = 1.5
CHILD_MIN_QUOTA = 1
CHILD_MAX_QUOTA = 2
# Sub-theme generation calls of one round run concurrently, a few at a time
# (a round of 8 is two or three calls).
SUBTHEME_CONCURRENCY = 3

# Keys in `GenerationProvenance.extra`, persisted with the question row.
SUBTHEME_KEY = "subtheme"
PLAN_KEY = "subtheme_plan"


class SubthemeProposer(Protocol):
    async def propose_subthemes(
        self, request: str, language: str, count: int, audience: str | None = None
    ) -> list[str] | None: ...


# One generation call of a round: (sub-theme, or None for the whole topic; count).
Call = tuple[str | None, int]


def _shape(audience: str | None) -> tuple[float, int, int]:
    """(questions per sub-theme, min quota, max quota) for the order's band."""
    if is_child(audience):
        return CHILD_QUESTIONS_PER_SUBTHEME, CHILD_MIN_QUOTA, CHILD_MAX_QUOTA
    return QUESTIONS_PER_SUBTHEME, MIN_QUOTA, MAX_QUOTA


def subtheme_count(pack_target: int, audience: str | None = None) -> int:
    per, _, _ = _shape(audience)
    return max(1, math.ceil(pack_target / per))


def stamp_of(question: Question) -> str | None:
    meta = question.generation_metadata
    if meta is None:
        return None
    value = meta.extra.get(SUBTHEME_KEY)
    return value if isinstance(value, str) and value else None


def stamp(questions: Sequence[Question], name: str, plan: list[dict[str, Any]]) -> None:
    for q in questions:
        meta = q.generation_metadata or GenerationProvenance()
        q.generation_metadata = meta.model_copy(
            update={"extra": {**meta.extra, SUBTHEME_KEY: name, PLAN_KEY: plan}}
        )


def split_quotas(
    names: Sequence[str], budget: int, audience: str | None = None
) -> list[dict[str, Any]]:
    """Spread ``budget`` evenly over as many sub-themes as keep every quota at
    3 or more, each capped at 4 (a child band: 1 or more, capped at 2). When
    the planner returned too few names the cap leaves part of the budget
    unplanned; that part is generated on the whole topic (see ``allocate``)."""
    if budget <= 0 or not names:
        return []
    _, min_quota, max_quota = _shape(audience)
    used = max(1, min(len(names), budget // min_quota))
    base, extra = divmod(budget, used)
    return [
        {"name": name, "quota": min(max_quota, base + (1 if i < extra else 0))}
        for i, name in enumerate(names[:used])
    ]


def restore_plan(questions: Sequence[Question]) -> list[dict[str, Any]] | None:
    """The plan a previous attempt stamped onto its questions, if any."""
    for q in questions:
        if stamp_of(q) is None:
            continue
        raw = q.generation_metadata.extra.get(PLAN_KEY)  # type: ignore[union-attr]
        if isinstance(raw, list) and raw and all(
            isinstance(p, dict)
            and isinstance(p.get("name"), str)
            and isinstance(p.get("quota"), int)
            for p in raw
        ):
            return [{"name": p["name"], "quota": p["quota"]} for p in raw]
    return None


def allocate(
    plan: list[dict[str, Any]], questions: Sequence[Question], size: int
) -> list[Call]:
    """This round's calls: sub-themes with the most quota left first (plan
    order breaks ties), then anything the plan cannot cover on the whole
    topic."""
    done = Counter(stamp_of(q) for q in questions)
    owed = [(p["name"], p["quota"] - done.get(p["name"], 0)) for p in plan]
    owed.sort(key=lambda item: -item[1])  # stable: plan order breaks ties
    calls: list[Call] = []
    left = size
    for name, remaining in owed:
        if left <= 0:
            break
        if remaining <= 0:
            continue
        n = min(remaining, left)
        calls.append((name, n))
        left -= n
    if left > 0:
        calls.append((None, left))
    return calls


async def round_calls(
    ctx: OrderContext, planner: SubthemeProposer, request: str
) -> list[Call]:
    """Decide how this round's ``ctx.target_count`` questions are generated."""
    size = ctx.target_count
    pack_target = ctx.pack_target or size
    if ctx.subtheme_plan is None:
        restored = restore_plan(ctx.questions)
        if restored is not None:
            ctx.subtheme_plan = restored
        elif ctx.subtheme_task is not None:
            try:
                names = await ctx.subtheme_task
            except Exception:  # a planner fault never fails the order
                logger.warning(
                    "subthemes order_id=%s: planner raised", ctx.order_id, exc_info=True
                )
                names = None
            ctx.subtheme_task = None
            ctx.subtheme_plan = _plan_from(names, ctx, pack_target)
        elif any(stamp_of(q) for q in ctx.questions):
            # Stamped without a readable plan: re-splitting would overshoot
            # the quotas already spent, so the rest goes on the whole topic.
            logger.warning(
                "subthemes order_id=%s: stamped questions without a plan — "
                "whole-topic generation for the rest",
                ctx.order_id,
            )
            ctx.subtheme_plan = []
        else:
            if size < pack_target:
                # More rounds follow: plan them while this one generates.
                # #236: only a child-band call carries the band, so an adult
                # call stays exactly as before.
                band = {"audience": ctx.audience} if is_child(ctx.audience) else {}
                ctx.subtheme_task = asyncio.create_task(
                    planner.propose_subthemes(
                        request,
                        ctx.language,
                        subtheme_count(pack_target, ctx.audience),
                        **band,
                    )
                )
            return [(None, size)]
    if not ctx.subtheme_plan:
        return [(None, size)]
    return allocate(ctx.subtheme_plan, ctx.questions, size)


def _plan_from(
    names: list[str] | None, ctx: OrderContext, pack_target: int
) -> list[dict[str, Any]]:
    if not names:
        logger.warning(
            "subthemes order_id=%s: planner returned nothing — the pack "
            "continues on the whole topic",
            ctx.order_id,
        )
        return []
    unstamped = sum(1 for q in ctx.questions if stamp_of(q) is None)
    plan = split_quotas(names, pack_target - unstamped, ctx.audience)
    logger.info("subthemes order_id=%s plan=%s", ctx.order_id, plan)
    return plan
