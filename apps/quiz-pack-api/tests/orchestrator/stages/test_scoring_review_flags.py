"""#177 T1 — a flagged-but-KEPT question must carry its reason on the row.

Why this matters: the shadow gates (craft guards in rollback mode, the
always-shadow undated-record heuristic, the judge veto) used to leave their
findings only in `StageResult.info` counters and the worker log, which say *how
many* rows were flagged, never *which*. Import-time machine approval (#177)
has to answer the per-question question — "did anything fire on THIS row?" — so
the reason now travels with the question into the JSON batch and the corpus. If
these pins break, a flagged row silently looks clean at import time and can be
machine-approved into App Store serving.

Split out of `test_scoring.py` (already ~800 lines) to keep both files
navigable.
"""

from __future__ import annotations

import uuid
from typing import Any

import pytest
from app.orchestrator import OrderContext
from app.orchestrator.stages.scoring import ScoringStage
from app.scoring.machine_approval import (
    CRAFT_FLAG_KEY,
    UNDATED_FLAG_KEY,
    VETO_FLAG_KEY,
)
from quiz_shared.models.question import Question


class _Sink:
    async def start_step(self, step: str, info: Any = None) -> int:
        return 0

    async def finish_step(self, step: str, event_id: int, info: Any = None) -> None:
        return None

    async def publish(
        self, event_id: int, step: str, progress: int, info: Any = None
    ) -> None:
        return None


class _FakeScorer:
    """Canned panel verdicts: {question_id: {dim: value}} merged per model."""

    def __init__(self, dims: dict[str, dict[str, float]] | None = None) -> None:
        self._dims = dims or {}

    async def score_batch(
        self, questions: list[dict[str, Any]], sql_client: Any = None
    ) -> list[dict[str, Any]]:
        return [
            {
                "id": q["id"],
                "model_scores": [
                    {
                        "model_name": name,
                        "scores": {
                            "conversation_spark": 8,
                            **self._dims.get(q["id"], {}),
                        },
                        "overall_score": 8.0,
                    }
                    for name in ("gpt-4.1-mini", "gemini-2.5-flash")
                ],
            }
            for q in questions
        ]


def _question(idx: int, **overrides: Any) -> Question:
    base: dict[str, Any] = {
        "id": f"q_{idx}",
        "question": f"stub question {idx}",
        "correct_answer": "answer",
        "topic": "General",
        "category": "general",
        "difficulty": "medium",
    }
    base.update(overrides)
    return Question(**base)


def _ctx(questions: list[Question]) -> OrderContext:
    ctx = OrderContext(
        order_id=uuid.uuid4(),
        prompt="famous capitals",
        language="en",
        target_count=len(questions),
    )
    ctx.questions = list(questions)
    return ctx


def _extra(q: Question) -> dict[str, Any]:
    assert q.generation_metadata is not None
    return q.generation_metadata.extra


@pytest.mark.asyncio
async def test_undated_flag_is_persisted_on_the_kept_question() -> None:
    """The undated-record guard never drops (#99 D2 contract), so persisting
    its reason is the ONLY way the finding can reach the importer."""
    flagged = _question(
        0,
        question="Which country was the first ever to ban commercial whaling?",
        correct_answer="Norway",
    )
    clean = _question(1)
    ctx = _ctx([flagged, clean])

    result = await ScoringStage(_FakeScorer()).run(ctx, sink=_Sink())  # type: ignore[arg-type]

    assert [q.id for q in ctx.questions] == ["q_0", "q_1"]
    assert result.info["undated_shadow_flagged"] == 1
    assert _extra(flagged)[UNDATED_FLAG_KEY]
    # A clean row must stay unmarked — an always-written key would make every
    # row look flagged and block all machine approvals.
    assert UNDATED_FLAG_KEY not in (
        clean.generation_metadata.extra if clean.generation_metadata else {}
    )


@pytest.mark.asyncio
async def test_craft_flag_is_persisted_in_shadow_mode(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """With CRAFT_GUARDS_ENFORCE rolled back to shadow, the leaky row is KEPT —
    and is exactly the row that must not be machine-approved later."""
    monkeypatch.setenv("CRAFT_GUARDS_ENFORCE", "0")
    leaky = _question(
        0,
        question="Which country's propaganda made Napoleon short, per British archives?",
        correct_answer="Britain",
    )
    ctx = _ctx([leaky, _question(1)])

    result = await ScoringStage(_FakeScorer()).run(ctx, sink=_Sink())  # type: ignore[arg-type]

    assert result.info["craft_flagged"] == 1
    assert _extra(leaky)[CRAFT_FLAG_KEY]


@pytest.mark.asyncio
async def test_veto_flag_is_persisted_in_shadow_mode(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Judge veto in shadow mode: the boring dead-end recall question survives
    the pipeline, so its reason has to survive with it."""
    monkeypatch.setenv("VETO_SHADOW", "1")
    monkeypatch.setenv("VETO_ENFORCE", "0")
    boring = _question(0)
    ctx = _ctx([boring, _question(1)])
    dims = {
        "q_0": {"surprise_delight": 2, "answerability": 2},
        "q_1": {"surprise_delight": 8, "answerability": 9},
    }

    result = await ScoringStage(_FakeScorer(dims)).run(ctx, sink=_Sink())  # type: ignore[arg-type]

    assert result.info["veto_shadow_flagged"] == 1
    assert _extra(boring)[VETO_FLAG_KEY]


@pytest.mark.asyncio
async def test_persisted_flag_survives_a_json_round_trip() -> None:
    """`_write_out` dumps and the importer re-parses: the flag is only useful if
    it survives `model_dump` → `Question.model_validate` (provenance keeps
    unknown keys in `extra`)."""
    flagged = _question(
        0,
        question="Which country was the first ever to ban commercial whaling?",
        correct_answer="Norway",
    )
    await ScoringStage(_FakeScorer()).run(_ctx([flagged]), sink=_Sink())  # type: ignore[arg-type]

    reparsed = Question.model_validate(flagged.model_dump(mode="json"))

    assert reparsed.generation_metadata is not None
    assert (
        reparsed.generation_metadata.extra[UNDATED_FLAG_KEY]
        == _extra(flagged)[UNDATED_FLAG_KEY]
    )
