"""Typed failure modes of the shared answer-submit flow (#148).

``POST /sessions/{id}/input`` and ``POST /voice/submit/{id}`` run over one
``QuizFlowService.process_answer``, so every condition it raises has to mean the
same thing on both. It did not: the flow raised a bare ``ValueError`` for a
missing question row, which the text route's generic handler paged on (500 +
Sentry) while the voice route's bare ``except ValueError`` handed the player a
400 with the raw internal message — one flow, two contradictory error contracts
(arch audit 2026-08-06).

Each class here names **whose fault** the condition is, and that is what decides
the status code. ``app.api.submit_errors`` owns the single mapping to HTTP;
nothing on the submit paths may map an untyped exception to a status code.
"""

from typing import Optional


class QuizFlowError(Exception):
    """Base for every condition the shared submit flow raises deliberately."""


class QuestionUnavailable(QuizFlowError):
    """The question the flow must grade against is not in the store.

    A server-side data fault — the row was deleted or expired mid-session, or
    retrieval came back empty — never something the client did wrong. It pages
    (500 + Sentry) on both routes instead of telling the player their input was
    bad, because a player who says the right thing into a session whose question
    row vanished has a backend bug, not a bad answer.
    """

    def __init__(self, question_id: Optional[str], *, stage: str):
        super().__init__(f"{stage} question not found (question_id={question_id!r})")
        self.question_id = question_id
        self.stage = stage


class InvalidSubmission(QuizFlowError):
    """Client-supplied content the submit path refuses before grading it.

    Today that is an audio upload whose format or size Whisper cannot take. The
    message is constructed server-side from validation facts (never an internal
    detail echoed back), so it is safe to return verbatim as a 400.
    """


class QuestionMismatch(QuizFlowError):
    """A submit carried a ``question_id`` this session cannot grade (#133 1a).

    It is neither the current question nor the last graded one, so the client is
    a whole question out of step (stale UI, resumed session) and grading the text
    would score the wrong question. Raised before any mutation — session state is
    untouched — and turned into a 409 carrying the current id so the client can
    resync instead of silently answering something the player never saw.
    """

    def __init__(self, current_question_id: Optional[str]):
        super().__init__(
            "submitted question_id does not match this session "
            f"(current={current_question_id})"
        )
        self.current_question_id = current_question_id
