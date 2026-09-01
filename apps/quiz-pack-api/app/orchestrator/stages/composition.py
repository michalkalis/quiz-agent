"""CompositionStage — deterministic batch-composition caps (#153 Phase 0.1).

The 2026-08-07 rated batch showed that per-question quality gates cannot see
batch-level defects: 27 questions drew on ~2 themes (13+13) and 6 of 8 MCQs
were true/false. Founder-approved rules, enforced here with zero LLM calls:

- **Topic cap** — at most 2 questions per (normalized) topic per 30-pack,
  scaled as ``max(1, ceil(2 * target / 30))`` for other sizes. Overridable
  per run via the constructor (``--per-topic-cap`` on the CLI, #167) for
  batches with a deliberately small locked topic set.
- **True/false cap** — at most 2 T/F questions per 30-pack, same scaling.

Runs after ``ScoringStage`` (in the main walk and inside every top-up round)
so that when judge scores exist the caps keep each topic's/format's
best-scored questions; without scores (judges-off experiment runs) original
generation order decides. Dropping below ``target_count`` is fine — the
top-up loop regenerates the shortfall and re-applies the caps each round.

Drops are loud: one warning per dropped question with the binding cap, and
counts in ``StageResult.info``.
"""

from __future__ import annotations

import logging
import math
import re

from app.orchestrator.context import OrderContext, StageResult
from app.orchestrator.progress_sink import ProgressSink
from app.scoring import craft_guards

logger = logging.getLogger(__name__)

# Founder rule of thumb: a 30-pack samples 12-15 topics, so no topic appears
# more than twice, and T/F stays a rarity rather than a default format.
PER_30_TOPIC_CAP = 2
PER_30_TF_CAP = 2

_NORM_RE = re.compile(r"[a-z0-9]+")


def _scaled_cap(per_30: int, target: int, floor: int = 1) -> int:
    return max(floor, math.ceil(per_30 * target / 30))


def _normalize_topic(topic: str | None) -> str:
    return " ".join(_NORM_RE.findall((topic or "").lower()))


class CompositionStage:
    """Enforces per-topic and true/false caps on the surviving batch."""

    name = "composition"

    def __init__(self, per_topic_cap: int | None = None) -> None:
        """``per_topic_cap`` overrides the scaled per-topic cap for this run.

        #167: the entertainment pilot locks a small themed topic set (6
        themes x ~5 questions), so the "~target/2 topics" assumption behind
        the scaled cap does not hold — a cap of 2 made 30 questions
        arithmetically unreachable from 6 topics and the top-up loop burned
        the full judge/verify/score pipeline chasing an impossible target.
        Operator-set (CLI only); ``None`` keeps the scaled default, which is
        what the API/worker path always uses.
        """
        self._per_topic_cap = per_topic_cap

    async def run(self, ctx: OrderContext, sink: ProgressSink) -> StageResult:
        target = ctx.target_count
        # Topic cap keeps a floor of 2: topic sampling yields ~target/2
        # topics (#153 sourcing rule), so a cap of 1 on a small pack would
        # mathematically guarantee a shortfall. T/F has no such risk (the
        # format is substitutable), so its floor stays 1.
        topic_cap = (
            self._per_topic_cap
            if self._per_topic_cap is not None
            else _scaled_cap(PER_30_TOPIC_CAP, target, floor=2)
        )
        tf_cap = _scaled_cap(PER_30_TF_CAP, target)

        # Judge-score order when available (mean of per-model overalls from
        # ctx.scores); stable sort keeps generation order otherwise, so the
        # judges-off experiment path stays deterministic.
        def mean_score(question) -> float:
            per_model = ctx.scores.get(question.id) or {}
            if not per_model:
                return float("-inf")
            return sum(per_model.values()) / len(per_model)

        ranked = sorted(
            enumerate(ctx.questions), key=lambda pair: -mean_score(pair[1])
        )

        topic_counts: dict[str, int] = {}
        tf_count = 0
        kept_indices: list[int] = []
        topic_dropped = 0
        tf_dropped = 0
        for index, q in ranked:
            topic = _normalize_topic(q.topic)
            if topic and topic_counts.get(topic, 0) >= topic_cap:
                topic_dropped += 1
                logger.warning(
                    "CompositionStage dropped id=%s topic=%r over per-topic "
                    "cap %d",
                    q.id, q.topic, topic_cap,
                )
                continue
            is_tf = (
                craft_guards.true_false_key(q.correct_answer, q.possible_answers)
                is not None
            )
            if is_tf and tf_count >= tf_cap:
                tf_dropped += 1
                logger.warning(
                    "CompositionStage dropped id=%s over true/false cap %d",
                    q.id, tf_cap,
                )
                continue
            if topic:
                topic_counts[topic] = topic_counts.get(topic, 0) + 1
            if is_tf:
                tf_count += 1
            kept_indices.append(index)

        kept_indices.sort()
        ctx.questions = [ctx.questions[i] for i in kept_indices]
        return StageResult(
            info={
                "kept": len(kept_indices),
                "topic_cap": topic_cap,
                "tf_cap": tf_cap,
                "topic_cap_dropped": topic_dropped,
                "tf_cap_dropped": tf_dropped,
            },
            cost_cents=0,
        )
