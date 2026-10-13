"""Casual-player check (#201, founder 2026-10-13).

The blind answerability round trip (``answerability.py``) proxies a *strong*
player and cannot know anything after its training cutoff, so for fresh
entertainment it lets stem giveaways through and says nothing about whether an
ordinary person had a chance. This checker asks the opposite question: given
the answer and the verifier's evidence, what share of casual adults in the
player's country would get it, and does the stem itself hand the answer over?

It runs inside ``ScoringStage`` (after verification, so direct-mode questions
already carry the verifier's source). Fail-safe contract, same as every other
check: a dead call or unparseable verdict KEEPS the question.
"""

from __future__ import annotations

import json
import logging
from dataclasses import dataclass
from datetime import date

from quiz_shared.llm import factory as llm_factory
from quiz_shared.models.question import GenerationProvenance, Question

logger = logging.getLogger(__name__)

# Written into ``generation_metadata.extra``. Deliberately NOT one of the
# machine-approval review-flag keys: the verdict is measurement, not a block.
VERDICT_KEY = "casual_player"

_AUDIENCE = {
    "en": "an international audience of adults (anywhere in the world)",
    "sk": "adults living in Slovakia",
    "cs": "adults living in the Czech Republic",
}

_PROMPT = """You judge pub-quiz questions for a voice trivia game. Today is {today}. The players are {audience}: ordinary people who follow film, TV, music and celebrities only loosely (news headlines, social media, what friends talk about) — not fans or insiders.

QUESTION: {question}
{options_block}CORRECT ANSWER: {answer}
SOURCE: {source}

1. Estimate what percentage of these casual players would give the correct answer (by knowing it, half-remembering it, or reasoning, estimating or eliminating their way there). For multiple-choice, count only real knowledge or reasoning above blind luck.
2. Is it a giveaway? true ONLY when the wording itself names or uniquely describes the answer, so someone who never heard of the fact still gets it (e.g. "the actor who played Kylo Ren" when the answer is Adam Driver). Fair deduction from everyday knowledge is NOT a giveaway.

Respond in JSON only:
{{"casual_correct_pct": <integer 0-100>, "giveaway": <true|false>, "reason": "<one short sentence>"}}"""


@dataclass
class CasualVerdict:
    passed: bool
    pct: int | None = None
    giveaway: bool | None = None
    reason: str | None = None
    drop_reason: str | None = None


def _audience(language: str | None) -> str:
    return _AUDIENCE.get((language or "en").lower(), f"adults who speak '{language}'")


class CasualPlayerChecker:
    """One call per question; the drop decision is deterministic on the verdict."""

    def __init__(self, model: str | None = None, today: date | None = None):
        self._model = model or llm_factory.CASUAL_PLAYER
        self._today = today
        self._client = None

    async def _complete(self, prompt: str) -> str | None:
        """Single LLM boundary: raw model text, or ``None`` on any failure."""
        try:
            if self._client is None:
                self._client = llm_factory.chat_model(self._model)
            response = await self._client.ainvoke(prompt)
            return llm_factory.message_text(response)
        except Exception:
            logger.warning("CasualPlayerChecker call failed", exc_info=True)
            return None

    @staticmethod
    def _parse(raw: str) -> dict | None:
        start, end = raw.find("{"), raw.rfind("}") + 1
        if start == -1 or end <= start:
            return None
        try:
            data = json.loads(raw[start:end])
        except json.JSONDecodeError:
            return None
        return data if isinstance(data, dict) else None

    async def check(self, question: Question, floor: int) -> CasualVerdict:
        options_block = ""
        if question.possible_answers:
            rendered = " | ".join(
                f"{str(k).lower()}) {v}" for k, v in question.possible_answers.items()
            )
            options_block = f"OPTIONS: {rendered}\n"
        source = question.source_excerpt or question.source_url or "(none)"
        prompt = _PROMPT.format(
            today=(self._today or date.today()).isoformat(),
            audience=_audience(question.language),
            question=question.question,
            options_block=options_block,
            answer=question.correct_answer,
            source=source,
        )
        raw = await self._complete(prompt)
        data = self._parse(raw) if raw is not None else None
        if data is None:
            return CasualVerdict(passed=True, reason="check_unavailable")
        try:
            pct = max(0, min(100, int(data.get("casual_correct_pct"))))
        except (TypeError, ValueError):
            return CasualVerdict(passed=True, reason="check_unavailable")
        giveaway = data.get("giveaway") is True
        reason = str(data.get("reason") or "")[:200] or None
        drop_reason = "giveaway" if giveaway else (
            f"casual_below_{floor}" if pct < floor else None
        )
        return CasualVerdict(
            passed=drop_reason is None,
            pct=pct,
            giveaway=giveaway,
            reason=reason,
            drop_reason=drop_reason,
        )


def stamp_verdict(q: Question, verdict: CasualVerdict, mode: str) -> None:
    """Record the verdict on the row (measurement for #201 201.4 + mix tuning)."""
    provenance = q.generation_metadata or GenerationProvenance()
    extra = dict(provenance.extra)
    extra[VERDICT_KEY] = {
        "mode": mode,
        "pct": verdict.pct,
        "giveaway": verdict.giveaway,
        "would_drop": verdict.drop_reason,
        "reason": verdict.reason,
        # A verdict without an evidence excerpt judged a post-cutoff event
        # from the question alone — not grounded (design review 2026-10-13).
        "excerpt_missing": not q.source_excerpt,
    }
    q.generation_metadata = provenance.model_copy(update={"extra": extra})
