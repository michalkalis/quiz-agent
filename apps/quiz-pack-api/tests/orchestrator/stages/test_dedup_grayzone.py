"""#170 D7 — gray-zone judge in `DedupStage` (`grayzone_judge`, default OFF).

Why: the 0.70–0.85 band is where "same fact" and "same topic" overlap on
question-only cosine (0.735 dup vs 0.738 non-dup). A cheap pairwise verdict
closes it — but it must stay a bounded, explicit, opt-in lever: no call
outside the band, its own drop reason, and a loud (never silent) fallback to
today's behaviour once the budget is gone. Without a judge the store must be
asked exactly as before (byte-identical customer path).
"""

from __future__ import annotations

import uuid
from pathlib import Path
from typing import Any

import pytest
from app.orchestrator import OrderContext
from app.orchestrator.stages.dedup import DEFAULT_COSINE_THRESHOLD, DedupStage
from app.orchestrator.stages.grayzone_judge import GRAYZONE_LOW, GrayZoneJudge
from langchain_core.messages import AIMessage
from quiz_shared.models.question import Question


class _NullSink:
    async def start_step(self, step: str, info: Any = None) -> int:
        return 0

    async def finish_step(self, step: str, event_id: int, info: Any = None) -> None:
        return None

    async def publish(self, event_id: int, step: str, progress: int, info: Any = None) -> None:
        return None


class _FakeQuestionStore:
    def __init__(self, canned: dict[str, list[tuple[Question, float]]]) -> None:
        self._canned = canned
        self.find_calls: list[tuple[str, float]] = []

    async def find_duplicates(
        self, question_text: str, threshold: float = 0.85
    ) -> list[tuple[Question, float]]:
        self.find_calls.append((question_text, threshold))
        return [(q, s) for q, s in self._canned.get(question_text, []) if s >= threshold]


class _FakeVerdictClient:
    """`chat_openai`-shaped double: returns canned one-word verdicts in order."""

    def __init__(self, verdicts: list[str]) -> None:
        self._verdicts = list(verdicts)
        self.prompts: list[str] = []

    async def ainvoke(self, prompt: str) -> AIMessage:
        self.prompts.append(prompt)
        return AIMessage(content=self._verdicts.pop(0))


def _judge(*verdicts: str, max_calls: int = 20) -> tuple[GrayZoneJudge, _FakeVerdictClient]:
    client = _FakeVerdictClient(list(verdicts))
    return GrayZoneJudge(model="test-judge", max_calls=max_calls, client=client), client


def _q(idx: int, text: str, answer: str = "Saturn") -> Question:
    return Question(
        id=f"q_{idx}",
        question=text,
        correct_answer=answer,
        topic="Space",
        category="science-nature",
        difficulty="medium",
    )


def _ctx(questions: list[Question]) -> OrderContext:
    ctx = OrderContext(order_id=uuid.uuid4(), prompt="space", language="en", target_count=len(questions))
    ctx.questions = list(questions)
    return ctx


CORPUS = _q(99, "Which planet has the most moons?")


@pytest.fixture
def gold(tmp_path: Path) -> Path:
    p = tmp_path / "gold_standard.json"
    p.write_text("[]", encoding="utf-8")
    return p


@pytest.mark.asyncio
async def test_judge_is_never_called_outside_the_band(gold: Path) -> None:
    """A clear cosine dup (≥ 0.85) drops WITHOUT a judge call; a clear
    non-match (< 0.70) passes WITHOUT a judge call — the model only ever sees
    the band."""
    judge, client = _judge("YES", "YES")
    clear_dup = _q(0, "Which planet has the most moons?")
    clear_pass = _q(1, "Which river flows through Vienna?", "Danube")
    store = _FakeQuestionStore(
        {clear_dup.question: [(CORPUS, 0.97)], clear_pass.question: [(CORPUS, 0.55)]}
    )
    stage = DedupStage(store, gold_standard_path=gold, grayzone_judge=judge)
    ctx = _ctx([clear_dup, clear_pass])

    result = await stage.run(ctx, _NullSink())  # type: ignore[arg-type]

    assert [q.id for q in ctx.questions] == ["q_1"]
    assert client.prompts == []
    assert result.info["drop_reasons"]["cosine"] == 1
    assert result.info["drop_reasons"]["grayzone_judge"] == 0
    assert result.info["grayzone_judge_calls"] == 0
    # With a judge the store is asked down to the band's lower edge.
    assert all(thr == GRAYZONE_LOW for _, thr in store.find_calls)


@pytest.mark.asyncio
async def test_duplicate_verdict_drops_under_its_own_reason(gold: Path) -> None:
    judge, client = _judge("YES", "NO")
    same_fact = _q(0, "Which planet is orbited by the most moons?")
    same_topic = _q(1, "Which planet has rings made mostly of ice?")
    store = _FakeQuestionStore(
        {same_fact.question: [(CORPUS, 0.78)], same_topic.question: [(CORPUS, 0.74)]}
    )
    stage = DedupStage(store, gold_standard_path=gold, grayzone_judge=judge)
    ctx = _ctx([same_fact, same_topic])

    result = await stage.run(ctx, _NullSink())  # type: ignore[arg-type]

    assert [q.id for q in ctx.questions] == ["q_1"]
    assert result.info["drop_reasons"]["grayzone_judge"] == 1
    assert result.info["drop_reasons"]["cosine"] == 0
    assert result.info["grayzone_judge_calls"] == 2
    # The judge saw both questions AND both answers of the pair.
    assert CORPUS.question in client.prompts[0]
    assert same_fact.question in client.prompts[0]
    assert "Saturn" in client.prompts[0]
    # The trace names the pair and the score for the replay/diff consumers.
    dropped = next(d for d in stage.last_decisions if d["id"] == "q_0")
    assert dropped == {
        "id": "q_0",
        "question": same_fact.question,
        "kept": False,
        "reason": "grayzone_judge",
        "match_id": "q_99",
        "match_question": CORPUS.question,
        "score": 0.78,
    }
    kept = next(d for d in stage.last_decisions if d["id"] == "q_1")
    assert kept["kept"] is True and kept["reason"] is None and kept["score"] == 0.74


@pytest.mark.asyncio
async def test_budget_exhaustion_falls_back_loudly(
    gold: Path, caplog: pytest.LogCaptureFixture
) -> None:
    """After MAX_CALLS: no call, today's behaviour (below threshold ⇒ pass),
    and a warning carrying the count — never a silent pass."""
    judge, client = _judge("NO", max_calls=1)
    first = _q(0, "Which planet is orbited by the most moons?")
    second = _q(1, "Which gas giant boasts the largest number of natural satellites?")
    store = _FakeQuestionStore(
        {first.question: [(CORPUS, 0.80)], second.question: [(CORPUS, 0.82)]}
    )
    stage = DedupStage(store, gold_standard_path=gold, grayzone_judge=judge)
    ctx = _ctx([first, second])

    with caplog.at_level("WARNING", logger="app.orchestrator.stages.grayzone_judge"):
        result = await stage.run(ctx, _NullSink())  # type: ignore[arg-type]

    assert [q.id for q in ctx.questions] == ["q_0", "q_1"]
    assert len(client.prompts) == 1
    assert result.info["grayzone_judge_calls"] == 1
    assert result.info["grayzone_judge_skipped"] == 1
    assert any("budget exhausted (1/1" in r.getMessage() for r in caplog.records)


@pytest.mark.asyncio
async def test_unparseable_verdict_passes_with_a_warning(
    gold: Path, caplog: pytest.LogCaptureFixture
) -> None:
    judge, _ = _judge("I am not sure about this one.")
    q = _q(0, "Which planet is orbited by the most moons?")
    store = _FakeQuestionStore({q.question: [(CORPUS, 0.78)]})
    stage = DedupStage(store, gold_standard_path=gold, grayzone_judge=judge)

    with caplog.at_level("WARNING", logger="app.orchestrator.stages.grayzone_judge"):
        result = await stage.run(_ctx([q]), _NullSink())  # type: ignore[arg-type]

    assert result.info["kept"] == 1
    assert any("unparseable verdict" in r.getMessage() for r in caplog.records)


@pytest.mark.asyncio
async def test_without_judge_the_store_is_asked_at_the_legacy_threshold(gold: Path) -> None:
    """Default OFF = byte-identical query: the store sees the category cosine
    threshold, not the band's lower edge; judge accounting stays at zero."""
    q = _q(0, "Which planet has the most moons?")
    store = _FakeQuestionStore({q.question: [(CORPUS, 0.78)]})
    stage = DedupStage(store, gold_standard_path=gold)

    result = await stage.run(_ctx([q]), _NullSink())  # type: ignore[arg-type]

    assert store.find_calls == [(q.question, DEFAULT_COSINE_THRESHOLD)]
    assert result.info["kept"] == 1
    assert result.info["grayzone_judge_calls"] == 0
    assert stage.last_decisions == [
        {
            "id": "q_0",
            "question": q.question,
            "kept": True,
            "reason": None,
            "match_id": None,
            "match_question": None,
            "score": None,
        }
    ]
