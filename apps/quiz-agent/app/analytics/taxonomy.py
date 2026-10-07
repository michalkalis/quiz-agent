"""The analytics event allowlist (issue #51) — the single source of truth.

Every event name and every property key that may be stored is listed here; the
recorder drops anything else. That is the privacy guarantee (no transcript, no
free text, no PII can ride in on an ad-hoc key) and the taxonomy guard (no
event outside ``docs/product/analytics-events.md``). Adding an event = add it
here AND to that doc AND to the App Store privacy label if it collects a new
data type.
"""

from __future__ import annotations

# Emitted by this API, where the truth lives.
SERVER_EVENTS: dict[str, frozenset[str]] = {
    "quiz_started": frozenset(
        {"category", "language", "difficulty", "mode", "is_pack", "max_questions"}
    ),
    "answer_evaluated": frozenset(
        {
            "question_id",
            "result",
            "category",
            "question_type",
            "difficulty",
            "route",
            "is_regrade",
            "question_index",
        }
    ),
    "quiz_completed": frozenset({"reason", "questions_asked", "score", "is_pack"}),
    "quota_hit": frozenset({"stage", "questions_used", "questions_limit"}),
    "transcription_failed": frozenset({"reason", "question_id"}),
    "store_event": frozenset(
        {"type", "product_id", "environment", "store", "period_type"}
    ),
}

# Posted by the app — only what the server cannot observe itself.
CLIENT_EVENTS: dict[str, frozenset[str]] = {
    "app_opened": frozenset({"launch"}),
    "onboarding_finished": frozenset({"outcome", "step"}),
    "quiz_context": frozenset({"audio_route", "voice_commands_enabled", "entry_point"}),
    "quiz_abandoned": frozenset({"questions_answered", "phase"}),
    "answer_submitted": frozenset({"input_mode", "question_id", "is_retry"}),
    "voice_capture_failed": frozenset({"reason", "question_id"}),
    "voice_command": frozenset({"command", "phase"}),
    "paywall_viewed": frozenset({"source"}),
    "purchase_result": frozenset({"product_id", "kind", "outcome"}),
    "restore_result": frozenset({"outcome"}),
}

# Property values are short scalars only: a long string is either a bug or free
# text that must not be stored.
MAX_STRING_LEN = 100


def clean_properties(allowed: frozenset[str], properties: dict | None) -> dict:
    """Keep allowlisted keys with scalar values; truncate strings."""
    cleaned: dict = {}
    for key, value in (properties or {}).items():
        if key not in allowed or value is None:
            continue
        if isinstance(value, str):
            cleaned[key] = value[:MAX_STRING_LEN]
        elif isinstance(value, (bool, int, float)):
            cleaned[key] = value
    return cleaned
