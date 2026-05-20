"""Unit tests for DedupStage (issue #36 task 2.8).

Why these scenarios:

- `test_drops_cosine_near_duplicates`: this is the headline contract —
  three near-duplicate questions land in the corpus, and the stage must
  drop the two that exceed the cosine threshold. Without this, the pack
  ships paraphrases of questions the user has already seen, which kills
  the "fresh content" promise of pack generation.
- `test_drops_jaccard_match_against_gold_standard`: the curated
  `gold_standard.json` is our reviewer baseline; a pack that mirrors it
  is both lazy and pollutes evaluation signal. The Jaccard branch must
  drop on a near-verbatim match even when the cosine branch would not
  fire (cold corpus / no embedding match).
- `test_keeps_question_when_only_self_match`: re-runs of the orchestrator
  on the same input must be idempotent. If the stage treated a
  question's own id as a duplicate of itself, every retry would empty
  the pack — silent and catastrophic.
- `test_publishes_dropped_count_in_stage_info`: SSE clients (#33 task
  1.11) surface per-step info to the iOS UI. The "dropped" count is how
  the operator sees the filter doing its job — it must reach the sink
  via `StageResult.info`.
- `test_empty_questions_returns_zero_counts`: empty input is the
  no-op path. Proves the stage tolerates an upstream that drained the
  pack (verification dropping everything) without crashing.
"""

from __future__ import annotations

import json
import uuid
from pathlib import Path
from typing import Any

import pytest

from app.orchestrator import OrderContext
from app.orchestrator.stages.dedup import (
    DEFAULT_COSINE_THRESHOLD,
    DEFAULT_JACCARD_THRESHOLD,
    DedupStage,
)
from quiz_shared.models.question import Question


class _RecordingSink:
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


class _FakeQuestionStore:
    """QuestionStore double whose `find_duplicates` returns canned matches.

    Caller seeds {question_text: [(Question, similarity)]} keyed by the
    *query* text. Other QuestionStore methods are stubbed; DedupStage only
    needs `find_duplicates`.
    """

    def __init__(
        self,
        canned: dict[str, list[tuple[Question, float]]] | None = None,
    ) -> None:
        self._canned = canned or {}
        self.find_calls: list[tuple[str, float]] = []

    # Methods DedupStage uses:
    def find_duplicates(
        self, question_text: str, threshold: float = 0.85
    ) -> list[tuple[Question, float]]:
        self.find_calls.append((question_text, threshold))
        matches = self._canned.get(question_text, [])
        return [(q, s) for q, s in matches if s >= threshold]

    # Unused-by-DedupStage protocol methods (kept so we satisfy QuestionStore):
    def add(self, question: Question) -> bool: return True
    def upsert(self, question: Question) -> bool: return True
    def get(self, question_id: str) -> Question | None: return None
    def delete(self, question_id: str) -> bool: return True
    def search(self, **kwargs: Any) -> list[Question]: return []
    def count(self, filters: dict[str, Any] | None = None) -> int: return 0
    def get_all(self, limit: int = 1000) -> list[Question]: return []


def _stub_question(idx: int, text: str | None = None, **overrides: Any) -> Question:
    base: dict[str, Any] = dict(
        id=f"q_{idx}",
        question=text or f"stub question {idx}",
        correct_answer="answer",
        topic="General",
        category="general",
        difficulty="medium",
    )
    base.update(overrides)
    return Question(**base)


def _make_ctx(questions: list[Question]) -> OrderContext:
    ctx = OrderContext(
        order_id=uuid.uuid4(),
        prompt="famous capitals",
        language="en",
        target_count=len(questions),
    )
    ctx.questions = list(questions)
    return ctx


@pytest.fixture
def empty_gold_standard(tmp_path: Path) -> Path:
    p = tmp_path / "gold_standard.json"
    p.write_text("[]", encoding="utf-8")
    return p


@pytest.mark.asyncio
async def test_drops_cosine_near_duplicates(empty_gold_standard: Path) -> None:
    """Three near-dups seeded in the store: the two flagged at ≥ 0.85 drop,
    the one at 0.60 (below threshold) stays."""
    existing = _stub_question(99, text="What is the capital of France?")
    canned = {
        "What is the capital of France?": [(existing, 0.95)],
        "Which city is France's capital?": [(existing, 0.91)],
        "What city in France has the most museums?": [(existing, 0.60)],
    }
    store = _FakeQuestionStore(canned)
    stage = DedupStage(store, gold_standard_path=empty_gold_standard)

    incoming = [
        _stub_question(0, text="What is the capital of France?"),
        _stub_question(1, text="Which city is France's capital?"),
        _stub_question(2, text="What city in France has the most museums?"),
    ]
    ctx = _make_ctx(incoming)

    result = await stage.run(ctx, sink=_RecordingSink())  # type: ignore[arg-type]

    surviving_ids = {q.id for q in ctx.questions}
    assert surviving_ids == {"q_2"}
    assert result.info["dropped"] == 2
    assert result.info["kept"] == 1


@pytest.mark.asyncio
async def test_drops_jaccard_match_against_gold_standard(tmp_path: Path) -> None:
    gold = tmp_path / "gold_standard.json"
    gold.write_text(
        json.dumps(
            [
                {
                    "question": "Which spice was so prized the Dutch traded "
                    "Manhattan for a tiny Indonesian island to control it?",
                    "answer": "Nutmeg",
                }
            ]
        ),
        encoding="utf-8",
    )
    store = _FakeQuestionStore()  # cosine branch silent
    stage = DedupStage(store, gold_standard_path=gold)

    near_verbatim = _stub_question(
        0,
        text=(
            "Which spice was so prized the Dutch traded Manhattan "
            "for a tiny Indonesian island to control it?"
        ),
    )
    unrelated = _stub_question(
        1,
        text="What year did the first human walk on the Moon?",
    )
    ctx = _make_ctx([near_verbatim, unrelated])

    result = await stage.run(ctx, sink=_RecordingSink())  # type: ignore[arg-type]

    surviving_ids = {q.id for q in ctx.questions}
    assert surviving_ids == {"q_1"}
    assert result.info["dropped"] == 1


@pytest.mark.asyncio
async def test_keeps_question_when_only_self_match(empty_gold_standard: Path) -> None:
    """Re-running the orchestrator on a persisted question must be idempotent —
    the stage must not drop a question because the store's find_duplicates
    echoes the question's own id back."""
    self_match = _stub_question(0, text="Already persisted question")
    canned = {
        "Already persisted question": [(self_match, 0.99)],
    }
    store = _FakeQuestionStore(canned)
    stage = DedupStage(store, gold_standard_path=empty_gold_standard)
    ctx = _make_ctx([self_match])

    result = await stage.run(ctx, sink=_RecordingSink())  # type: ignore[arg-type]

    assert [q.id for q in ctx.questions] == ["q_0"]
    assert result.info["dropped"] == 0


@pytest.mark.asyncio
async def test_publishes_dropped_count_in_stage_info(
    empty_gold_standard: Path,
) -> None:
    existing = _stub_question(99, text="Mount Everest height in meters?")
    canned = {
        "Mount Everest height in meters?": [(existing, 0.90)],
    }
    store = _FakeQuestionStore(canned)
    stage = DedupStage(store, gold_standard_path=empty_gold_standard)
    ctx = _make_ctx([_stub_question(0, text="Mount Everest height in meters?")])

    result = await stage.run(ctx, sink=_RecordingSink())  # type: ignore[arg-type]

    assert "dropped" in result.info
    assert result.info["dropped"] == 1


@pytest.mark.asyncio
async def test_empty_questions_returns_zero_counts(
    empty_gold_standard: Path,
) -> None:
    store = _FakeQuestionStore()
    stage = DedupStage(store, gold_standard_path=empty_gold_standard)
    ctx = _make_ctx([])

    result = await stage.run(ctx, sink=_RecordingSink())  # type: ignore[arg-type]

    assert result.info == {"kept": 0, "dropped": 0}
    assert store.find_calls == []


def test_thresholds_default_match_module_constants() -> None:
    """Pin the defaults — a silent threshold drift would change drop rates
    in production without any test failing."""
    assert DEFAULT_COSINE_THRESHOLD == 0.85
    assert DEFAULT_JACCARD_THRESHOLD == 0.80
