"""A record of every automatic change to a question's text.

Founder 2026-11-18: "chcem aby sa zapisovali tieto upravy, aby sme vedeli co
aky krok meni a ako" — each step that rewrites question text after generation
appends one entry per field it touched, applied or not, so it can be judged
later which step changes what and whether it helps.

Entries live in ``generation_metadata.extra["text_edits"]`` (the
``questions.provenance`` JSONB column): a list of
``{"step", "field", "before", "after", "applied", "rejected", ...detail}``.
``rejected`` is the reason a proposed edit was not applied (``None`` when it
was). Any other text-changing step can call :func:`record` with its own name.
"""

from __future__ import annotations

from typing import Any

from quiz_shared.models.question import GenerationProvenance, Question

KEY = "text_edits"


def record(
    q: Question,
    *,
    step: str,
    field: str,
    before: str,
    after: str,
    rejected: str | None = None,
    **detail: Any,
) -> None:
    """Append one edit (applied when ``rejected`` is None) to the question."""
    provenance = q.generation_metadata or GenerationProvenance()
    entry = {
        "step": step,
        "field": field,
        "before": before,
        "after": after,
        "applied": rejected is None,
        "rejected": rejected,
        **detail,
    }
    q.generation_metadata = provenance.model_copy(
        update={
            "extra": {**provenance.extra, KEY: [*provenance.extra.get(KEY, []), entry]}
        }
    )


def edits(q: Question) -> list[dict[str, Any]]:
    meta = q.generation_metadata
    return list(meta.extra.get(KEY, [])) if meta else []
