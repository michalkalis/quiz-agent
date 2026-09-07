"""GrayZoneJudge — pairwise "same fact?" verdict for the dedup gray zone (#170 D7).

The question-only cosine branch has a band no threshold can split: the
2026-08-07 batch's true dup sat at 0.735 while a non-dup pair sat at 0.738.
Instead of moving the threshold, a candidate whose nearest corpus match falls
in ``[GRAYZONE_LOW, <category cosine threshold>)`` is put to a cheap model
with ONE question: do these two ask for the same fact? "yes" drops the
candidate under its own reason; "no", a parse failure or an exhausted budget
all fall back to today's behaviour (below threshold ⇒ passes) — the last two
with a warning, never silently.

This is NOT a quality judge and deliberately does not hang off the
``_judges_enabled`` panel switch (#169 keeps that OFF in session runs); it is
allowed under the session gateway. Default OFF: ``DedupStage`` only calls it
when a ``GrayZoneJudge`` is injected (D5), which only corpus CLI runs do.

The LLM boundary is ``llm_factory.chat_openai`` — the same seam
``MultiModelScorer._get_client`` uses — so the call is remapped to the active
gateway and counted by ``app.llm_usage`` under the ``dedup`` stage.
"""

from __future__ import annotations

import logging
from typing import Any

from quiz_shared.llm import factory as llm_factory
from quiz_shared.models.question import Question

logger = logging.getLogger(__name__)

# Lower edge of the band. The upper edge is the candidate's own cosine
# threshold (0.85 global, or the category profile's value): anything at or
# above it is already a plain cosine drop and never reaches the judge.
GRAYZONE_LOW = 0.70
# Per-run budget (D7). A 30-question batch rarely has more than a handful of
# gray-zone pairs; 20 bounds a pathological corpus without starving a normal run.
DEFAULT_MAX_CALLS = 20

_PROMPT = """You are checking a trivia question bank for duplicated facts.

Two questions are a DUPLICATE when a player who knows the answer to one of them
necessarily knows the answer to the other — they test the same fact, even if
the wording, format or angle differs. They are NOT duplicates when they merely
share a topic, entity or theme but ask for different facts.

Question A: {question_a}
Answer A: {answer_a}

Question B: {question_b}
Answer B: {answer_b}

Do A and B test the same fact? Reply with exactly one word: YES or NO."""


def _answer_text(question: Question) -> str:
    answer: Any = question.correct_answer
    if isinstance(question.possible_answers, dict) and isinstance(answer, str):
        answer = question.possible_answers.get(answer, answer)
    return str(answer)


class GrayZoneJudge:
    """One pairwise call per gray-zone candidate, bounded by ``max_calls``."""

    def __init__(
        self,
        model: str | None = None,
        max_calls: int = DEFAULT_MAX_CALLS,
        client: Any = None,
    ) -> None:
        self.model = model or llm_factory.DEDUP_JUDGE
        self.max_calls = max_calls
        self.calls = 0
        self.skipped = 0
        self._client = client

    async def same_fact(
        self, candidate: Question, match: Question, score: float
    ) -> bool | None:
        """``True`` = same fact (drop), ``False`` = different, ``None`` = no
        verdict (budget exhausted or unparseable reply) — the caller applies
        today's below-threshold behaviour."""
        if self.calls >= self.max_calls:
            self.skipped += 1
            logger.warning(
                "GrayZoneJudge budget exhausted (%d/%d calls) — candidate id=%s "
                "vs corpus id=%s at cosine %.3f passes unjudged (%d skipped so far)",
                self.calls,
                self.max_calls,
                candidate.id,
                match.id,
                score,
                self.skipped,
            )
            return None
        self.calls += 1
        prompt = _PROMPT.format(
            question_a=candidate.question,
            answer_a=_answer_text(candidate),
            question_b=match.question,
            answer_b=_answer_text(match),
        )
        if self._client is None:
            self._client = llm_factory.chat_openai(self.model, temperature=0)
        response = await self._client.ainvoke(prompt)
        verdict = llm_factory.message_text(response).strip().upper()
        if verdict.startswith("YES"):
            return True
        if verdict.startswith("NO"):
            return False
        logger.warning(
            "GrayZoneJudge unparseable verdict %r for candidate id=%s vs corpus "
            "id=%s — candidate passes unjudged",
            verdict[:40],
            candidate.id,
            match.id,
        )
        return None
