"""E2E MCQ generation test (issue #42 task 42.12).

Pins the cross-track contract that Tracks B + C established: when a
`true_false`-pattern question reaches the orchestrator with
`possible_answers` populated, the persisted question carries
`type="text_multichoice"` so iOS `MCQOptionPicker` activates and the
evaluator's `possible_answers` fast-path (`evaluator.py:77`) routes
correctly. A regression here would silently downgrade MCQ to free-form.

Stages:
- Stub `SourcingStage` — provides one attributed fact (`source_url`)
  so `GenerationStage`'s F8 invariant passes without a real `FactSourcer`.
  Required first per #36 task 2.15: `PackGenerator.__init__` raises
  `ValueError` when the leading stage name is not `"sourcing"`.
- Real `GenerationStage` driven by a stubbed `AdvancedQuestionGenerator`
  that returns a `true_false` question with `possible_answers` and
  `correct_answer="a"`. We exercise the real stage so the 42.9a tagging
  step (pattern → type) actually fires — that's the contract under test.
"""

from __future__ import annotations

import uuid
from typing import Any

import pytest

from app.db.models import GenerationOrder
from app.orchestrator import OrderContext, PackGenerator, StageResult
from app.orchestrator.progress_sink import ProgressSink
from app.orchestrator.stages.generation import GenerationStage
from app.sourcing.models import Fact
from quiz_shared.models.question import GenerationProvenance, Question


class _NoopSink:
    async def start_step(self, step: str, info: Any = None) -> int:
        return 0

    async def finish_step(self, step: str, event_id: int, info: Any = None) -> None:
        return None

    async def publish(
        self, event_id: int, step: str, progress: int, info: Any = None
    ) -> None:
        return None


class _StubSourcingStage:
    """Minimal SourcingStage stand-in.

    Real `SourcingStage` calls `FactSourcer.gather_facts` — we sidestep
    that to keep the test offline. The single fact must carry a
    `source_url` so `GenerationStage`'s F8 fallback can backfill the
    question's attribution.
    """

    name = "sourcing"

    async def run(self, ctx: OrderContext, sink: ProgressSink) -> StageResult:
        ctx.facts = [
            Fact(
                text="The Great Wall of China is not visible from low orbit with the naked eye.",
                source_url="https://example.org/great-wall",
                excerpt="not visible from orbit with the naked eye",
            )
        ]
        return StageResult(info={"facts": 1}, cost_cents=0)


class _StubMCQGenerator:
    """Stubbed `AdvancedQuestionGenerator` that returns a `true_false` MCQ.

    `reasoning_pattern="true_false"` is in `PATTERNS_TO_MCQ`, so the
    `GenerationStage` 42.9a tagging step must set
    `q.type = "text_multichoice"` and keep the question.
    """

    async def generate_questions(self, **kwargs: Any) -> list[Question]:
        return [
            Question(
                id=str(uuid.uuid4()),
                question="True or false: the Great Wall of China is visible from the Moon.",
                correct_answer="a",
                possible_answers={"a": "False", "b": "True"},
                topic="Geography",
                category="general",
                difficulty="easy",
                generation_metadata=GenerationProvenance(
                    reasoning_pattern="true_false"
                ),
            )
        ]


def _make_order() -> GenerationOrder:
    return GenerationOrder(
        id=uuid.uuid4(),
        transaction_id=f"txn_{uuid.uuid4().hex}",
        product_id="pack_10",
        prompt="famous landmarks",
        target_count=1,
        language="en",
        category="general",
        status="in_progress",
    )


@pytest.mark.asyncio
async def test_true_false_pattern_surfaces_as_text_multichoice() -> None:
    """`true_false` pattern + `possible_answers` → persisted as MCQ.

    Why this matters: iOS `MCQOptionPicker` keys off `type`, and the
    evaluator's MCQ fast-path keys off `possible_answers`. Both must
    line up at the orchestrator boundary or the question silently
    degrades to free-form on the wire — the exact bug Track C exists
    to prevent.
    """
    pack_generator = PackGenerator(
        stages=[_StubSourcingStage(), GenerationStage(_StubMCQGenerator())],  # type: ignore[arg-type]
        sink_factory=lambda _oid: _NoopSink(),  # type: ignore[arg-type,return-value]
    )

    await pack_generator.run(_make_order())

    assert pack_generator.last_ctx is not None
    questions = pack_generator.last_ctx.questions
    assert len(questions) == 1

    q = questions[0]
    assert q.type == "text_multichoice"
    assert q.possible_answers is not None
    assert set(q.possible_answers.keys()) == {"a", "b"}
    # Pilot 2026-07-11 hardening: the stage normalizes a key-letter
    # `correct_answer` to the full option text so the stored answer is
    # self-contained (TTS reveal, review renders, evaluator value-match).
    assert q.correct_answer in ("True", "False")
