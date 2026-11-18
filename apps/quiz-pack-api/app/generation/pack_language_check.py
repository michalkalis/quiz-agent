"""Language check of a customer pack, built on the #211 naturalness check.

A paid trial of Slovak child packs (2026-11) shipped one character's name
spelled two ways ("Hedwigu" / "Hedwiga", official Slovak "Hedviga") and a
wrong comma ("viac, či menej"). Customer packs are written straight in the
order's language and had no language check at all; the corpus importer runs
:class:`NaturalnessChecker` only on stems.

This reuses that check (same model, same editor prompt and problem kinds, same
LLM boundary) and appends a pack note, so the corpus prompt stays byte
identical. What the pack note adds:

- the answer, options and explanation of each question are shown and may be
  fixed too (all of it is read aloud, names appear in all of them);
- the questions already in the pack are shown as context, so a name keeps one
  spelling across the whole pack;
- two more kinds: ``name`` and ``punctuation``.

The caller (``LanguageFixStage``) decides which proposed edits are safe to
apply. Fail-safe like the parent: any failure returns ``None`` (the whole
call) or ``None`` per question; never raises.
"""

from __future__ import annotations

import json
import logging
from collections.abc import Sequence
from dataclasses import dataclass, field

from quiz_shared.llm import factory as llm_factory
from quiz_shared.models.question import Question

from app.generation.naturalness_check import (
    _PROMPT_HEADER,
    _UK_NOTE,
    LANGUAGES,
    PROBLEM_KINDS,
    NaturalnessChecker,
)

logger = logging.getLogger(__name__)

PACK_PROBLEM_KINDS = PROBLEM_KINDS + ("name", "punctuation")

#: Stamped on every recorded edit, next to the naturalness PROMPT_VERSION.
PACK_NOTE_VERSION = 1

_PACK_NOTE = """

This is one custom quiz pack, checked as a whole. Each question to check \
shows its answer (or its options) and its explanation: all of it is read \
aloud, so check all of it. Questions listed as already in the pack are \
context only: do not check them, but keep the new questions consistent with \
them.

Two more kinds in this check:
- "name": a name of a person, character, animal, place or work written \
differently across the pack, or not in the official form used in this \
language (sk: Harry Potter's owl is "Hedviga", not "Hedwiga" or "Hedwigu"). \
Use the official form in this language, the same one in every question.
- "punctuation": a missing or wrong comma or other punctuation mark (sk "viac \
či menej", not "viac, či menej").

Fix only wording, spelling, names and punctuation. Never change a fact or a \
number, and never what the answer means: an answer or option may change only \
in spelling or form, it must stay the same thing. Put fixed parts other than \
the question in "fields", only the parts that change, each with the smallest \
edit: {"answer": "<text>", "options": {"<key>": "<text>"}, "explanation": \
"<text>"}. "rewrite" is still the whole question; copy it unchanged when only \
other parts change."""


@dataclass
class PackCheck:
    """One question's verdict and the edits the model proposes, by field:
    ``question``, ``correct_answer``, ``explanation`` or ``option:<key>``."""

    ok: bool
    problems: list[dict] = field(default_factory=list)
    edits: dict[str, str] = field(default_factory=dict)


def applies_to(language: str | None) -> bool:
    """The check is a native sk/cs/uk editor; other packs are not checked."""
    return language in LANGUAGES


def _answer_line(q: Question) -> str:
    if q.possible_answers:
        options = " | ".join(f"{k}) {v}" for k, v in q.possible_answers.items())
        return f"Options: {options} (correct: {q.correct_answer})"
    return f"Answer: {q.correct_answer}"


def build_prompt(new: Sequence[Question], context: Sequence[Question]) -> str:
    prompt = _PROMPT_HEADER
    if any(q.language == "uk" for q in [*new, *context]):
        prompt += _UK_NOTE
    lines = [prompt + _PACK_NOTE, ""]
    if context:
        lines.append("Already in the pack (context only, not numbered, do not check):")
        for q in context:
            lines.append(f"- {q.question} | {_answer_line(q)}")
        lines.append("")
    lines.append("Check these:")
    for i, q in enumerate(new, start=1):
        lines.append(f"{i}. [{q.language}] {q.question}")
        lines.append(f"   {_answer_line(q)}")
        if q.explanation:
            lines.append(f"   Explanation: {q.explanation}")
    return "\n".join(lines)


def _edits(item: dict, q: Question) -> dict[str, str]:
    """The proposed texts, keyed by the field they replace. Parts the
    question does not have (an answer list, an unknown option key) are
    ignored rather than invented."""
    edits: dict[str, str] = {}
    rewrite = item.get("rewrite")
    if isinstance(rewrite, str) and rewrite.strip():
        edits["question"] = rewrite.strip()
    fields = item.get("fields")
    if not isinstance(fields, dict):
        return edits
    answer = fields.get("answer")
    if (
        isinstance(answer, str)
        and isinstance(q.correct_answer, str)
        and not q.possible_answers
    ):
        edits["correct_answer"] = answer.strip()
    explanation = fields.get("explanation")
    if isinstance(explanation, str) and q.explanation:
        edits["explanation"] = explanation.strip()
    options = fields.get("options")
    if isinstance(options, dict) and q.possible_answers:
        for key, text in options.items():
            if key in q.possible_answers and isinstance(text, str):
                edits[f"option:{key}"] = text.strip()
    return edits


def parse(text: str, new: Sequence[Question]) -> list[PackCheck | None]:
    """Aligned to ``new``; ``None`` for a question without a consistent verdict."""
    n = len(new)
    result: list[PackCheck | None] = [None] * n
    cleaned = text.strip()
    start, end = cleaned.find("{"), cleaned.rfind("}") + 1
    if start == -1 or end <= start:
        logger.warning("PackLanguageChecker: no JSON object in response")
        return result
    data = json.loads(cleaned[start:end])
    items = data.get("checks") if isinstance(data, dict) else None
    if not isinstance(items, list):
        logger.warning("PackLanguageChecker: response missing 'checks' list")
        return result
    for item in items:
        if not isinstance(item, dict):
            continue
        try:
            idx = int(item.get("index"))
        except (TypeError, ValueError):
            continue
        if not 1 <= idx <= n:
            continue
        ok = item.get("ok")
        problems = [
            {"kind": p["kind"], "quote": str(p.get("quote") or "").strip()}
            for p in item.get("problems") or []
            if isinstance(p, dict) and p.get("kind") in PACK_PROBLEM_KINDS
        ]
        if ok is True and not problems:
            result[idx - 1] = PackCheck(ok=True)
        elif ok is False and problems:
            edits = _edits(item, new[idx - 1])
            if edits:
                result[idx - 1] = PackCheck(ok=False, problems=problems, edits=edits)
    return result


class PackLanguageChecker(NaturalnessChecker):
    """The naturalness check run over one round of a customer pack."""

    async def check_pack(
        self, new: Sequence[Question], context: Sequence[Question]
    ) -> list[PackCheck | None] | None:
        """One call for the round. ``None`` when the call itself failed."""
        if not new:
            return []
        try:
            if not llm_factory.chat_available(self.model):
                logger.warning(
                    "PackLanguageChecker unavailable (no key for %s)", self.model
                )
                return None
            text = await self._complete(build_prompt(new, context))
            if text is None:
                return None
            return parse(text, new)
        except Exception as exc:  # noqa: BLE001 — a polish step, never propagate
            logger.warning("PackLanguageChecker failed (%r)", exc)
            return None
