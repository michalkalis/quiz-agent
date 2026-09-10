"""Serve a pre-translated SK/CS row instead of translating at request time (#176).

#168 translated the whole corpus into `question_translations` and gated every
row, but the serve path still paid for an LLM call per question and showed text
no gate had ever seen. This module makes the stored row the PRIMARY source:

- a row exists for (question, session language) → serve it, no LLM call;
- no row → the caller falls back to today's serve-time translation, unchanged.

Which rows count as servable depends on the build channel, and that is the whole
point of #176: a TestFlight session also gets `rejected` rows (badged critical,
so the founder meets the machine's refusals in the game), an App Store client
only ever gets `approved` ones.

The returned dict is the same *translation record* shape
``app.serializers.build_question_translation`` produces, so everything
downstream — display overlay, grading, the result screen, the audio route —
keeps reading one shape and does not care which path produced it. It carries two
extra keys (``review_badge``/``review_note``): the badge is derived here, while
the gate evidence is in hand, and then rides the session record so no later
reader has to query the store again.
"""

from __future__ import annotations

import logging
from typing import Any, Dict, Optional, Sequence

from quiz_shared.models.question import Question

from .review_badge import (
    RECORD_BADGE_KEY,
    RECORD_NOTE_KEY,
    translation_badge,
)

logger = logging.getLogger(__name__)

# App Store: vouched rows only. TestFlight: also the refused ones (#176).
_APP_STORE_STATUSES: Sequence[str] = ("approved",)
_TESTFLIGHT_STATUSES: Sequence[str] = ("approved", "rejected")


def servable_statuses(build_channel: Optional[str]) -> Sequence[str]:
    """Which ``question_translations.status`` values this client may be served."""
    return (
        _TESTFLIGHT_STATUSES if build_channel == "testflight" else _APP_STORE_STATUSES
    )


async def stored_translation_record(
    question: Question,
    language: str,
    question_store: Any = None,
    *,
    build_channel: Optional[str] = None,
) -> Optional[Dict[str, Any]]:
    """The stored translation record for this question, or None to fall back.

    None is returned for an English session, when no store is wired, when the
    store has no servable row, and when the lookup itself fails — in every one of
    those cases the caller's existing serve-time translation path still runs, so
    a store outage degrades to today's behaviour rather than breaking a quiz.
    """
    if language == "en" or question_store is None:
        return None
    try:
        rows = await question_store.get_translations(
            [question.id], language, servable_statuses(build_channel)
        )
    except Exception as e:  # pragma: no cover - surfaces only on a DB outage
        logger.warning(
            "Stored translation lookup failed for %s/%s: %s", question.id, language, e
        )
        return None
    row = (rows or {}).get(question.id)
    if not row:
        return None
    return _record(row, language)


def _record(row: Dict[str, Any], language: str) -> Dict[str, Any]:
    """Map a stored row onto the translation-record shape.

    ``status``/``verification`` are deliberately *not* copied through: they are
    collapsed into the badge here so the record that gets persisted on the
    session stays small and JSON-stable.
    """
    badge, note = translation_badge(row.get("status") or "", row.get("verification"))
    return {
        "question_id": row["question_id"],
        "language": row.get("language") or language,
        "question": row["question"],
        "possible_answers": dict(row["possible_answers"] or {}) or None,
        "explanation": row.get("explanation"),
        "headline_answer": row.get("headline_answer"),
        "correct_answer": row["correct_answer"],
        "correct_answer_key": row.get("correct_answer_key"),
        # C1/DD5: the evaluator matches a free-text answer against the accepted
        # alternates, so serving translated text with English alternates would
        # score a correct Slovak answer wrong.
        "alternative_answers": list(row.get("alternative_answers") or []),
        RECORD_BADGE_KEY: badge,
        RECORD_NOTE_KEY: note,
    }
