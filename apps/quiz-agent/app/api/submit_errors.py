"""The one exception→HTTP mapping for the answer-submit routes (#148).

Both submit routes run over the same ``QuizFlowService.process_answer``, so the
same condition must produce the same status code, the same Sentry behaviour and
the same retryability on both. Before this module they did not: the retryable
503 envelope iOS relies on (``TransientRetry.isTransient`` passes only 502/503)
existed only on the text route, so a DB blip during a *voice* submit could never
engage the shipped client retry, and a missing question row was a client-blaming
400 on voice but a paging 500 on text.

Keep this the only place a submit-path exception becomes a status code. The
statuses clients already depend on are fixed: 409 ``question_mismatch``, 400 for
a client-side input problem, 503 for transient infra, 500 for everything else.
"""

import logging

import sentry_sdk
from fastapi import HTTPException
from sqlalchemy.exc import OperationalError
from sqlalchemy.exc import TimeoutError as SATimeoutError

from ..quiz.errors import InvalidSubmission, QuestionMismatch, QuestionUnavailable

logger = logging.getLogger(__name__)

# #131 Track A: DB connection/pool errors typical of a Fly `auto_stop_machines`
# cold wake (staging) — surface these as a retryable 503 instead of a raw 500.
# ``OperationalError`` covers DBAPI/asyncpg disconnects; ``SATimeoutError`` is
# the SQLAlchemy pool-checkout timeout (pool exhaustion); ``ConnectionError``/
# ``TimeoutError`` catch a raw socket failure before SQLAlchemy wraps it.
TRANSIENT_INFRA_ERRORS = (
    OperationalError,
    SATimeoutError,
    ConnectionError,
    TimeoutError,
)


def submit_http_error(
    exc: Exception, *, session_id: str, fallback_detail: str
) -> HTTPException:
    """The HTTP error a submit-path exception must become, on either route.

    ``fallback_detail`` is the route's own client-safe wording for a server
    fault; the exception's own message is never leaked for a 5xx.
    """
    if isinstance(exc, QuestionMismatch):
        # #133 1a: the client is a whole question out of step. Grading its text
        # would score a question the player never saw, so refuse and hand back
        # the id to resync on. Nothing was mutated.
        return HTTPException(
            status_code=409,
            detail={
                "code": "question_mismatch",
                "current_question_id": exc.current_question_id,
            },
        )

    if isinstance(exc, InvalidSubmission):
        # Constructed validation text (format/size) — client-safe by design.
        logger.warning("Submission rejected for session %s: %s", session_id, exc)
        return HTTPException(status_code=400, detail=str(exc))

    if isinstance(exc, QuestionUnavailable):
        # Server-side data fault: the row the flow had to grade against is gone.
        # It pages on BOTH routes — the player's input was fine.
        return _server_fault(exc, session_id=session_id, detail=fallback_detail)

    if isinstance(exc, TRANSIENT_INFRA_ERRORS):
        # Cold-wake DB hiccup (Fly auto_stop_machines) or pool exhaustion —
        # retryable, not a bug. iOS retries 502/503 (TransientRetry.isTransient).
        logger.warning(
            "Transient infra error on submit (session=%s): %s", session_id, exc
        )
        return HTTPException(
            status_code=503, detail="Temporary server issue, please retry"
        )

    # Anything unforeseen is a bug: never downgrade it to "just retry".
    return _server_fault(exc, session_id=session_id, detail=fallback_detail)


def _server_fault(exc: Exception, *, session_id: str, detail: str) -> HTTPException:
    """500 the loud way: logged with a traceback, captured, detail kept generic."""
    logger.error("Submit failed for session %s: %s", session_id, exc, exc_info=True)
    if sentry_sdk.get_client().is_active():
        sentry_sdk.capture_exception(exc)
    return HTTPException(status_code=500, detail=detail)
