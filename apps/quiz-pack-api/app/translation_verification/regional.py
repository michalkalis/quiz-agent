"""Regional-relevance flag — a single-attribute classifier, flag-only.

Issue #168 — batch translation pipeline SK/CS, task T8 (DD12, locked
decision 3(d)).

Shape adopted from ``app/verification/shape_classifier.py:45``: one
answer-blind-ish classification call, one attribute, a strict JSON reply.

What is deliberately NOT adopted is that classifier's fail-closed routing.
This flag **never blocks and never drops a row** (locked decision 3(d)): a
question about a US state capital is perfectly correct Slovak and a perfectly
valid quiz question — it is just less interesting to a Slovak player, which is
a curation signal for the human review loop, not a defect. The structural
guarantee is that ``judge.approval_status()`` takes no regional argument at
all, so there is no code path by which this result can reject anything; the
flag and its reason ride ``question_translations.verification`` and surface on
the rating web.

A failed or unparseable call therefore returns "not flagged" with the reason
recorded — the fail-*safe* direction. Holding a row because a curation hint
was unavailable would be exactly the auto-drop 3(d) forbids.
"""

from __future__ import annotations

import json
import logging
from dataclasses import dataclass
from typing import Any

from quiz_shared.llm import factory as llm_factory

from app import feature_flags

logger = logging.getLogger(__name__)

_LANGUAGE_NAMES = {"sk": "Slovak", "cs": "Czech"}

_PROMPT = """Decide one thing about the quiz question below, for an audience of {language_name} players.

Flag it only if answering it depends on knowledge that is specific to another country or region and is not part of general knowledge in {language_name}-speaking countries — for example a domestic sports league, a local TV show, a national holiday, a state/province, or a school-curriculum fact taught only elsewhere.

Do NOT flag world knowledge, science, history, geography, or globally distributed culture (international films, music, sport, brands), even when it is foreign in origin. Do NOT flag a question for being difficult, and do NOT judge the translation.

QUESTION: {question}
{options_block}
Respond in JSON only:
{{"regionally_specific": true | false, "reason": "one short sentence naming the region and the assumed knowledge, or why it is general"}}"""


@dataclass
class RegionalRelevance:
    """``(flag, reason)`` — never a verdict, never a block."""

    flag: bool
    reason: str

    def as_verification_json(self) -> dict[str, Any]:
        """The ``question_translations.verification`` fragment for this stage."""
        return {"regional": {"flag": self.flag, "reason": self.reason}}


class RegionalClassifier:
    """One regional-relevance call per translated question."""

    def __init__(self, model: str | None = None):
        self._model = (
            model or feature_flags.answerability_model() or llm_factory.ANSWERABILITY
        )
        self._client = None

    async def classify(
        self,
        question_text: str,
        language: str,
        possible_answers: dict | None = None,
    ) -> RegionalRelevance:
        """Return the flag and its reason. Never raises, never blocks."""
        options_block = ""
        if possible_answers:
            rendered = " | ".join(
                f"{str(k).lower()}) {v}" for k, v in possible_answers.items()
            )
            options_block = f"OPTIONS: {rendered}\n"
        prompt = _PROMPT.format(
            language_name=_LANGUAGE_NAMES.get(language, language),
            question=question_text,
            options_block=options_block,
        )
        try:
            if self._client is None:
                self._client = llm_factory.chat_model(self._model)
            response = await self._client.ainvoke(prompt)
            raw = llm_factory.message_text(response)
        # Broad on purpose: a curation hint must never fail a row.
        except Exception:
            logger.warning("Regional classification call failed", exc_info=True)
            return RegionalRelevance(False, "classification unavailable")
        parsed = _parse(raw)
        if parsed is None:
            logger.warning("Regional classifier reply unparseable: %.120r", raw)
            return RegionalRelevance(False, "classification unparseable")
        return parsed


def _parse(raw: str | None) -> RegionalRelevance | None:
    if not raw:
        return None
    cleaned = raw.strip()
    if cleaned.startswith("```"):
        cleaned = cleaned.split("\n", 1)[-1].rsplit("```", 1)[0].strip()
    start, end = cleaned.find("{"), cleaned.rfind("}") + 1
    if start == -1 or end <= start:
        return None
    try:
        data = json.loads(cleaned[start:end])
    except json.JSONDecodeError:
        return None
    if not isinstance(data, dict) or "regionally_specific" not in data:
        return None
    return RegionalRelevance(
        flag=bool(data.get("regionally_specific")),
        reason=str(data.get("reason") or ""),
    )
