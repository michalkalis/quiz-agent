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
from ..tts.service import TTSService
from ..usage.tracker import UsageTracker

from quiz_shared.models.question import Question
from quiz_shared.models.session import QuizSession

from ..serializers import question_to_dict

logger = logging.getLogger(__name__)

# Strong references to in-flight TTS prefetch tasks. asyncio holds only weak refs,
# so without this set tasks could be garbage-collected mid-execution.
_prefetch_tasks: "set[asyncio.Task]" = set()


def prefetch_question_audio(tts_service: Optional[TTSService], question_text: str) -> None:
    """Fire-and-forget TTS warm-up so the next /question/audio request hits the cache.

    Returns immediately. Failures are logged but never propagate to the caller —
    a missed prefetch just means iOS pays the original synthesis cost.
    """
    if not tts_service or not question_text:
        return

    task = asyncio.create_task(tts_service.synthesize_question(question_text))
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
        chroma_client: Any,
        translation_service: Any,
    ):
        self.session_manager = session_manager
        self.input_parser = input_parser
        self.question_retriever = question_retriever
        self.answer_evaluator = answer_evaluator
        self.tts_service = tts_service
        self.usage_tracker = usage_tracker
        self.chroma_client = chroma_client
        self.translation_service = translation_service

    async def process_answer(
        self,
        session: QuizSession,
        answer_text: str,
        participant_id: Optional[str] = None,
        include_audio: bool = False,
        next_question: Optional[Question] = None,
    ) -> FlowResult:
        """Process a user's answer through the full quiz flow.

        Args:
            session: Current quiz session
            answer_text: User's answer (text or transcribed voice)
            participant_id: Optional participant ID for multiplayer
            include_audio: Whether to include audio info in response
            next_question: Pre-fetched next question (from parallel fetch in voice endpoint)

        Returns:
            FlowResult with evaluation, next question, audio info, etc.
        """
        result = FlowResult()
        evaluated_question_id = session.current_question_id

        # Get current question
        current_question = self.chroma_client.get_question(evaluated_question_id)
        if not current_question:
            raise ValueError("Current question not found")

        # Parse intents (fast-path for literal "skip")
        if answer_text.strip().lower() == "skip":
            intents = [{"intent_type": "skip", "extracted_data": {}}]
        else:
            intents = await self.input_parser.parse(
                user_input=answer_text,
                current_question=current_question.question,
                phase=session.phase,
            )

        enhanced_feedback_audio = None

        # Process intents
        for intent in intents:
            intent_type = intent.get("intent_type")
            extracted_data = intent.get("extracted_data", {})

            if intent_type == "answer":
                user_answer = extracted_data.get("answer")
                eval_result, score_delta = await self.answer_evaluator.evaluate(
                    user_answer=user_answer,
                    question=current_question,
                    question_text=current_question.question,
                )

                translated_correct = await self._translate_correct_answer(
                    str(current_question.correct_answer), session.language
                )

                result.evaluation = {
                    "user_answer": user_answer,
                    "result": eval_result,
                    "points": score_delta,
                    "correct_answer": translated_correct,
                    "question_id": evaluated_question_id,
                }
                if current_question.explanation:
                    result.evaluation["explanation"] = current_question.explanation

                # Generate enhanced feedback audio
                if include_audio and self.tts_service:
                    enhanced_feedback_audio = await self._generate_feedback_audio(
                        eval_result, translated_correct, session.language
                    )

                # Update participant score
                self._update_participant_score(session, participant_id, score_delta)
                result.feedback_received.append(f"answer: {eval_result}")

            elif intent_type == "skip":
                translated_correct = await self._translate_correct_answer(
                    str(current_question.correct_answer), session.language
                )
                result.evaluation = {
                    "user_answer": "skipped",
                    "result": "skipped",
                    "points": 0.0,
                    "correct_answer": translated_correct,
                    "question_id": evaluated_question_id,
                }
                if current_question.explanation:
                    result.evaluation["explanation"] = current_question.explanation
                result.feedback_received.append("skipped question")

            elif intent_type == "rating":
                rating_value = extracted_data.get("rating")
                result.feedback_received.append(f"rating: {rating_value}")

            elif intent_type == "difficulty_change":
                difficulty = extracted_data.get("difficulty")
                session.current_difficulty = difficulty
                result.feedback_received.append(f"difficulty: {difficulty}")

            elif intent_type == "preference_change":
                topic = extracted_data.get("topic", "")
                if topic.startswith("-"):
                    topic = topic[1:]
                    if topic not in session.disliked_topics:
                        session.disliked_topics.append(topic)
                    result.feedback_received.append(f"avoiding: {topic}")
                else:
                    if topic not in session.preferred_topics:
                        session.preferred_topics.append(topic)
                    result.feedback_received.append(f"preference: {topic}")

            elif intent_type == "category_change":
                category = extracted_data.get("category")
                session.category = category
                result.feedback_received.append(f"category: {category}")

        # Build audio info
        if include_audio and result.evaluation:
            result.audio_info = self._build_audio_info(
                session.session_id, result.evaluation, enhanced_feedback_audio
            )

        # Check if quiz is finished
        if len(session.asked_question_ids) >= session.max_questions:
            session.phase = "finished"
            self.session_manager.update_session(session)
            result.quiz_finished = True
            result.message = "Quiz completed!"
            return result

        # Check usage limit
        if self.usage_tracker and session.user_id:
            allowed, remaining, resets_at = self.usage_tracker.check_limit(session.user_id)
            if not allowed:
                session.phase = "finished"
                self.session_manager.update_session(session)
                usage = self.usage_tracker.get_usage(session.user_id)
                result.usage_limit_error = {
                    "error": "daily_limit_reached",
                    "questions_used": usage["questions_used"],
                    "questions_limit": usage["questions_limit"],
                    "resets_at": usage["resets_at"],
                    "upgrade_available": True,
                    "evaluation": result.evaluation,
                }
                return result

        # Get next question (use pre-fetched if available)
        if next_question is None:
            next_question = self.question_retriever.get_next_question(session)

        if not next_question:
            session.phase = "finished"
            self.session_manager.update_session(session)
            result.quiz_finished = True
            result.message = "No more questions available"
            return result

        # Advance session to next question
        session.current_question_id = next_question.id
        session.asked_question_ids.append(next_question.id)
        session.phase = "asking"

        # Record usage
        if self.usage_tracker and session.user_id:
            self.usage_tracker.record_question(session.user_id)

        # Cache translated question text
        translated_q_dict = await self._question_to_dict_translated(next_question, session.language)
        session.current_question_text = translated_q_dict["question"]
        self.session_manager.update_session(session)

        result.next_question_dict = translated_q_dict

        # Add question audio URL
        if include_audio:
            if not result.audio_info:
                result.audio_info = {}
            result.audio_info["question_url"] = f"/api/v1/sessions/{session.session_id}/question/audio"
            result.audio_info["format"] = "opus"

            # Warm TTS cache so iOS gets a cache hit when it requests this URL.
            # iOS plays feedback + result screen + auto-advance (~3-5s) before requesting,
            # giving OpenAI TTS time to finish in the background.
            prefetch_question_audio(self.tts_service, translated_q_dict["question"])

        return result

    def _update_participant_score(
        self, session: QuizSession, participant_id: Optional[str], score_delta: float
    ):
        """Update the score for the answering participant."""
        if participant_id:
            for p in session.participants:
                if p.participant_id == participant_id:
                    p.score += score_delta
                    p.answered_count += 1
        elif session.participants:
            session.participants[0].score += score_delta
            session.participants[0].answered_count += 1

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
                "feedback_audio_base64": base64.b64encode(enhanced_feedback_audio).decode(),
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

    async def _translate_correct_answer(self, answer: str, language: str) -> str:
        """Translate correct answer to target language."""
        if language == "en" or not self.translation_service:
            return answer
        try:
            return await self.translation_service.translate_feedback(
                feedback=answer, target_language=language
            )
        except Exception as e:
            logger.warning("Failed to translate correct answer to %s: %s", language, e)
            return answer

    async def _question_to_dict_translated(
        self, question: Question, language: str
    ) -> Dict[str, Any]:
        """Convert Question to dict with translated question text."""
        question_dict = question_to_dict(question)
        if self.translation_service and language != "en":
            try:
                translated_text = await self.translation_service.translate_question(
                    question=question.question, target_language=language
                )
                question_dict["question"] = translated_text
            except Exception as e:
                logger.warning("Failed to translate question text to %s: %s", language, e)
        return question_dict
