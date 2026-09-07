"""The translated draft the gate judges — the DD3 serve payload, in memory.

The gate runs on file-based drafts (arm-test output, batch retrieval) before
the DD3 ``question_translations`` table exists, so the draft is a plain
dataclass carrying exactly the translated fields DD3 stores — nothing about
provenance or status, which the runner owns.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Optional


@dataclass
class TranslatedDraft:
    """One machine translation of one question into one language."""

    question: str
    correct_answer: str
    possible_answers: Optional[dict[str, str]] = None
    # DD3/DD13: MCQ comparison is on the option KEY, not the option text.
    correct_answer_key: Optional[str] = None
    alternative_answers: list[str] = field(default_factory=list)
    explanation: Optional[str] = None
    headline_answer: Optional[str] = None

    @classmethod
    def from_payload(cls, payload: dict[str, Any]) -> "TranslatedDraft":
        """Build from the runner's JSON payload (arm-file / batch shape)."""
        return cls(
            question=str(payload.get("question") or ""),
            correct_answer=str(payload.get("correct_answer") or ""),
            possible_answers=payload.get("possible_answers") or None,
            correct_answer_key=payload.get("correct_answer_key"),
            alternative_answers=list(payload.get("alternative_answers") or []),
            explanation=payload.get("explanation"),
            headline_answer=payload.get("headline_answer"),
        )
