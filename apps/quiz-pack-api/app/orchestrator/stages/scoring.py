"""ScoringStage — MultiModelScorer as the fail-loud ship gate (issue #36 task
2.7; gate added #42 task 42.29).

The stage adapts `OrderContext.questions` to the dict shape
`MultiModelScorer.score_batch` expects, calls the existing scorer, then
writes per-model overall scores into `ctx.scores` keyed by question id:

    ctx.scores[question_id] = {
        "<model_name>": overall_score,
        ...
    }

**#42 task 42.29 — this stage now DROPS, not just scores.** The Track F-R
review (2026-06-19) designated `MultiModelScorer` the single blocking
quality gate; two scorers that only ever warned were "false confidence"
(CLAUDE.md Rule #2 — fail loud). A question is dropped when:

- its mean ``overall_score`` across models is below ``MIN_OVERALL_SCORE``
  (a low floor — only catastrophically bad questions), or
- (MCQ only) its ``distractor_quality`` is below ``MIN_DISTRACTOR_QUALITY``
  — catches duplicate / substring-leaking / length-skewed distractors
  (``distractor_quality`` is the deterministic dim from task 42.6, attached
  identically to every model's ``scores`` sub-dict; ``None`` for free-form).

A question the scorer could not score at all (empty ``model_scores``) is
KEPT — we never drop on the absence of a judgment, only on a bad one. The
drop count is surfaced via ``StageResult.info["dropped_low_score"]``,
mirroring ``DedupStage.info["dropped"]`` so SSE/audit clients see it.
"""

from __future__ import annotations

import logging

from app.orchestrator.context import OrderContext, StageResult
from app.orchestrator.progress_sink import ProgressSink
from app.scoring.multi_model_scorer import MultiModelScorer

logger = logging.getLogger(__name__)

# Drop thresholds (module-level constants, not magic numbers — #42 task 42.29).
# Deliberately lenient: the gate removes broken questions, it is not a top-K
# trimmer. Tune here, not at call sites.
MIN_OVERALL_SCORE = 3.0
MIN_DISTRACTOR_QUALITY = 4


class ScoringStage:
    """Scores via MultiModelScorer; drops questions below the quality gate."""

    name = "scoring"

    def __init__(self, scorer: MultiModelScorer) -> None:
        self._scorer = scorer

    async def run(self, ctx: OrderContext, sink: ProgressSink) -> StageResult:
        if not ctx.questions:
            return StageResult(info={"scored": 0, "dropped_low_score": 0}, cost_cents=0)

        payload = [
            {
                "id": q.id,
                "question": q.question,
                "correct_answer": _stringify_answer(q.correct_answer),
                "difficulty": q.difficulty,
                "topic": q.topic,
                "possible_answers": q.possible_answers,
            }
            for q in ctx.questions
        ]
        results = await self._scorer.score_batch(payload)
        scores_by_id = {
            r.get("id"): r.get("model_scores", [])
            for r in results
            if r.get("id") is not None
        }

        kept: list = []
        dropped = 0
        for q in ctx.questions:
            model_scores = scores_by_id.get(q.id, [])

            # Keep the per-model overall map in ctx.scores for downstream
            # review tooling (advisory) — including for dropped questions, so
            # an audit can see *why* they failed the gate.
            per_model: dict[str, float] = {}
            for score in model_scores:
                name = score.get("model_name")
                overall = score.get("overall_score")
                if name is None or overall is None:
                    continue
                per_model[name] = float(overall)
            ctx.scores[q.id] = per_model

            drop_reason = self._gate_reason(model_scores)
            if drop_reason is not None:
                dropped += 1
                logger.warning(
                    "ScoringStage dropped question id=%s reason=%s", q.id, drop_reason
                )
                continue
            kept.append(q)

        ctx.questions = kept
        return StageResult(
            info={"scored": len(ctx.scores), "dropped_low_score": dropped},
            cost_cents=0,
        )

    @staticmethod
    def _gate_reason(model_scores: list[dict]) -> str | None:
        """Return a drop reason if the question fails the gate, else None.

        Unscored questions (empty ``model_scores``) return None — absence of
        a judgment is not a failed judgment, so they are kept.
        """
        overalls = [
            float(s["overall_score"])
            for s in model_scores
            if s.get("overall_score") is not None
        ]
        if overalls and (sum(overalls) / len(overalls)) < MIN_OVERALL_SCORE:
            return f"overall_below_{MIN_OVERALL_SCORE}"

        # distractor_quality is deterministic and identical across models
        # (#42 task 42.6); MCQ-only (None for free-form). First entry carrying
        # it is representative.
        for s in model_scores:
            dq = (s.get("scores") or {}).get("distractor_quality")
            if dq is not None and dq < MIN_DISTRACTOR_QUALITY:
                return f"distractor_quality_below_{MIN_DISTRACTOR_QUALITY}"
        return None


def _stringify_answer(answer: object) -> str:
    """Flatten Question.correct_answer (str | list[str]) for the scorer API."""
    if isinstance(answer, list):
        return ", ".join(str(a) for a in answer)
    return str(answer)
