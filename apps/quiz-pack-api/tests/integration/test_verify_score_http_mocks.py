"""Verifier + scorer HTTP mock smoke tests (issue #36 task 2.11d).

Runs the real ``VerificationStage`` and ``ScoringStage`` against canned
HTTP responses from ``verify_score_http_mocks``. These pin the contracts
between the stage wrappers and the underlying ``FactVerifier`` /
``MultiModelScorer`` collaborators so the 2.11e e2e test can layer them
in unchanged.

Coverage rationale:

- ``test_verification_stage_keeps_all_five_questions``: Tavily mock returns
  three results that all contain the lowercase claimed answer ("three"), so
  ``FactVerifier`` reaches the heuristic verified branch (confidence ≈ 0.95).
  Tests that every question survives the stage's drop filter — the
  acceptance line "verifier returns the 5 questions it was given (none
  dropped)" depends on this happy-path behaviour.
- ``test_scoring_stage_fills_ctx_scores_for_all``: confirms the stage writes
  one ``ctx.scores`` entry per question id with the OpenAI mock returning a
  valid scoring payload. The keys-by-id check guards the join between
  questions and per-model scores that downstream review tooling depends on.

Gemini and Anthropic providers are intentionally NOT configured for these
tests: ``GOOGLE_API_KEY`` and ``ANTHROPIC_API_KEY`` are unset so the verifier
takes the heuristic Tavily-only path and the scorer's default-model list is
OpenAI-only. The Anthropic ``/v1/messages`` route is still registered in the
fixture so a future config change can't silently leak real HTTPS.
"""

from __future__ import annotations

import uuid
from typing import Any

import pytest

from app.orchestrator import OrderContext
from app.orchestrator.stages.scoring import ScoringStage
from app.orchestrator.stages.verification import VerificationStage
from app.scoring.multi_model_scorer import MultiModelScorer
from app.verification.fact_verifier import FactVerifier
from quiz_shared.models.question import Question


@pytest.fixture(autouse=True)
def _llm_api_keys(monkeypatch: pytest.MonkeyPatch) -> None:
    """OpenAI + Tavily need env-var keys; Gemini/Anthropic stay unset."""
    monkeypatch.setenv("OPENAI_API_KEY", "test-key-for-mocks")
    monkeypatch.setenv("TAVILY_API_KEY", "test-key-for-mocks")
    monkeypatch.delenv("GOOGLE_API_KEY", raising=False)
    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)


class _RecordingSink:
    """In-memory ProgressSink double — same shape as test_scoring.py's."""

    def __init__(self) -> None:
        self.events: list[tuple[str, str, Any]] = []
        self._next_id = 0

    async def start_step(self, step: str, info: Any = None) -> int:
        eid = self._next_id
        self._next_id += 1
        self.events.append(("start", step, info))
        return eid

    async def finish_step(self, step: str, event_id: int, info: Any = None) -> None:
        self.events.append(("finish", step, info))

    async def publish(
        self, event_id: int, step: str, progress: int, info: Any = None
    ) -> None:
        self.events.append(("publish", step, info))


def _stub_question(idx: int) -> Question:
    """Question whose claimed answer matches the verifier Tavily mock content."""
    return Question(
        id=f"q_{idx}",
        question=f"How many hearts does an octopus have? (variant {idx})",
        correct_answer="three",
        topic="Biology",
        category="science",
        difficulty="medium",
    )


def _make_ctx(questions: list[Question]) -> OrderContext:
    ctx = OrderContext(
        order_id=uuid.uuid4(),
        prompt="surprising animal anatomy",
        language="en",
        target_count=len(questions),
    )
    ctx.questions = list(questions)
    return ctx


async def test_verification_stage_keeps_all_five_questions(
    verify_score_http_mocks,
) -> None:
    """All 5 questions survive when Tavily mock returns agreeing evidence."""
    ctx = _make_ctx([_stub_question(i) for i in range(5)])
    stage = VerificationStage(FactVerifier())

    result = await stage.run(ctx, sink=_RecordingSink())  # type: ignore[arg-type]

    assert len(ctx.questions) == 5, (
        f"expected all 5 questions kept, got {len(ctx.questions)}"
    )
    assert result.info["dropped"] == 0
    assert result.info["verified"] == 5
    for q in ctx.questions:
        extra = (q.generation_metadata or {}).extra if q.generation_metadata else {}
        assert extra.get("verified") is True, (
            f"question {q.id} should be flagged verified, got extra={extra}"
        )
        assert extra.get("verification_score", 0.0) >= 0.5


async def test_scoring_stage_fills_ctx_scores_for_all(
    verify_score_http_mocks,
) -> None:
    """ScoringStage writes one ctx.scores entry per question id."""
    ctx = _make_ctx([_stub_question(i) for i in range(5)])
    stage = ScoringStage(MultiModelScorer())

    result = await stage.run(ctx, sink=_RecordingSink())  # type: ignore[arg-type]

    assert set(ctx.scores.keys()) == {f"q_{i}" for i in range(5)}, (
        f"expected ctx.scores keyed by all 5 question ids, got "
        f"{sorted(ctx.scores.keys())}"
    )
    assert result.info["scored"] == 5
    for qid, per_model in ctx.scores.items():
        assert per_model, f"question {qid} got no model scores"
        assert all(score > 0 for score in per_model.values())
