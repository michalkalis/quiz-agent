"""Issue #76 F-3b task 2 — post-generation expiry classification.

A question-type-agnostic classifier that reads each generated question + its
correct answer and assigns a ``content_class`` — one of ``evergreen`` /
``semi-stable`` / ``current`` — plus a one-line rationale (the founder reviews
"why 14 days" per question from the run logs). A deterministic
``content_class → TTL`` map (``CONTENT_CLASS_TTL``) then decides how long the
question stays fresh; ``GenerationStage`` stamps ``expires_at`` / ``freshness_tag``
from that map (task 3).

Design (locked founder decisions):
- ONE batched LLM call per generation run on the cheapest judgment tier already
  in this codebase (``gpt-4o-mini`` — the factory's EVAL/CRITIQUE/PARSE default),
  made through ``quiz_shared.llm.factory`` (never an SDK client / API key here).
- Reads question text + correct answer only — no question-type-specific logic, so
  future image/kids/themed questions reuse it unchanged.
- Fail-safe, fail-loud: any LLM error, malformed response, or count mismatch logs
  a warning and leaves the affected questions unclassified (expiry unset). This
  classifier NEVER raises into the generation pipeline.
"""

from __future__ import annotations

import json
import logging
import os
from dataclasses import dataclass
from datetime import timedelta
from typing import Optional, Sequence

from quiz_shared.llm import factory as llm_factory
from quiz_shared.models.question import Question

logger = logging.getLogger(__name__)

# The one config spot: content_class → time-to-live. ``None`` means no expiry
# (evergreen never goes stale). Provisional values per the F-3b plan — change
# them here and both the stamping loop and its tests follow automatically.
CONTENT_CLASS_TTL: dict[str, Optional[timedelta]] = {
    "current": timedelta(days=14),
    "semi-stable": timedelta(days=365),
    "evergreen": None,
}

# Cheapest judgment tier already used in this codebase (factory EVAL/CRITIQUE/
# PARSE default). Resolved through the factory so the OpenRouter remap applies
# under ``LLM_GATEWAY=openrouter``; direct mode leaves it unchanged.
_CLASSIFIER_MODEL = "gpt-4o-mini"

_PROMPT_HEADER = """You classify trivia questions by how quickly their correct \
answer goes out of date. You read only the question and its correct answer.

Assign exactly one content_class to each:
- "current": the answer depends on the present moment and can change within
  weeks or a few months — e.g. "who currently holds X", "this year's winner",
  a living person's current age, anything tied to a recent/ongoing event.
- "semi-stable": the answer is settled for now but could plausibly change within
  about a year — e.g. a standing record holder, an incumbent that rarely changes.
- "evergreen": the answer is historically fixed and will never change — past
  events, dated facts ("won Best Picture in 1994"), science, definitions.

Also give a one-line rationale for each (why that class).

Respond with JSON only, no prose:
{"classifications": [{"index": <1-based int>, "content_class": "current|semi-stable|evergreen", "rationale": "<one line>"}]}

Questions:
"""


@dataclass
class Classification:
    """A question's content class plus the one-line rationale for it."""

    content_class: str  # always a key of CONTENT_CLASS_TTL
    rationale: str


def _answer_text(answer: object) -> str:
    """Flatten a correct_answer (str or list) to a single line for the prompt."""
    if isinstance(answer, list):
        return ", ".join(str(a) for a in answer)
    return str(answer)


class ExpiryClassifier:
    """Batched LLM judge assigning a temporal ``content_class`` per question.

    Mirrors ``AnswerNormalizer``'s lazy OpenAI-SDK client (issue #53 factory):
    with no API key the model never inits and ``classify`` returns all-``None``
    (fail-safe → expiry unset). ``classify`` never raises.
    """

    def __init__(self, api_key: Optional[str] = None) -> None:
        self.api_key = api_key or os.getenv("OPENAI_API_KEY")
        self._client = None

    def _available(self) -> bool:
        """Whether the LLM is reachable under the active gateway."""
        if llm_factory.gateway() == llm_factory.OPENROUTER:
            return bool(os.getenv("OPENROUTER_API_KEY"))
        return bool(self.api_key)

    async def _complete(self, prompt: str) -> Optional[str]:
        """Single LLM boundary: raw model text, or ``None`` on any failure."""
        if self._client is None:
            self._client = llm_factory.openai_client(async_=True)
        try:
            response = await self._client.chat.completions.create(
                model=llm_factory.resolve_model(_CLASSIFIER_MODEL),
                messages=[{"role": "user", "content": prompt}],
            )
            return response.choices[0].message.content
        except Exception:
            return None

    def _build_prompt(self, questions: Sequence[Question]) -> str:
        lines = [_PROMPT_HEADER]
        for i, q in enumerate(questions, start=1):
            lines.append(f"{i}. Q: {q.question}\n   A: {_answer_text(q.correct_answer)}")
        return "\n".join(lines)

    def _parse(
        self, text: str, questions: Sequence[Question]
    ) -> list[Optional[Classification]]:
        """Parse the batched JSON into a list aligned to ``questions``.

        Returns a ``None`` for every question the model didn't classify (or
        classified with an unknown class / out-of-range index). A count
        mismatch is a warning, never a failure — the affected questions simply
        stay unclassified.
        """
        n = len(questions)
        result: list[Optional[Classification]] = [None] * n

        cleaned = text.strip()
        if cleaned.startswith("```"):
            cleaned = cleaned.split("\n", 1)[1].rsplit("```", 1)[0].strip()
        start = cleaned.find("{")
        end = cleaned.rfind("}") + 1
        if start == -1 or end <= start:
            logger.warning(
                "ExpiryClassifier: no JSON object in response; %d questions "
                "left unclassified",
                n,
            )
            return result
        data = json.loads(cleaned[start:end])

        items = data.get("classifications") if isinstance(data, dict) else None
        if not isinstance(items, list):
            logger.warning(
                "ExpiryClassifier: response missing 'classifications' list; %d "
                "questions left unclassified",
                n,
            )
            return result

        matched = 0
        for item in items:
            if not isinstance(item, dict):
                continue
            try:
                idx = int(item.get("index"))
            except (TypeError, ValueError):
                continue
            content_class = item.get("content_class")
            if not (1 <= idx <= n) or content_class not in CONTENT_CLASS_TTL:
                continue
            rationale = str(item.get("rationale") or "").strip()
            result[idx - 1] = Classification(
                content_class=content_class, rationale=rationale
            )
            matched += 1

        if matched != n:
            logger.warning(
                "ExpiryClassifier: classified %d/%d questions (count mismatch); "
                "the rest stay unclassified",
                matched,
                n,
            )
        return result

    async def classify(
        self, questions: Sequence[Question]
    ) -> list[Optional[Classification]]:
        """Classify every question in one batched call.

        Returns a list aligned to ``questions``; ``None`` for any question that
        couldn't be classified. NEVER raises — every failure mode fails safe to
        all-``None`` with a logged warning so the generation pipeline is never
        blocked.
        """
        n = len(questions)
        if n == 0:
            return []
        try:
            if not self._available():
                logger.warning(
                    "ExpiryClassifier unavailable (no API key for active "
                    "gateway); leaving %d questions unclassified",
                    n,
                )
                return [None] * n
            text = await self._complete(self._build_prompt(questions))
            if text is None:
                logger.warning(
                    "ExpiryClassifier: LLM returned no content; leaving %d "
                    "questions unclassified",
                    n,
                )
                return [None] * n
            result = self._parse(text, questions)
        except Exception as exc:  # bulletproof: never propagate into the pipeline
            logger.warning(
                "ExpiryClassifier failed (%r); leaving %d questions unclassified",
                exc,
                n,
            )
            return [None] * n

        # INFO log per classified question so a founder can review a run
        # ("why 14 days?") straight from the logs.
        for q, c in zip(questions, result):
            if c is not None:
                logger.info(
                    "ExpiryClassifier class=%s ttl=%s rationale=%s | %.80s",
                    c.content_class,
                    CONTENT_CLASS_TTL[c.content_class],
                    c.rationale,
                    q.question,
                )
        return result
