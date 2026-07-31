"""Re-submission handling: replay, re-grade, refuse (#133 1a) and the re-grade cap.

Clients re-POST an answer for a question the server has already graded — the
transient-retry wrapper re-sends when a response is lost, and editing a voice
transcript submits corrected text after the original was accepted. This module
owns everything that follows from that:

- **classify** the submit (current question / already-graded question / out of
  step, which is refused with ``QuestionMismatch``),
- **replay** the stored verdict when the text is unchanged,
- **re-grade** it against the SAME question when the text differs, reversing the
  previous verdict's counter effect,
- **bound** the re-grade path (``REGRADE_CAP``), which is quota-free by design and
  was therefore unbounded paid work.

Split out of ``flow.py`` (#133 V-split): the flow module is the parse → evaluate
→ advance path, this is the idempotency layer over it. Deliberately a leaf —
functions take the ``QuizFlowService`` explicitly and reach back through it, so
``flow`` imports this module and never the reverse.
"""

from __future__ import annotations

import asyncio
import logging
from dataclasses import dataclass
from typing import TYPE_CHECKING, Any, Dict, Optional

import sentry_sdk

from quiz_shared.models.session import LastEvaluation, QuizSession

from ..serializers import (
    apply_question_translation,
    question_to_dict,
    session_translation,
)

if TYPE_CHECKING:  # pragma: no cover - typing only, avoids a flow ↔ resubmission cycle
    from .flow import FlowResult, QuizFlowService

logger = logging.getLogger(__name__)

# How many times one question may be re-graded with different text (#133 V6b).
# Re-grading is quota-free on purpose, so this is the only thing standing between
# the edited-transcript flow and unbounded evaluator/Whisper/TTS spend on a single
# question. Three covers "Whisper misheard me, and my correction was also off"
# with room to spare; anything past it is a client loop or an abuser.
REGRADE_CAP = 3


class QuestionMismatch(Exception):
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


@dataclass
class IntentOutcome:
    """What one parse-and-apply pass actually changed, for the caller to persist.

    ``score_delta``/``answered_delta`` are the participant-counter effects, kept
    so a re-graded submission can reverse the previous verdict exactly (#133 1a).
    """

    score_delta: float = 0.0
    answered_delta: int = 0
    feedback_audio: Optional[bytes] = None


def _same_submission(new_text: str, graded_text: str) -> bool:
    """Whether a re-sent submission is the same answer that was already graded.

    Compared case- and whitespace-insensitively because the evaluator normalizes
    both anyway: a retry differing only there would produce the identical verdict,
    so replaying it is free and correct. Anything else — an edited transcript, a
    re-transcribed upload — is a genuinely different answer and gets re-graded.
    """
    return new_text.strip().casefold() == graded_text.strip().casefold()


def classify_submission(
    session: QuizSession, submitted_question_id: Optional[str]
) -> bool:
    """True when a submit re-sends a question this session already graded (#133 1a).

    False = grade it against the current question, which is also the legacy
    path: a client that sends no ``question_id`` behaves exactly as before.
    Raises ``QuestionMismatch`` when the id is neither the current nor the
    last-graded question.

    Pure and side-effect free, so callers can gate expensive work on it — the
    voice route checks it before paying for transcription.
    """
    if (
        submitted_question_id is None
        or submitted_question_id == session.current_question_id
    ):
        return False
    previous = session.last_evaluation
    if previous is not None and previous.question_id == submitted_question_id:
        return True
    raise QuestionMismatch(session.current_question_id)


def evaluation_record(
    *,
    result: "FlowResult",
    question_id: str,
    submitted_text: str,
    translation: Optional[Dict[str, Any]],
    participant_id: Optional[str],
    outcome: IntentOutcome,
    regrade_count: int = 0,
) -> LastEvaluation:
    """Snapshot a graded submission for idempotent re-submits (#133 1a)."""
    return LastEvaluation(
        question_id=question_id,
        submitted_text=submitted_text,
        evaluation=dict(result.evaluation or {}),
        feedback_received=list(result.feedback_received),
        points_awarded=outcome.score_delta,
        answered_count_delta=outcome.answered_delta,
        participant_id=participant_id,
        translation=translation,
        regrade_count=regrade_count,
    )


async def process_resubmission(
    flow: "QuizFlowService",
    *,
    session: QuizSession,
    previous: LastEvaluation,
    answer_text: str,
    participant_id: Optional[str],
    include_audio: bool,
    result: "FlowResult",
) -> "FlowResult":
    """Handle a submit for the question this session already graded (#133 1a).

    Same text (a retry whose original response was lost) → replay the stored
    verdict: no evaluation call, no quota, no advance, no counter change.
    Different text (an edited transcript, or a retried voice upload the STT
    transcribed slightly differently) → re-grade it against THAT question,
    reverse the previous verdict's counter effect and replace the record.

    Either way the session never advances twice and the freemium quota is
    never charged twice — that is the whole invariant this branch exists for.
    """
    if _same_submission(answer_text, previous.submitted_text):
        return await _replay_stored_verdict(
            flow, session, previous, result, include_audio, "Answer already processed"
        )

    # #133 V6b: re-grading is deliberately quota-free (editing a transcript must
    # not cost a question), which made it an unbounded *paid* path — every
    # different text buys an evaluator call, and on voice a Whisper transcription
    # and feedback TTS too, at the route's 30/min. Editing is one or two
    # corrections; past the cap hand back the verdict the client already has
    # instead of re-evaluating. Degraded, not an error: the response shape is a
    # replay, so a client looping on retries still gets a valid answer.
    if previous.regrade_count >= REGRADE_CAP:
        message = (
            "Re-grade cap reached: replaying stored verdict instead of "
            f"re-evaluating (#133 V6b, cap={REGRADE_CAP}, "
            f"session_id={session.session_id!r}, "
            f"question_id={previous.question_id!r})"
        )
        logger.warning(message)
        sentry_sdk.capture_message(message, level="warning")
        return await _replay_stored_verdict(
            flow, session, previous, result, include_audio, "Re-grade limit reached"
        )

    question = await asyncio.to_thread(
        flow.question_retriever.get, previous.question_id
    )
    if not question:
        raise ValueError("Re-submitted question not found")

    outcome = await flow._apply_intents(
        session=session,
        answer_text=answer_text,
        evaluated_question_id=previous.question_id,
        question=question,
        translation=previous.translation,
        participant_id=participant_id,
        include_audio=include_audio,
        result=result,
    )

    # An edit that parses to no answer must not destroy the verdict the client
    # already holds: keep the stored record and let the route 400, exactly as
    # for a first submission with no answer in it.
    if result.evaluation is None:
        return flow._no_answer_result(result)

    # Replace, don't accumulate: undo what the previous verdict applied to the
    # participant before keeping the new one.
    flow._update_participant_score(
        session,
        previous.participant_id,
        -previous.points_awarded,
        answered_delta=-previous.answered_count_delta,
    )
    session.last_evaluation = evaluation_record(
        result=result,
        question_id=previous.question_id,
        submitted_text=answer_text,
        translation=previous.translation,
        participant_id=participant_id,
        outcome=outcome,
        regrade_count=previous.regrade_count + 1,
    )
    flow.session_manager.update_session(session)

    result.next_question_dict = await _current_question_payload(flow, session)
    result.message = "Answer re-evaluated"
    if include_audio:
        result.audio_info = _resubmitted_audio_info(
            flow, session, result.evaluation, outcome.feedback_audio
        )
    return result


async def _replay_stored_verdict(
    flow: "QuizFlowService",
    session: QuizSession,
    previous: LastEvaluation,
    result: "FlowResult",
    include_audio: bool,
    message: str,
) -> "FlowResult":
    """Hand back the stored verdict verbatim: no evaluation, no write, no charge.

    Serves both a genuine replay (identical text) and a re-grade refused by the
    cap (#133 V6b) — the client gets a valid, complete answer either way, and
    the only difference is the ``message`` that says which happened.
    """
    result.evaluation = dict(previous.evaluation)
    result.feedback_received = list(previous.feedback_received)
    result.message = message
    result.next_question_dict = await _current_question_payload(flow, session)
    if include_audio:
        result.audio_info = _resubmitted_audio_info(
            flow, session, result.evaluation, None
        )
    return result


async def _current_question_payload(
    flow: "QuizFlowService", session: QuizSession
) -> Optional[Dict[str, Any]]:
    """The question the session is on now, in the exact wording it was served.

    Rebuilt from the stored serve-time translation record, never re-translated,
    so replaying a lost response costs no LLM call. None when there is no
    current question or the row has since disappeared.
    """
    if not session.current_question_id:
        return None
    question = await asyncio.to_thread(
        flow.question_retriever.get, session.current_question_id
    )
    if not question:
        return None
    record = session_translation(session, question.id)
    payload = apply_question_translation(question_to_dict(question), record)
    if not record and session.current_question_text:
        # Pre-#132 session, or a serve where translation fell back: the stem is
        # the only translated string stored — same fallback GET /question uses.
        payload["question"] = session.current_question_text
    return payload


def _resubmitted_audio_info(
    flow: "QuizFlowService",
    session: QuizSession,
    evaluation: Dict[str, Any],
    feedback_audio: Optional[bytes],
) -> Dict[str, Any]:
    """Audio block for a replayed / re-graded submission.

    With no freshly synthesized feedback (a replay evaluates nothing) the block
    carries the cache-backed ``feedback_url`` instead of inline base64: a retry
    must not pay OpenAI TTS again for audio the client can fetch. The static
    ``question_url`` is included because the client may have lost the original
    response that carried it, but no prefetch is fired — that question's audio
    was already warmed when it was served.
    """
    info = flow._build_audio_info(session.session_id, evaluation, feedback_audio)
    if session.current_question_id:
        info["question_url"] = f"/api/v1/sessions/{session.session_id}/question/audio"
    return info
