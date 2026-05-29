"""ScoringStage — thin wrapper around MultiModelScorer (issue #36 task 2.7).

The stage adapts `OrderContext.questions` to the dict shape
`MultiModelScorer.score_batch` expects, calls the existing scorer, then
writes per-model scores into `ctx.scores` keyed by question id:

    ctx.scores[question_id] = {
        "<model_name>": overall_score,
        ...
    }

The stage does NOT drop questions based on score. Drop policy (e.g.
"trim packs to the top-K scoring questions") is deliberately deferred
to Phase 3 (#37) — see issue 36 task 2.7 acceptance + the keep-list in
the focus file. Keeping scoring side-effect-free here means the scorer
output is purely advisory in Phase 2 and easy to inspect post-hoc.
"""

from __future__ import annotations

from app.orchestrator.context import OrderContext, StageResult
from app.orchestrator.progress_sink import ProgressSink
from app.scoring.multi_model_scorer import MultiModelScorer


class ScoringStage:
    """Calls MultiModelScorer.score_batch; writes ctx.scores; never drops."""

    name = "scoring"

    def __init__(self, scorer: MultiModelScorer) -> None:
        self._scorer = scorer

    async def run(self, ctx: OrderContext, sink: ProgressSink) -> StageResult:
        if not ctx.questions:
            return StageResult(info={"scored": 0}, cost_cents=0)

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

        for record in results:
            qid = record.get("id")
            if qid is None:
                continue
            per_model: dict[str, float] = {}
            for score in record.get("model_scores", []):
                name = score.get("model_name")
                overall = score.get("overall_score")
                if name is None or overall is None:
                    continue
                per_model[name] = float(overall)
            ctx.scores[qid] = per_model

        return StageResult(info={"scored": len(ctx.scores)}, cost_cents=0)


def _stringify_answer(answer: object) -> str:
    """Flatten Question.correct_answer (str | list[str]) for the scorer API."""
    if isinstance(answer, list):
        return ", ".join(str(a) for a in answer)
    return str(answer)
