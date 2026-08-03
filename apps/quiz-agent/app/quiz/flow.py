"""Shared quiz flow logic for processing answers and advancing sessions.

Extracted from the duplicated logic between /input and /voice/submit endpoints.

The first grade of a question lives here: parse intents → evaluate → score →
advance. Everything about a submit for a question that was ALREADY graded
(replay, re-grade, refuse, the re-grade cap) lives in ``resubmission.py``.
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
from ..tts.spoken_text import spoken_question_text
from ..tts.service import TTSService
from ..usage.tracker import UsageTracker

from quiz_shared.models.question import Question
from quiz_shared.models.session import QuizSession
from quiz_shared.models.phase import SessionPhase

from .resubmission import (
    QuestionMismatch,  # noqa: F401 — re-exported: routes and tests import it from here
    IntentOutcome,
    classify_submission,
    evaluation_record,
    process_resubmission,
)

from ..serializers import (
    correct_option_key,
    session_translation,
    translated_question_payload,
    translated_question_view,
)

logger = logging.getLogger(__name__)

# Strong references to in-flight TTS prefetch tasks. asyncio holds only weak refs,
# so without this set tasks could be garbage-collected mid-execution.
_prefetch_tasks: "set[asyncio.Task]" = set()


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

        Method form of ``resubmission.classify_submission`` — the voice route calls
        it on the injected flow service to gate transcription spend.
        """
        return classify_submission(session, submitted_question_id)

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
        if classify_submission(session, submitted_question_id):
            return await process_resubmission(
                self,
                session=session,
                previous=session.last_evaluation,
                answer_text=answer_text,
                participant_id=participant_id,
                include_audio=include_audio,
                result=FlowResult(),
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

        # Ghost-question guard (#66): a non-answer intent (rating, explanation
        # request, or an unparseable utterance) produces no evaluation.
        # Return BEFORE the session-advance block so we never advance
        # current_question_id or burn a freemium question on a non-answer. The
        # callers surface this as a 400 with no state mutation.
        if result.evaluation is None:
            return self._no_answer_result(result)

        # #133 1a: remember what was graded BEFORE anything advances, so a retry
        # of this same submission is replayed instead of scoring the next question.
        session.last_evaluation = evaluation_record(
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
                self.tts_service,
                spoken_question_text(
                    translated_q_dict["question"],
                    translated_q_dict.get("possible_answers"),
                ),
                session.language,
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
    ) -> IntentOutcome:
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

        outcome = IntentOutcome()

        # Process intents
        for intent in intents:
            intent_type = intent.get("intent_type")
            extracted_data = intent.get("extracted_data", {})

            if intent_type == "answer":
                # #133 V9: the classifier can return an answer intent with a
                # missing or null "answer" (it heard speech, extracted nothing).
                # ``user_answer`` is projected straight into the response and iOS
                # decodes it as a non-optional String — a null killed the decode of
                # the WHOLE response, losing a verdict the player had already been
                # charged for. Empty string is the contract: iOS renders it as
                # "said nothing", and the evaluator already grades it "skipped".
                user_answer = extracted_data.get("answer") or ""
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

        return outcome

    def _no_answer_result(self, result: FlowResult) -> FlowResult:
        """Finish a submission that carried no answer (ghost-question guard, #66).

        Nothing advances, no quota is charged, and the session is not persisted.
        """
        result.message = "No answer detected in input"
        return result

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
