"""Session phase enum and transition table.

The session phase is a small state machine. Adding a new phase or transition
should be a single edit here — callers go through `QuizSession.transition(to=...)`
rather than mutating `session.phase` directly.

Mirrors the iOS-side `QuizState.validTransitions` table in
`apps/ios-app/Hangs/Hangs/ViewModels/QuizViewModel.swift`.
"""

from __future__ import annotations

from enum import Enum
from typing import Dict, FrozenSet


class SessionPhase(str, Enum):
    """Lifecycle of a `QuizSession`.

    String-valued so existing serialized sessions (SQLite reload) round-trip
    without migration.
    """

    IDLE = "idle"
    ASKING = "asking"
    AWAITING_ANSWER = "awaiting_answer"
    FINISHED = "finished"


# Allowed successors for each phase. `FINISHED` is terminal.
VALID_TRANSITIONS: Dict[SessionPhase, FrozenSet[SessionPhase]] = {
    SessionPhase.IDLE: frozenset({SessionPhase.ASKING}),
    SessionPhase.ASKING: frozenset({SessionPhase.AWAITING_ANSWER, SessionPhase.FINISHED}),
    SessionPhase.AWAITING_ANSWER: frozenset({SessionPhase.ASKING, SessionPhase.FINISHED}),
    SessionPhase.FINISHED: frozenset(),
}


class InvalidPhaseTransition(ValueError):
    """Raised when a caller asks for a phase change the table forbids."""

    def __init__(self, from_phase: SessionPhase, to_phase: SessionPhase):
        self.from_phase = from_phase
        self.to_phase = to_phase
        super().__init__(
            f"Invalid phase transition: {from_phase.value} -> {to_phase.value}. "
            f"Allowed from {from_phase.value}: "
            f"{sorted(p.value for p in VALID_TRANSITIONS[from_phase])}"
        )


def is_valid_transition(from_phase: SessionPhase, to_phase: SessionPhase) -> bool:
    """Return True if `from_phase -> to_phase` is allowed by the table."""
    return to_phase in VALID_TRANSITIONS.get(from_phase, frozenset())
