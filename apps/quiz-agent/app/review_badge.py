"""Per-question review badge for TestFlight sessions (#176).

The founder field-tests SK/CS translations in TestFlight but, in the game, could
not tell a human-approved question from a machine-approved translation — and
never met a machine-*rejected* one at all, because those were not served. This
module turns the review state that already exists in the corpus
(``questions.review_status``) and in the gate's evidence
(``question_translations.status`` + ``verification``) into ONE short label.

Two invariants hold this together:

1. **App Store is untouched.** Every entry point returns the payload unchanged
   unless ``build_channel == "testflight"``, so the wire an App Store client
   decodes is byte-identical to pre-#176 (the keys are absent, not null).
2. **One badge per question.** The states are ordered by severity and the
   highest one wins, so a question can never show two contradicting labels.

No LLM call, no extra query: the badge is derived from data the serve path has
already read (hot path, founder constraint).
"""

from __future__ import annotations

from typing import Any, Dict, Optional, Tuple

from quiz_shared.models.question import Question

# ── The badge states ─────────────────────────────────────────────────────────
# Five founder-decided states (2026-09-10) plus two for "this text is not a
# stored translation at all", which the serve path can still produce while the
# #168 corpus cutover is incomplete.
APPROVED = "approved"
PENDING_REVIEW = "pending_review"
TRANSLATION_MACHINE = "translation_machine"
TRANSLATION_FLAGGED = "translation_flagged"
TRANSLATION_CRITICAL = "translation_critical"
# No stored row for (question, language): the old serve-time LLM translation
# produced this text, so no gate ever saw it.
TRANSLATION_LIVE = "translation_live"
# No stored row and no live translation either — the player is reading English
# in a non-English session.
EN_FALLBACK = "en_fallback"

# Severity order, worst first. `translation_live` / `en_fallback` sit with
# `translation_machine`: none of them is a defect signal, but none is a human
# vouch either. `pending_review` outranks them because an unvouched *question*
# is a bigger caveat than an unvouched translation of a vouched one.
BADGE_PRIORITY = (
    TRANSLATION_CRITICAL,
    TRANSLATION_FLAGGED,
    PENDING_REVIEW,
    TRANSLATION_MACHINE,
    TRANSLATION_LIVE,
    EN_FALLBACK,
    APPROVED,
)

# Only these two carry a note: the others have nothing to explain.
_NOTED_BADGES = (TRANSLATION_FLAGGED, TRANSLATION_CRITICAL)

# Record keys the stored-translation reader stamps, so `/question`, the audio
# route and a re-graded submission all reproduce the badge from the session's
# own record instead of re-querying the store.
RECORD_BADGE_KEY = "review_badge"
RECORD_NOTE_KEY = "review_note"


def translation_badge(
    status: str, verification: Optional[Dict[str, Any]]
) -> Tuple[str, Optional[str]]:
    """``(badge, note)`` for one stored ``question_translations`` row.

    Mirrors the bucket rule the review export already uses
    (``scripts/translation_runner/review.py:select_for_review``) so the founder
    sees the same classification in the game as on the rating web: a refused row
    is critical, a row the judge or the regional classifier left a mark on is
    flagged, anything else is a clean machine approval.
    """
    evidence = verification or {}
    if status == "rejected":
        return TRANSLATION_CRITICAL, _note(evidence)
    judge_findings = (evidence.get("judge") or {}).get("findings") or []
    regional_flag = bool((evidence.get("regional") or {}).get("flag"))
    if judge_findings or regional_flag:
        return TRANSLATION_FLAGGED, _note(evidence)
    return TRANSLATION_MACHINE, None


def _note(verification: Dict[str, Any]) -> Optional[str]:
    """One line saying what the gate objected to, or None.

    The judge's first finding is the richest source, but it is not the only
    reason a row gets refused: a guard failure skips the judge entirely, and an
    answerability flip produces no finding either. Those two are the majority of
    rejections in the #168 corpus run, so a note that only ever read judge
    findings would be empty exactly when the badge is loudest.
    """
    findings = (verification.get("judge") or {}).get("findings") or []
    if findings:
        note = (findings[0] or {}).get("note")
        if note:
            return str(note)
    reasons = (verification.get("guards") or {}).get("reasons") or []
    if reasons:
        return str(reasons[0])
    verdict = (verification.get("answerability") or {}).get("verdict")
    if verdict and verdict != "ok":
        return f"answerability: {verdict}"
    regional_reason = (verification.get("regional") or {}).get("reason")
    if regional_reason:
        return str(regional_reason)
    return None


def badge_for(
    question: Question, record: Optional[Dict[str, Any]], language: str
) -> Tuple[str, Optional[str]]:
    """``(badge, note)`` for the question as this session is actually serving it.

    ``record`` is the serve-time translation record (stored row or live
    translation); None means no translation was applied at all.
    """
    question_badge = APPROVED if question.review_status == APPROVED else PENDING_REVIEW
    if language == "en":
        # No translation dimension: the question's own review state is the
        # whole story, and a stale record from a language switch is not.
        return question_badge, None

    if record is None:
        translation = EN_FALLBACK
        note = None
    else:
        translation = record.get(RECORD_BADGE_KEY) or TRANSLATION_LIVE
        note = record.get(RECORD_NOTE_KEY)

    badge = min(
        (question_badge, translation),
        key=lambda candidate: BADGE_PRIORITY.index(candidate),
    )
    return badge, (note if badge in _NOTED_BADGES else None)


def review_badge_fields(
    question: Question,
    record: Optional[Dict[str, Any]],
    *,
    language: str,
    build_channel: Optional[str],
) -> Dict[str, str]:
    """The three wire fields, or ``{}`` for any client that must not see them."""
    if build_channel != "testflight":
        return {}
    badge, note = badge_for(question, record, language)
    fields = {
        "review_badge": badge,
        # The language the served text is actually in — English whenever no
        # translation was applied, whatever the session asked for.
        "translation_language": (record or {}).get("language") or "en",
    }
    if note:
        fields["review_note"] = note
    return fields


def apply_review_badge(
    question_dict: Dict[str, Any],
    question: Question,
    record: Optional[Dict[str, Any]],
    *,
    language: str,
    build_channel: Optional[str],
) -> Dict[str, Any]:
    """Stamp the badge onto a public question dict (in place) and return it.

    A no-op for every non-TestFlight client, and idempotent for a TestFlight one
    (the same inputs produce the same three values), so a caller that cannot
    easily prove the badge was already applied may simply apply it again.
    """
    question_dict.update(
        review_badge_fields(
            question, record, language=language, build_channel=build_channel
        )
    )
    return question_dict
