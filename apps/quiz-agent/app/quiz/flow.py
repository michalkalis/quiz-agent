"""Shared quiz flow logic for processing answers and advancing sessions.

Extracted from the duplicated logic between /input and /voice/submit endpoints.
"""

import asyncio
import base64
import logging
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional

from ..evaluation.evaluator import AnswerEvaluator
from ..input.parser import InputParser
from ..retrieval.question_retriever import QuestionRetriever
from ..session.manager import SessionManager
from ..tts.number_normalization import normalize_numbers_for_tts
from ..tts.service import TTSService
from ..usage.tracker import UsageTracker

from quiz_shared.models.question import Question
from quiz_shared.models.session import LastEvaluation, QuizSession
from quiz_shared.models.phase import SessionPhase

from ..serializers import (
    apply_question_translation,
    correct_option_key,
    question_to_dict,
    session_translation,
    translated_question_payload,
    translated_question_view,
)

logger = logging.getLogger(__name__)

# Strong references to in-flight TTS prefetch tasks. asyncio holds only weak refs,
# so without this set tasks could be garbage-collected mid-execution.
_prefetch_tasks: "set[asyncio.Task]" = set()

# The parser emits a difficulty *direction* ("harder"/"easier"), while the corpus
# stores discrete levels — so a direction is one clamped step along
# easy → medium → hard. "random" has no direction and is left alone.
_DIFFICULTY_STEPS = {
    "harder": {"easy": "medium", "medium": "hard", "hard": "hard"},
    "easier": {"hard": "medium", "medium": "easy", "easy": "easy"},
}


def prefetch_question_audio(
    tts_service: Optional[TTSService], question_text: str, language: str
) -> None:
    """Fire-and-forget TTS warm-up so the next /question/audio request hits the cache.

    Returns immediately. Failures are logged but never propagate to the caller —
    a missed prefetch just means iOS pays the original synthesis cost.

    ``language`` is required because the serve route synthesizes
    ``normalize_numbers_for_tts(text, language)`` and the cache key is the exact
    text: warming the raw stem warms a key nothing ever reads, so any stem with a
    digit was synthesized (and paid for) twice.
    """
    if not tts_service or not question_text:
        return

    tts_text = normalize_numbers_for_tts(question_text, language)
    task = asyncio.create_task(tts_service.synthesize_question(tts_text))
    _prefetch_tasks.add(task)
    task.add_done_callback(_prefetch_tasks.discard)
    task.add_done_callback(_log_prefetch_outcome)


def _log_prefetch_outcome(task: "asyncio.Task") -> None:
    if task.cancelled():
        return
    exc = task.exception()
    if exc:
        logger.warning("TTS prefetch failed: %s", exc)
    else:
        logger.debug("TTS prefetch completed (cache warmed)")


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


def _same_submission(new_text: str, graded_text: str) -> bool:
    """Whether a re-sent submission is the same answer that was already graded.

    Compared case- and whitespace-insensitively because the evaluator normalizes
    both anyway: a retry differing only there would produce the identical verdict,
    so replaying it is free and correct. Anything else — an edited transcript, a
    re-transcribed upload — is a genuinely different answer and gets re-graded.
    """
    return new_text.strip().casefold() == graded_text.strip().casefold()


@dataclass
class FlowResult:
    """Result of processing a quiz answer through the flow."""

    evaluation: Optional[Dict[str, Any]] = None
    feedback_received: List[str] = field(default_factory=list)
    next_question_dict: Optional[Dict[str, Any]] = None
    audio_info: Optional[Dict[str, Any]] = None
    quiz_finished: bool = False
    message: str = "Input processed"
    usage_limit_error: Optional[Dict[str, Any]] = None


@dataclass
class _IntentOutcome:
    """What one parse-and-apply pass actually changed, for the caller to persist.

    ``score_delta``/``answered_delta`` are the participant-counter effects, kept
    so a re-graded submission can reverse the previous verdict exactly (#133 1a).
    """

    score_delta: float = 0.0
    answered_delta: int = 0
    preferences_changed: bool = False
    feedback_audio: Optional[bytes] = None


class QuizFlowService:
    """Processes quiz answers: parse intents, evaluate, update score, advance session."""

    def __init__(
        self,
        session_manager: SessionManager,
        input_parser: InputParser,
        question_retriever: QuestionRetriever,
        answer_evaluator: AnswerEvaluator,
        tts_service: Optional[TTSService],
        usage_tracker: Optional[UsageTracker],
        translation_service: Any,
    ):
        self.session_manager = session_manager
        self.input_parser = input_parser
        self.question_retriever = question_retriever
        self.answer_evaluator = answer_evaluator
        self.tts_service = tts_service
        self.usage_tracker = usage_tracker
        self.translation_service = translation_service

    def classify_submission(
        self, session: QuizSession, submitted_question_id: Optional[str]
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

    async def process_answer(
        self,
        session: QuizSession,
        answer_text: str,
        participant_id: Optional[str] = None,
        include_audio: bool = False,
        next_question: Optional[Question] = None,
        submitted_question_id: Optional[str] = None,
    ) -> FlowResult:
        """Process a user's answer through the full quiz flow.

        Args:
            session: Current quiz session
            answer_text: User's answer (text or transcribed voice)
            participant_id: Optional participant ID for multiplayer
            include_audio: Whether to include audio info in response
            next_question: Pre-fetched next question (from parallel fetch in voice endpoint)
            submitted_question_id: The question the client believes it is answering
                (#133 1a). None = legacy client, always the current question. An
                already-graded id is replayed or re-graded against that question
                instead of scoring the current one; anything else raises
                ``QuestionMismatch``.

        Returns:
            FlowResult with evaluation, next question, audio info, etc.
        """
        if self.classify_submission(session, submitted_question_id):
            return await self._process_resubmission(
                session=session,
                previous=session.last_evaluation,
                answer_text=answer_text,
                participant_id=participant_id,
                include_audio=include_audio,
            )

        result = FlowResult()
        evaluated_question_id = session.current_question_id

        # Get current question. The retriever is sync and blocks the calling
        # thread on the pgvector bridge (and, for retrieval, an OpenAI embedding
        # HTTP call) — keep it off the event loop, as /voice/submit already does.
        current_question = await asyncio.to_thread(
            self.question_retriever.get, evaluated_question_id
        )
        if not current_question:
            raise ValueError("Current question not found")

        translation = session_translation(session, evaluated_question_id)
        outcome = await self._apply_intents(
            session=session,
            answer_text=answer_text,
            evaluated_question_id=evaluated_question_id,
            question=current_question,
            translation=translation,
            participant_id=participant_id,
            include_audio=include_audio,
            result=result,
        )

        # Ghost-question guard (#66): a non-answer intent (rating, difficulty,
        # preference, category, or an unparseable utterance) produces no evaluation.
        # Return BEFORE the session-advance block so we never advance
        # current_question_id or burn a freemium question on a non-answer. The
        # callers surface this as a 400 with no state mutation.
        if result.evaluation is None:
            return self._no_answer_result(session, result, outcome)

        # #133 1a: remember what was graded BEFORE anything advances, so a retry
        # of this same submission is replayed instead of scoring the next question.
        session.last_evaluation = self._evaluation_record(
            result=result,
            question_id=evaluated_question_id,
            submitted_text=answer_text,
            translation=translation,
            participant_id=participant_id,
            outcome=outcome,
        )

        # Build audio info
        if include_audio:
            result.audio_info = self._build_audio_info(
                session.session_id, result.evaluation, outcome.feedback_audio
            )

        # Check if quiz is finished
        if len(session.asked_question_ids) >= session.max_questions:
            session.transition(
                to=SessionPhase.FINISHED, caller="flow.process_answer:max_questions"
            )
            self.session_manager.update_session(session)
            result.quiz_finished = True
            result.message = "Quiz completed!"
            return result

        # Check usage limit. #95: custom-pack sessions bypass the free monthly
        # quota (paid, curated content).
        if self.usage_tracker and session.user_id and not session.pack_id:
            allowed, remaining, resets_at = await self.usage_tracker.check_limit(
                session.user_id
            )
            if not allowed:
                session.transition(
                    to=SessionPhase.FINISHED, caller="flow.process_answer:usage_limit"
                )
                self.session_manager.update_session(session)
                usage = await self.usage_tracker.get_usage(session.user_id)
                result.usage_limit_error = {
                    "error": "quota_limit_reached",
                    "questions_used": usage["questions_used"],
                    "questions_limit": usage["questions_limit"],
                    "resets_at": usage["resets_at"],
                    "upgrade_available": True,
                    "evaluation": result.evaluation,
                }
                return result

        # Get next question (use pre-fetched if available)
        if next_question is None:
            next_question = await asyncio.to_thread(
                self.question_retriever.get_next_question, session
            )

        if not next_question:
            session.transition(
                to=SessionPhase.FINISHED, caller="flow.process_answer:no_more_questions"
            )
            self.session_manager.update_session(session)
            result.quiz_finished = True
            result.message = "No more questions available"
            return result

        # Advance session to next question. Phase stays "asking" — there's no
        # backend-side state for "answer received, next question loading", so
        # advancing the question_id is the entire transition. (No self-loop.)
        session.current_question_id = next_question.id
        session.asked_question_ids.append(next_question.id)

        # Record usage (#95: skipped for custom-pack sessions — see check above)
        if self.usage_tracker and session.user_id and not session.pack_id:
            await self.usage_tracker.record_question(session.user_id)

        # Translate the next question ONCE (stem + options + explanation + answer)
        # and persist the record: /question, /question/audio and the next
        # evaluation all read it instead of re-translating.
        translated_q_dict, translation_record = await translated_question_payload(
            next_question,
            session.language,
            self.translation_service,
            session_id=session.session_id,
        )
        session.current_question_text = translated_q_dict["question"]
        session.current_question_translation = translation_record
        self.session_manager.update_session(session)

        result.next_question_dict = translated_q_dict

        # Add question audio URL
        if include_audio:
            if not result.audio_info:
                result.audio_info = {}
            result.audio_info["question_url"] = (
                f"/api/v1/sessions/{session.session_id}/question/audio"
            )
            result.audio_info["format"] = "opus"

            # Warm TTS cache so iOS gets a cache hit when it requests this URL.
            # iOS plays feedback + result screen + auto-advance (~3-5s) before requesting,
            # giving OpenAI TTS time to finish in the background.
            prefetch_question_audio(
                self.tts_service, translated_q_dict["question"], session.language
            )

        return result

    async def _apply_intents(
        self,
        session: QuizSession,
        answer_text: str,
        evaluated_question_id: str,
        question: Question,
        translation: Optional[Dict[str, Any]],
        participant_id: Optional[str],
        include_audio: bool,
        result: FlowResult,
    ) -> _IntentOutcome:
        """Parse ``answer_text`` and apply every intent it carries to session + result.

        Shared by a first submission and a re-graded one (#133 1a) so an edited
        transcript goes through the identical parse → evaluate → score path, just
        pointed at the question it was written for. Returns what was applied, so
        the caller can persist it and — on a re-grade — reverse the previous
        verdict's effect.
        """
        # #132 D / #126: score against the question exactly as the player saw it.
        # The serve-time translation record (one LLM call, stored on the session)
        # carries the translated stem, options, explanation and answer — so the
        # spoken Slovak answer is matched against Slovak option text, and the
        # result screen quotes the same strings. No record (English session, or a
        # translation that fell back) → the original English question, unchanged.
        display_question = translated_question_view(question, translation)

        # Parse intents (fast-path for literal "skip")
        if answer_text.strip().lower() == "skip":
            intents = [{"intent_type": "skip", "extracted_data": {}}]
        else:
            intents = await self.input_parser.parse(
                user_input=answer_text,
                current_question=display_question.question,
                phase=session.phase,
            )

        outcome = _IntentOutcome()

        # Process intents
        for intent in intents:
            intent_type = intent.get("intent_type")
            extracted_data = intent.get("extracted_data", {})

            if intent_type == "answer":
                user_answer = extracted_data.get("answer")
                eval_result, score_delta = await self.answer_evaluator.evaluate(
                    user_answer=user_answer,
                    question=display_question,
                    question_text=display_question.question,
                )

                translated_correct = await self._correct_answer_display(
                    question, translation, session
                )

                result.evaluation = {
                    "user_answer": user_answer,
                    "result": eval_result,
                    "points": score_delta,
                    "correct_answer": translated_correct,
                    "question_id": evaluated_question_id,
                }
                if display_question.headline_answer:
                    result.evaluation["headline_answer"] = (
                        display_question.headline_answer
                    )
                if display_question.explanation:
                    result.evaluation["explanation"] = display_question.explanation

                # Generate enhanced feedback audio
                if include_audio and self.tts_service:
                    outcome.feedback_audio = await self._generate_feedback_audio(
                        eval_result, translated_correct, session.language
                    )

                # Update participant score
                self._update_participant_score(session, participant_id, score_delta)
                outcome.score_delta += score_delta
                outcome.answered_delta += 1
                result.feedback_received.append(f"answer: {eval_result}")

            elif intent_type == "skip":
                translated_correct = await self._correct_answer_display(
                    question, translation, session
                )
                result.evaluation = {
                    "user_answer": "skipped",
                    "result": "skipped",
                    "points": 0.0,
                    "correct_answer": translated_correct,
                    "question_id": evaluated_question_id,
                }
                if display_question.headline_answer:
                    result.evaluation["headline_answer"] = (
                        display_question.headline_answer
                    )
                if display_question.explanation:
                    result.evaluation["explanation"] = display_question.explanation
                result.feedback_received.append("skipped question")

            elif intent_type == "rating":
                rating_value = extracted_data.get("rating")
                result.feedback_received.append(f"rating: {rating_value}")

            elif intent_type == "preference_change":
                for topic in extracted_data.get("avoid_topics") or []:
                    if not topic:
                        continue
                    if topic not in session.disliked_topics:
                        session.disliked_topics.append(topic)
                        outcome.preferences_changed = True
                    result.feedback_received.append(f"avoiding: {topic}")
                for topic in extracted_data.get("prefer_topics") or []:
                    if not topic:
                        continue
                    if topic not in session.preferred_topics:
                        session.preferred_topics.append(topic)
                        outcome.preferences_changed = True
                    result.feedback_received.append(f"preference: {topic}")
                stepped = _DIFFICULTY_STEPS.get(
                    extracted_data.get("difficulty"), {}
                ).get(session.current_difficulty)
                if stepped:
                    # A clamped direction ("harder" at hard) is acknowledged to the
                    # player but changed nothing — nothing to persist.
                    if stepped != session.current_difficulty:
                        outcome.preferences_changed = True
                    session.current_difficulty = stepped
                    result.feedback_received.append(f"difficulty: {stepped}")

        return outcome

    async def _process_resubmission(
        self,
        session: QuizSession,
        previous: LastEvaluation,
        answer_text: str,
        participant_id: Optional[str],
        include_audio: bool,
    ) -> FlowResult:
        """Handle a submit for the question this session already graded (#133 1a).

        Same text (a retry whose original response was lost) → replay the stored
        verdict: no evaluation call, no quota, no advance, no counter change.
        Different text (an edited transcript, or a retried voice upload the STT
        transcribed slightly differently) → re-grade it against THAT question,
        reverse the previous verdict's counter effect and replace the record.

        Either way the session never advances twice and the freemium quota is
        never charged twice — that is the whole invariant this branch exists for.
        """
        result = FlowResult()

        if _same_submission(answer_text, previous.submitted_text):
            result.evaluation = dict(previous.evaluation)
            result.feedback_received = list(previous.feedback_received)
            result.message = "Answer already processed"
            result.next_question_dict = await self._current_question_payload(session)
            if include_audio:
                result.audio_info = self._resubmitted_audio_info(
                    session, result.evaluation, None
                )
            return result

        question = await asyncio.to_thread(
            self.question_retriever.get, previous.question_id
        )
        if not question:
            raise ValueError("Re-submitted question not found")

        outcome = await self._apply_intents(
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
            return self._no_answer_result(session, result, outcome)

        # Replace, don't accumulate: undo what the previous verdict applied to the
        # participant before keeping the new one.
        self._update_participant_score(
            session,
            previous.participant_id,
            -previous.points_awarded,
            answered_delta=-previous.answered_count_delta,
        )
        session.last_evaluation = self._evaluation_record(
            result=result,
            question_id=previous.question_id,
            submitted_text=answer_text,
            translation=previous.translation,
            participant_id=participant_id,
            outcome=outcome,
        )
        self.session_manager.update_session(session)

        result.next_question_dict = await self._current_question_payload(session)
        result.message = "Answer re-evaluated"
        if include_audio:
            result.audio_info = self._resubmitted_audio_info(
                session, result.evaluation, outcome.feedback_audio
            )
        return result

    def _no_answer_result(
        self, session: QuizSession, result: FlowResult, outcome: _IntentOutcome
    ) -> FlowResult:
        """Finish a submission that carried no answer (ghost-question guard, #66).

        Nothing advances and no quota is charged. A preference the utterance DID
        carry ("no more geography", said on its own) is still persisted: it was
        parsed and applied to the session, and returning before ``update_session``
        threw it away — the player then kept getting the topic they just rejected.
        """
        result.message = "No answer detected in input"
        if outcome.preferences_changed:
            self.session_manager.update_session(session)
            result.message = "Preferences updated, no answer detected"
        return result

    @staticmethod
    def _evaluation_record(
        *,
        result: FlowResult,
        question_id: str,
        submitted_text: str,
        translation: Optional[Dict[str, Any]],
        participant_id: Optional[str],
        outcome: _IntentOutcome,
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
        )

    async def _current_question_payload(
        self, session: QuizSession
    ) -> Optional[Dict[str, Any]]:
        """The question the session is on now, in the exact wording it was served.

        Rebuilt from the stored serve-time translation record, never re-translated,
        so replaying a lost response costs no LLM call. None when there is no
        current question or the row has since disappeared.
        """
        if not session.current_question_id:
            return None
        question = await asyncio.to_thread(
            self.question_retriever.get, session.current_question_id
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
        self,
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
        info = self._build_audio_info(session.session_id, evaluation, feedback_audio)
        if session.current_question_id:
            info["question_url"] = (
                f"/api/v1/sessions/{session.session_id}/question/audio"
            )
        return info

    def _update_participant_score(
        self,
        session: QuizSession,
        participant_id: Optional[str],
        score_delta: float,
        answered_delta: int = 1,
    ):
        """Apply a score/answered-count delta to the answering participant.

        Negative deltas reverse a previously applied verdict (#133 1a re-grade), so
        the same targeting rule decides who is credited and who is un-credited.
        """
        if participant_id:
            for p in session.participants:
                if p.participant_id == participant_id:
                    p.score += score_delta
                    p.answered_count += answered_delta
        elif session.participants:
            session.participants[0].score += score_delta
            session.participants[0].answered_count += answered_delta

    def _build_audio_info(
        self,
        session_id: str,
        evaluation: Dict[str, Any],
        enhanced_feedback_audio: Optional[bytes],
    ) -> Dict[str, Any]:
        """Build audio info dict for the response."""
        result_type = evaluation.get("result", "")
        if enhanced_feedback_audio:
            return {
                "feedback_audio_base64": base64.b64encode(
                    enhanced_feedback_audio
                ).decode(),
                "format": "opus",
            }
        return {
            "feedback_url": f"/api/v1/sessions/{session_id}/feedback/{result_type}/audio",
            "format": "opus",
        }

    async def _generate_feedback_audio(
        self, result: str, correct_answer: str, language: str
    ) -> Optional[bytes]:
        """Generate TTS audio for answer feedback."""
        try:
            from ..translation.feedback_messages import get_correct_answer_message

            feedback_text = get_correct_answer_message(
                result=result, answer=correct_answer, language=language
            )
            return await self.tts_service.synthesize(text=feedback_text, use_cache=True)
        except Exception as e:
            logger.warning("Failed to generate enhanced feedback: %s", e)
            return None

    async def _correct_answer_display(
        self,
        question: Question,
        translation: Optional[Dict[str, Any]],
        session: QuizSession,
    ) -> str:
        """The correct answer as the result screen and feedback audio say it.

        Prefers the serve-time translation record (free — already paid for by the
        one payload call, and guaranteed to be the same wording as the options the
        player saw). Only a session with no record — English, or a translation that
        fell back — pays for the legacy single-string translation.
        """
        if translation:
            return translation["correct_answer"]
        # No record → the player saw the ENGLISH question. Corpus MCQ rows store
        # ``correct_answer`` either as option text or as the bare key ("b"), and
        # a lone letter is useless on the result screen and unspeakable in the
        # feedback audio — resolve it to the option text the player actually saw.
        # The raw value is only right for non-MCQ questions.
        correct_key = correct_option_key(question)
        if correct_key is not None:
            return question.possible_answers[correct_key]
        correct = question.correct_answer
        if isinstance(correct, list):
            correct = correct[0] if correct else ""
        return await self._translate_correct_answer(
            str(correct), session.language, session_id=session.session_id
        )

    async def _translate_correct_answer(
        self, answer: str, language: str, session_id: str | None = None
    ) -> str:
        """Translate correct answer to target language."""
        if language == "en" or not self.translation_service:
            return answer
        try:
            return await self.translation_service.translate_feedback(
                feedback=answer, target_language=language, session_id=session_id
            )
        except Exception as e:
            logger.warning("Failed to translate correct answer to %s: %s", language, e)
            return answer
