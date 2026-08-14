"""Answer-blind question-shape classifier (#160, gen-review part-4 verdict).

The pipeline used to route a question to the logical-consistency judge — and
past web fact-checking — purely on the generator's self-reported
``pattern_used`` label. That is model-controlled routing (P4): a generator
labelling a factual claim ``lateral_thinking`` skipped the only truth gate.

This classifier is the independent second opinion: it sees ONLY the question
text (and options) — never the correct answer, never the generator's label —
and decides whether the question is a self-contained logic/lateral puzzle
(no external source could confirm the answer) or a real-world factual claim
that web verification can and must check.

Fail-closed contract (opposite of AnswerabilityChecker's fail-safe): any
call/parse failure returns ``None`` and the caller must route the question to
the STRICTER path (factual web verification). Runs on the answerability model
role (mid-class, D26) — a classification call, not generation.
"""

from __future__ import annotations

import json
import logging
from typing import Literal, Optional

from quiz_shared.llm import factory as llm_factory

from app import feature_flags

logger = logging.getLogger(__name__)

_PROMPT = """Classify the quiz question below by what could prove its answer right.

- "logical": a self-contained logic or lateral-thinking puzzle. The answer is an explanation that follows from the scenario itself; no encyclopedia, news article, or database could confirm it. Example: "A man pushes his car to a hotel and loses his fortune. What happened?"
- "factual": everything else — the answer asserts something about the real world (a fact, number, name, date, mechanism, cause) that an external source could confirm or refute. Example: "Why are Ferraris traditionally red?"

If in doubt, answer "factual".

QUESTION: {question}
{options_block}
Respond in JSON only:
{{"shape": "logical" | "factual"}}"""


class ShapeClassifier:
    """One answer-blind classification call per audited question."""

    def __init__(self, model: Optional[str] = None):
        self._model = (
            model
            or feature_flags.answerability_model()
            or llm_factory.ANSWERABILITY
        )
        self._client = None

    async def classify(
        self, question_text: str, possible_answers: Optional[dict] = None
    ) -> Optional[Literal["logical", "factual"]]:
        """Return the shape verdict, or ``None`` when the call failed.

        ``None`` is NOT "logical" — callers route it to factual verification
        (fail-closed, P4).
        """
        options_block = ""
        if possible_answers:
            rendered = " | ".join(
                f"{str(k).lower()}) {v}" for k, v in possible_answers.items()
            )
            options_block = f"OPTIONS: {rendered}\n"
        try:
            if self._client is None:
                self._client = llm_factory.chat_model(self._model)
            response = await self._client.ainvoke(
                _PROMPT.format(
                    question=question_text, options_block=options_block
                )
            )
            raw = llm_factory.message_text(response)
        except Exception:  # noqa: BLE001 — call boundary; caller fails closed
            logger.warning("Shape classification call failed", exc_info=True)
            return None
        verdict = self._parse(raw)
        if verdict is None:
            logger.warning(
                "Shape classification returned unparseable verdict: %.120r", raw
            )
        return verdict

    @staticmethod
    def _parse(raw: Optional[str]) -> Optional[Literal["logical", "factual"]]:
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
        shape = str(data.get("shape") or "").strip().lower()
        if shape in ("logical", "factual"):
            return shape  # type: ignore[return-value]
        return None
