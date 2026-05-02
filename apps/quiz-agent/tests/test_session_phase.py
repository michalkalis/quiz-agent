"""Unit tests for the SessionPhase transition table.

Pure unit tests on the QuizSession model — no fixtures, no IO. Mirrors the
shape of the iOS-side `QuizState.validTransitions` tests.
"""

import pytest

from quiz_shared.models.phase import (
    InvalidPhaseTransition,
    SessionPhase,
    VALID_TRANSITIONS,
    is_valid_transition,
)
from quiz_shared.models.session import QuizSession


def _session(phase: SessionPhase = SessionPhase.IDLE) -> QuizSession:
    return QuizSession(session_id="sess_test", phase=phase)


# ── Transition table coverage ────────────────────────────────────────────────


@pytest.mark.parametrize(
    "from_phase, to_phase",
    [
        (SessionPhase.IDLE, SessionPhase.ASKING),
        (SessionPhase.ASKING, SessionPhase.AWAITING_ANSWER),
        (SessionPhase.ASKING, SessionPhase.FINISHED),
        (SessionPhase.AWAITING_ANSWER, SessionPhase.ASKING),
        (SessionPhase.AWAITING_ANSWER, SessionPhase.FINISHED),
    ],
)
def test_valid_transition_succeeds(from_phase, to_phase):
    session = _session(from_phase)
    session.transition(to=to_phase)
    assert session.phase == to_phase


@pytest.mark.parametrize(
    "from_phase, to_phase",
    [
        # No self-loops anywhere.
        (SessionPhase.IDLE, SessionPhase.IDLE),
        (SessionPhase.ASKING, SessionPhase.ASKING),
        (SessionPhase.AWAITING_ANSWER, SessionPhase.AWAITING_ANSWER),
        (SessionPhase.FINISHED, SessionPhase.FINISHED),
        # Skipping IDLE -> FINISHED isn't allowed; quiz must start first.
        (SessionPhase.IDLE, SessionPhase.FINISHED),
        (SessionPhase.IDLE, SessionPhase.AWAITING_ANSWER),
        # Cannot un-finish.
        (SessionPhase.FINISHED, SessionPhase.IDLE),
        (SessionPhase.FINISHED, SessionPhase.ASKING),
        (SessionPhase.FINISHED, SessionPhase.AWAITING_ANSWER),
        # Cannot rewind to idle from mid-quiz.
        (SessionPhase.ASKING, SessionPhase.IDLE),
        (SessionPhase.AWAITING_ANSWER, SessionPhase.IDLE),
    ],
)
def test_invalid_transition_raises(from_phase, to_phase):
    session = _session(from_phase)
    with pytest.raises(InvalidPhaseTransition) as exc_info:
        session.transition(to=to_phase)
    assert exc_info.value.from_phase == from_phase
    assert exc_info.value.to_phase == to_phase
    # Phase must be unchanged after a rejected transition.
    assert session.phase == from_phase


def test_finished_is_terminal():
    """No outgoing edges from FINISHED."""
    assert VALID_TRANSITIONS[SessionPhase.FINISHED] == frozenset()


def test_every_phase_has_an_entry():
    """Catch typos: every enum member must be a key in the table."""
    assert set(VALID_TRANSITIONS.keys()) == set(SessionPhase)


def test_transition_accepts_string_target():
    """Callers may pass `"asking"` or `SessionPhase.ASKING` interchangeably."""
    session = _session(SessionPhase.IDLE)
    session.transition(to="asking")
    assert session.phase == SessionPhase.ASKING


def test_transition_rejects_unknown_string():
    session = _session(SessionPhase.IDLE)
    with pytest.raises(ValueError):
        session.transition(to="not-a-real-phase")


def test_caller_label_does_not_change_outcome():
    """`caller=` is just for telemetry — must not affect validation."""
    session = _session(SessionPhase.IDLE)
    session.transition(to=SessionPhase.ASKING, caller="test_suite")
    assert session.phase == SessionPhase.ASKING


def test_is_valid_transition_helper_matches_method():
    """The pure-function helper agrees with the method on every pair."""
    for src in SessionPhase:
        for dst in SessionPhase:
            session = _session(src)
            method_ok = True
            try:
                session.transition(to=dst)
            except InvalidPhaseTransition:
                method_ok = False
            assert is_valid_transition(src, dst) == method_ok, (
                f"Disagreement on {src.value} -> {dst.value}"
            )


# ── Serialization ────────────────────────────────────────────────────────────


def test_phase_serializes_as_string():
    """SQLite-stored sessions must round-trip without migration."""
    session = _session(SessionPhase.ASKING)
    dumped = session.model_dump_json()
    assert '"phase":"asking"' in dumped


def test_phase_round_trips_through_json():
    """Loading from JSON gives a SessionPhase, not a raw str."""
    original = _session(SessionPhase.AWAITING_ANSWER)
    restored = QuizSession.model_validate_json(original.model_dump_json())
    assert restored.phase == SessionPhase.AWAITING_ANSWER
    assert isinstance(restored.phase, SessionPhase)


def test_legacy_string_phase_still_loads():
    """A QuizSession persisted before this refactor (raw `str` phase) must load."""
    legacy_json = '{"session_id":"sess_old","phase":"asking"}'
    restored = QuizSession.model_validate_json(legacy_json)
    assert restored.phase == SessionPhase.ASKING
