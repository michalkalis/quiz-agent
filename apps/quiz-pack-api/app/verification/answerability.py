"""Round-trip answerability check (#135 D10 / O3, founder-approved 2026-08-03).

A cheap model attempts each question WITHOUT seeing the answer. A question it
cannot reach — or flags as unclear/ambiguous — is dropped EARLY, right after
dedup, before the paid verification/scoring stages. The checker proxies a
smart player, which is why a flash-class model is the point, not a compromise
(factory ``ANSWERABILITY`` role; founder carve-out from the frontier-only
policy). It catches the failure modes the founder keeps seeing: unclear
phrasing, ambiguous stems, dead-end unguessables, and MCQs where a second
option is defensibly correct (the blind model picks it → mismatch → drop).

Fail-safe contract: a checker/API/parse failure KEEPS the question (absence
of a judgment is not a failed judgment — same rule as the scoring gate).
Open-shape questions (sentence answers) are only dropped on the model's own
gave-up/unclear signal — fuzzy-matching a sentence answer would be noise.
"""

from __future__ import annotations

import json
import logging
import re
from dataclasses import dataclass
from typing import Optional

from quiz_shared.llm import factory as llm_factory
from quiz_shared.models.question import Question

from app import feature_flags
from app.generation.pattern_routing import answer_shape

logger = logging.getLogger(__name__)

_ARTICLES = ("the ", "a ", "an ")

_PROMPT = """You are a strong quiz player. Answer the question below. You cannot look anything up — use reasoning, estimation, elimination and general knowledge. Commit to your single best answer.

QUESTION: {question}
{options_block}
Respond in JSON only:
{{"answer": "<your best answer — for multiple-choice, the option letter>", "gave_up": <true ONLY if you cannot commit to any answer at all>, "issue": <null, or "ambiguous" when the wording allows multiple valid readings or more than one option is defensibly correct, or "unclear" when you cannot tell what is being asked>}}"""


@dataclass
class AnswerabilityResult:
    passed: bool
    reason: Optional[str] = None
    model_answer: Optional[str] = None


def _normalize(text: str) -> str:
    text = re.sub(r"[^a-z0-9 ]+", " ", text.lower()).strip()
    for article in _ARTICLES:
        if text.startswith(article):
            text = text[len(article):]
    return re.sub(r"\s+", " ", text)


def _token_overlap(a: str, b: str) -> float:
    ta = {t for t in a.split() if len(t) >= 3}
    tb = {t for t in b.split() if len(t) >= 3}
    if not ta or not tb:
        return 0.0
    return len(ta & tb) / len(ta | tb)


def _text_answers_match(model_answer: str, references: list[str]) -> bool:
    """Lenient normalized comparison against the reference answers."""
    norm_model = _normalize(model_answer)
    if not norm_model:
        return False
    for ref in references:
        norm_ref = _normalize(str(ref))
        if not norm_ref:
            continue
        if norm_model == norm_ref:
            return True
        if norm_ref in norm_model or norm_model in norm_ref:
            return True
        if _token_overlap(norm_model, norm_ref) >= 0.6:
            return True
    return False


def _mcq_answers_match(
    model_answer: str, possible_answers: dict, correct_answer: object
) -> bool:
    """Resolve the model's letter-or-text pick and compare option identity."""
    wanted = _normalize(str(correct_answer))
    picked = str(model_answer).strip().lower()
    for key, value in possible_answers.items():
        key_norm = str(key).strip().lower()
        value_norm = _normalize(str(value))
        if picked == key_norm or _normalize(picked) == value_norm:
            return value_norm == wanted or key_norm == wanted
    # The model answered outside the options — try a direct text match
    # (e.g. "True" for a true/false framed reply with punctuation).
    return _text_answers_match(model_answer, [str(correct_answer)])


class AnswerabilityChecker:
    """One cheap blind-attempt call per question; deterministic comparison."""

    def __init__(self, model: Optional[str] = None):
        self._model = (
            model
            or feature_flags.answerability_model()
            or llm_factory.ANSWERABILITY
        )
        self._client = None

    async def _complete(self, prompt: str) -> Optional[str]:
        """Single LLM boundary: raw model text, or ``None`` on any failure."""
        try:
            if self._client is None:
                # chat_model routes bedrock: ids to Bedrock; the OpenAI path
                # defaults to the generation timeout.
                self._client = llm_factory.chat_model(self._model)
            response = await self._client.ainvoke(prompt)
            return llm_factory.message_text(response)
        except Exception:  # noqa: BLE001 — checker call boundary (fail-safe)
            return None

    @staticmethod
    def _parse(raw: str) -> Optional[dict]:
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
        return data if isinstance(data, dict) else None

    async def check(self, question: Question) -> AnswerabilityResult:
        options_block = ""
        if question.possible_answers:
            rendered = " | ".join(
                f"{str(k).lower()}) {v}"
                for k, v in question.possible_answers.items()
            )
            options_block = f"OPTIONS: {rendered}\n"

        raw = await self._complete(
            _PROMPT.format(question=question.question, options_block=options_block)
        )
        data = self._parse(raw) if raw is not None else None
        if data is None or "answer" not in data:
            # No verdict at all (dead call, non-JSON, or JSON of a different
            # shape — e.g. a hermetic-test mock): keep. Only an explicit
            # ``gave_up`` below is a considered surrender.
            return AnswerabilityResult(passed=True, reason="check_unavailable")

        model_answer = str(data.get("answer") or "").strip()
        issue = data.get("issue")
        if data.get("gave_up") is True:
            return AnswerabilityResult(
                passed=False, reason="unanswerable", model_answer=model_answer or None
            )
        if not model_answer:
            return AnswerabilityResult(passed=True, reason="check_unavailable")
        if isinstance(issue, str) and issue.strip().lower() in ("ambiguous", "unclear"):
            return AnswerabilityResult(
                passed=False,
                reason=f"flagged_{issue.strip().lower()}",
                model_answer=model_answer,
            )

        pattern = (
            question.generation_metadata.reasoning_pattern
            if question.generation_metadata is not None
            else None
        )
        if answer_shape(pattern, question.question) == "open":
            # Sentence answers can't be fuzzy-matched meaningfully; the
            # gave-up/issue signals above are the whole check for open shapes.
            return AnswerabilityResult(passed=True, model_answer=model_answer)

        if question.possible_answers:
            matched = _mcq_answers_match(
                model_answer, question.possible_answers, question.correct_answer
            )
        else:
            references = [str(question.correct_answer)]
            references.extend(str(a) for a in (question.alternative_answers or []))
            matched = _text_answers_match(model_answer, references)

        if matched:
            return AnswerabilityResult(passed=True, model_answer=model_answer)
        return AnswerabilityResult(
            passed=False, reason="wrong_answer", model_answer=model_answer
        )
