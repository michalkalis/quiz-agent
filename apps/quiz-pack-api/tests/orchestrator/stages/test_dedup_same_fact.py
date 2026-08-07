"""Same-fact in-batch dedup tests for DedupStage (#153 Phase 0.1).

The 2026-08-07 rated batch shipped 4 duplicate pairs — the same fact asked
twice, as open-vs-MCQ rephrasings or paraphrases — because the existing
in-batch check compares raw question-text Jaccard (0.60), which rephrasings
slip under. Question texts here are near-verbatim from that batch, so these
tests pin the fix against the real observed failures:

- `test_drops_cross_format_same_fact`: pair 6/27 — the same "brain slows at
  24" fact as an open question and again as an MCQ. Same source URL + same
  normalized answer must drop the later one regardless of wording.
- `test_drops_paraphrase_of_same_fact_across_sources`: pair 2/26 with
  different source URLs — the fact-key check can't fire, so the
  content-token overlap check (>= 0.35 with stopwords removed) must catch
  the paraphrase (measured 0.52 on this pair vs 0.21 noise ceiling).
- `test_keeps_distinct_facts_from_same_source_url`: one listicle URL feeds
  many distinct facts (sdbif.org carried 72) — same URL with different
  answers must NOT be treated as one fact.
- `test_keeps_distinct_questions_without_source_url`: a missing URL must not
  collapse unrelated questions into one fact key.
"""

from __future__ import annotations

import uuid
from typing import Any

import pytest

from app.orchestrator import OrderContext
from app.orchestrator.stages.dedup import DedupStage
from quiz_shared.models.question import Question


class _NullStore:
    async def find_duplicates(self, question_text, threshold=0.85):
        return []


class _NullSink:
    async def start_step(self, step, info=None):
        return 0

    async def finish_step(self, step, event_id, info=None):
        pass

    async def publish(self, event_id, step, progress, info=None):
        pass


def _question(idx: int, text: str, answer: str, **overrides: Any) -> Question:
    base: dict[str, Any] = dict(
        id=f"q_{idx}",
        question=text,
        correct_answer=answer,
        topic="General",
        category="general",
        difficulty="medium",
    )
    base.update(overrides)
    return Question(**base)


def _ctx(questions: list[Question]) -> OrderContext:
    ctx = OrderContext(
        order_id=uuid.uuid4(),
        prompt="general knowledge",
        language="en",
        target_count=len(questions),
    )
    ctx.questions = list(questions)
    return ctx


def _stage() -> DedupStage:
    return DedupStage(_NullStore(), gold_standard_path=None)


@pytest.mark.asyncio
async def test_drops_cross_format_same_fact():
    url = "https://sdbif.org/72-amazing-human-brain-facts-based-on-the-latest-science"
    open_q = _question(
        1,
        "At what surprisingly young age does the brain reportedly begin "
        "slowing down?",
        "24",
        source_url=url,
    )
    mcq = _question(
        2,
        "At what age does the brain begin slowing down: 24, 40, 55, or 70?",
        "24",
        source_url=url,
        possible_answers={"a": "24", "b": "40", "c": "55", "d": "70"},
    )
    ctx = _ctx([open_q, mcq])

    result = await _stage().run(ctx, _NullSink())

    assert [q.id for q in ctx.questions] == ["q_1"]
    assert result.info["fact_dropped"] == 1


@pytest.mark.asyncio
async def test_drops_paraphrase_of_same_fact_across_sources():
    first = _question(
        1,
        "How did pioneering bandleader James Reese Europe die during "
        "World War One?",
        "Killed by his drummer",
        source_url="https://www.youtube.com/watch?v=2FtfN7X6XQw",
    )
    paraphrase = _question(
        2,
        "What happened to James Reese Europe, the African-American "
        "bandleader who introduced jazz to France?",
        "Killed by his drummer",
        source_url="https://example.com/james-reese-europe-biography",
    )
    ctx = _ctx([first, paraphrase])

    result = await _stage().run(ctx, _NullSink())

    assert [q.id for q in ctx.questions] == ["q_1"]
    assert result.info["fact_dropped"] == 1


@pytest.mark.asyncio
async def test_keeps_distinct_facts_from_same_source_url():
    url = "https://sdbif.org/72-amazing-human-brain-facts-based-on-the-latest-science"
    age_fact = _question(
        1,
        "At what surprisingly young age does the brain reportedly begin "
        "slowing down?",
        "24",
        source_url=url,
    )
    smell_fact = _question(
        2,
        "Which sense is most strongly tied to triggering vivid early "
        "childhood memories?",
        "Smell",
        source_url=url,
    )
    ctx = _ctx([age_fact, smell_fact])

    result = await _stage().run(ctx, _NullSink())

    assert [q.id for q in ctx.questions] == ["q_1", "q_2"]
    assert result.info["fact_dropped"] == 0


@pytest.mark.asyncio
async def test_keeps_distinct_questions_without_source_url():
    a = _question(1, "Which planet spins in the opposite direction?", "Venus")
    b = _question(2, "Which metal stays liquid at room temperature?", "Mercury")
    ctx = _ctx([a, b])

    result = await _stage().run(ctx, _NullSink())

    assert [q.id for q in ctx.questions] == ["q_1", "q_2"]
    assert result.info["fact_dropped"] == 0
