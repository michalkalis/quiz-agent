"""LanguageFixStage — fixes the language of a customer pack round before it is saved.

Runs inside the incremental TopUpStage walk on each round's accepted tail,
right before ``persist_batch``: after the fact-check (so only questions that
survived every gate pay for it) and before the questions are saved and can be
played (saved questions never change). Already saved questions are shown to
the model as context only, so a name keeps one spelling across the pack.

The model proposes; this stage decides deterministically what is safe:
an edit is rejected, and the original kept, when it changes a number, adds
letters from another script, empties a field, or turns an answer or option
into a different word (``_same_answer``). A child-band question must still
pass the band's word and number caps after all its edits, or none of them
are kept. Every proposed edit is recorded on the question, applied or not
(``app.generation.text_edits``), and the round's counts go to the caller,
which adds them to the round's ``step_log`` entry.

Fail open: an error or timeout leaves the round exactly as it was and is
counted (``failed``). This is a polish step, not a safety gate.

Behind ``PACK_LANGUAGE_FIX`` (``app.feature_flags.pack_language_fix``).
"""

from __future__ import annotations

import asyncio
import difflib
import logging
import re
import unicodedata
from collections import Counter

from quiz_shared.models.question import Question

from app import audience as order_audience
from app import kids_check, uk_policy
from app.generation import text_edits
from app.generation.naturalness_check import PROMPT_VERSION, _foreign_letters
from app.generation.pack_language_check import (
    PACK_NOTE_VERSION,
    PackCheck,
    PackLanguageChecker,
    applies_to,
)
from app.orchestrator.context import OrderContext, StageResult
from app.orchestrator.progress_sink import ProgressSink

logger = logging.getLogger(__name__)

STEP = "language_fix"
TIMEOUT_SECONDS = 120.0
# Folded answers this alike are one word spelled or inflected differently
# ("Hedwiga" / "Hedviga" 0.86, "Ryba" / "Rybu" 0.75); a different word falls
# below ("Pes" / "Les" 0.67, "Mačka" / "Myška" 0.6).
ANSWER_SIMILARITY = 0.75
# Same pattern as app.kids_check: "4 000", "4,000", "4.000" or a digit run.
_NUMBER = re.compile(r"\d{1,3}(?:[  .,]\d{3})+(?!\d)|\d+")


def _fold(text: str) -> str:
    decomposed = unicodedata.normalize("NFKD", text.casefold())
    return "".join(ch for ch in decomposed if not unicodedata.combining(ch)).strip()


def _same_answer(before: str, after: str) -> bool:
    return (
        difflib.SequenceMatcher(None, _fold(before), _fold(after)).ratio()
        >= ANSWER_SIMILARITY
    )


def _numbers(text: str) -> Counter:
    return Counter(re.sub(r"\D", "", m) for m in _NUMBER.findall(text))


def _adds_foreign(before: str, after: str, language: str | None) -> bool:
    if language == "uk":
        return bool(
            uk_policy.russian_contamination_reason([after])
            and not uk_policy.russian_contamination_reason([before])
        )
    return bool(_foreign_letters(after) - _foreign_letters(before))


def _rejection(field: str, before: str, after: str, language: str | None) -> str | None:
    if not after.strip():
        return "empty"
    if _numbers(before) != _numbers(after):
        return "numbers_changed"
    if _adds_foreign(before, after, language):
        return "foreign_letters"
    is_answer = field == "correct_answer" or field.startswith("option:")
    if is_answer and not _same_answer(before, after):
        return "answer_meaning"
    return None


def _get(q: Question, field: str) -> str:
    if field.startswith("option:"):
        return q.possible_answers[field.split(":", 1)[1]]
    return getattr(q, field)


def _set(q: Question, field: str, value: str) -> None:
    if field.startswith("option:"):
        q.possible_answers = {**q.possible_answers, field.split(":", 1)[1]: value}
    else:
        setattr(q, field, value)


def _kinds(problems: list[dict], before: str) -> list[str]:
    """The problem kinds whose quote sits in this field; all of them when the
    model's quotes point nowhere in it."""
    matched = [p["kind"] for p in problems if p["quote"] and p["quote"] in before]
    return sorted(set(matched or [p["kind"] for p in problems]))


class LanguageFixStage:
    """Applies safe language fixes to ``ctx.questions[ctx.locked_count:]``."""

    name = STEP

    def __init__(self, checker: PackLanguageChecker | None = None) -> None:
        self._checker = checker or PackLanguageChecker()

    async def run(self, ctx: OrderContext, sink: ProgressSink) -> StageResult:
        new = ctx.questions[ctx.locked_count :]
        if not new or not applies_to(ctx.language):
            return StageResult()
        context = ctx.questions[: ctx.locked_count]
        counts: Counter = Counter()
        try:
            verdicts = await asyncio.wait_for(
                self._checker.check_pack(new, context), TIMEOUT_SECONDS
            )
        except Exception as exc:  # noqa: BLE001 — TimeoutError included; fail open
            logger.warning("LanguageFixStage order_id=%s failed: %r", ctx.order_id, exc)
            verdicts = None
        if verdicts is None:
            return StageResult(info={"failed": 1, "unchecked": len(new)})

        rejected_by: Counter = Counter()
        kinds_applied: Counter = Counter()
        originals = [q.model_copy(deep=True) for q in new]
        try:
            for q, verdict in zip(new, verdicts):
                if verdict is None:
                    counts["unchecked"] += 1
                    continue
                counts["checked"] += 1
                if verdict.ok:
                    continue
                counts["flagged"] += 1
                applied = self._apply(q, verdict, ctx, rejected_by, kinds_applied)
                counts["changed_questions"] += bool(applied)
                counts["edits_applied"] += applied
        except Exception as exc:  # noqa: BLE001 — fail open: the round goes on as generated
            logger.warning(
                "LanguageFixStage order_id=%s failed applying: %r", ctx.order_id, exc
            )
            ctx.questions[ctx.locked_count :] = originals
            return StageResult(info={"failed": 1, "unchecked": len(new)})
        counts["edits_rejected"] = sum(rejected_by.values())
        info = {
            k: counts[k]
            for k in (
                "checked",
                "unchecked",
                "flagged",
                "changed_questions",
                "edits_applied",
                "edits_rejected",
            )
        }
        info["rejected_by"] = dict(rejected_by)
        info["kinds_applied"] = dict(kinds_applied)
        logger.info("LanguageFixStage order_id=%s %s", ctx.order_id, info)
        return StageResult(info=info)

    def _apply(
        self,
        q: Question,
        verdict: PackCheck,
        ctx: OrderContext,
        rejected_by: Counter,
        kinds_applied: Counter,
    ) -> int:
        """Apply the safe edits of one question, record all; return how many applied."""
        proposals: list[tuple[str, str, str, str | None]] = []
        for field, after in verdict.edits.items():
            before = _get(q, field)
            if after == before:
                continue
            proposals.append(
                (field, before, after, _rejection(field, before, after, q.language))
            )
            # MCQ: correct_answer holds the full text of the right option.
            if (
                field.startswith("option:")
                and proposals[-1][3] is None
                and before == q.correct_answer
            ):
                proposals.append(("correct_answer", before, after, None))

        fixed = q.model_copy(deep=True)
        for field, _, after, rejected in proposals:
            if rejected is None:
                _set(fixed, field, after)
        if order_audience.is_child(ctx.audience) and kids_check.length_violation(
            fixed, ctx.audience
        ):
            proposals = [(f, b, a, r or "kids_cap") for f, b, a, r in proposals]

        applied = 0
        for field, before, after, rejected in proposals:
            kinds = _kinds(verdict.problems, before)
            if rejected is None:
                _set(q, field, after)
                applied += 1
                kinds_applied.update(kinds)
            else:
                rejected_by[rejected] += 1
            text_edits.record(
                q,
                step=STEP,
                field=field,
                before=before,
                after=after,
                rejected=rejected,
                kinds=kinds,
                problems=verdict.problems,
                model=self._checker.model,
                version=f"naturalness-{PROMPT_VERSION}+pack-{PACK_NOTE_VERSION}",
            )
        return applied
