"""Issue #46 task 46.A2b — LLM normalization fallback for the ambiguous
comma-tailed remainder of 46.A2's deterministic splitter.

The deterministic pass (`GenerationStage._split_answer_head`) only fires on
unambiguous tail markers (em/en-dash, "because", "while", …) and never on a
bare comma, because a comma is structural in legitimate short answers
("Tokyo, Japan", "December 7, 1941", "salt, pepper, flour"). That leaves
over-cap, comma-tailed answers — e.g. the Sahara audit example,
"A lush green landscape with flowing rivers, lakes and abundant grazing
wildlife" — with no recoverable head, so they currently drop.

This module asks an LLM the single judgment call (CLAUDE.md rule #5): "what is
the canonical short answer here, and what context belongs in the explanation —
or is this one indivisible answer?" The LLM may *canonicalize*, not just split
(the Sahara sentence has no substring head; "Grassland/savanna" is a paraphrase).

Fail-safe by construction: any unavailability, parse failure, low confidence,
an over-cap head, or an "indivisible" verdict returns ``None`` so the caller
drops the question rather than normalizing it to a guess. Nothing is invented.
"""

from __future__ import annotations

import json
import os
from dataclasses import dataclass
from typing import Optional

from quiz_shared.llm import factory as llm_factory

from app.scoring.multi_model_scorer import _ANSWER_WORD_CAP

_PROMPT = """You normalize trivia answers for a voice quiz read aloud while driving.
The canonical answer must be a short, gettable gist (<= {cap} words); any extra
context belongs in a separate explanation read afterwards.

QUESTION: {question}
CURRENT ANSWER: {answer}

Decide: does this answer contain one short canonical answer plus extra context,
or is it a single indivisible answer that cannot be shortened without losing
meaning?

Respond in JSON only:
{{
  "divisible": true | false,
  "head": "the canonical short answer (<= {cap} words), or null if indivisible",
  "explanation": "the remaining context, or null",
  "confidence": 0.0-1.0
}}

Rules:
- "Tokyo, Japan" / "December 7, 1941" are single indivisible answers → divisible=false.
- "A lush green landscape with rivers and lakes" (Sahara 6000y ago) has a short
  canonical answer "Grassland/savanna" → divisible=true, head="Grassland/savanna".
- The head may paraphrase; it need not be a substring of the current answer.
- Be conservative — when unsure, return divisible=false."""


@dataclass
class NormalizedAnswer:
    """A recovered canonical head plus the context split off into explanation."""

    head: str
    explanation: str


class AnswerNormalizer:
    """LLM judge that recovers a canonical short answer from a verbose one.

    Mirrors `FactVerifier`'s lazy Gemini-Flash client so the dependency stays
    optional: with no API key the model never inits and `normalize` returns
    ``None`` (fail-safe to drop).
    """

    def __init__(
        self,
        gemini_api_key: Optional[str] = None,
        *,
        min_confidence: float = 0.6,
    ) -> None:
        self.gemini_api_key = gemini_api_key or os.getenv("GOOGLE_API_KEY")
        self._min_confidence = min_confidence
        self._client = None

    def _available(self) -> bool:
        """Whether the LLM judge is reachable (see FactVerifier._available)."""
        return bool(self.gemini_api_key) or llm_factory.gateway() == llm_factory.OPENROUTER

    async def _complete(self, prompt: str) -> Optional[str]:
        """Single LLM boundary: raw model text, or ``None`` on any failure."""
        if self._client is None:
            self._client = llm_factory.openai_client(async_=True)
        try:
            response = await self._client.chat.completions.create(
                model=llm_factory.resolve_model("gemini-2.5-flash"),
                messages=[{"role": "user", "content": prompt}],
            )
            return response.choices[0].message.content
        except Exception:
            return None

    async def normalize(
        self, question: str, answer: str
    ) -> Optional[NormalizedAnswer]:
        """Return the canonical head + explanation, or ``None`` to drop.

        ``None`` whenever the model is unavailable, the response can't be
        parsed, the model judges the answer indivisible, the head is empty or
        still over the word cap, or confidence is below `min_confidence`.
        """
        if not self._available():
            return None

        prompt = _PROMPT.format(
            question=question, answer=answer, cap=_ANSWER_WORD_CAP
        )
        try:
            text = await self._complete(prompt)
            if text is None:
                return None
            text = text.strip()
            if text.startswith("```"):
                text = text.split("\n", 1)[1].rsplit("```", 1)[0].strip()
            start = text.find("{")
            end = text.rfind("}") + 1
            if start == -1 or end <= start:
                return None
            data = json.loads(text[start:end])
        except Exception:
            return None

        if not data.get("divisible"):
            return None
        head = (data.get("head") or "").strip()
        if not head or len(head.split()) > _ANSWER_WORD_CAP:
            return None
        try:
            confidence = float(data.get("confidence", 0.0))
        except (TypeError, ValueError):
            return None
        if confidence < self._min_confidence:
            return None
        explanation = (data.get("explanation") or "").strip()
        return NormalizedAnswer(head=head, explanation=explanation)
