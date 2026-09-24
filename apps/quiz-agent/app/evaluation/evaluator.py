"""Answer evaluation with nuanced scoring.

Ported from graph.py:445-518
"""

import logging
import re
from typing import Tuple

from quiz_shared.llm import factory as llm_factory
from quiz_shared.models.question import Question
from quiz_shared.utils.text_normalization import normalize_text

from .mcq_matcher import match_option
from .voice_match import sounds_like_any

logger = logging.getLogger(__name__)

# #185 G: an MCQ answer that names no option. Not a verdict the player ever
# sees as such — the flow either asks again (clients declaring `answer-codes`)
# or grades it "incorrect" (today's contract for builds that predate it).
UNMATCHED = "unmatched"


class AnswerEvaluator:
    """Evaluates quiz answers with fair, nuanced scoring.

    Uses two-tier evaluation:
    1. Fast path: Normalized text matching
    2. LLM path: Nuanced evaluation for partial credit
    """

    def __init__(self, model: str = "gpt-4o-mini", temperature: float = 0.3):
        """Initialize answer evaluator.

        Args:
            model: OpenAI model for evaluation
            temperature: Lower temperature for deterministic evaluation
        """
        self.client = llm_factory.openai_client(async_=True)
        self.model = llm_factory.resolve_model(model)
        self.temperature = temperature

    async def evaluate(
        self, user_answer: str, question: Question, question_text: str = ""
    ) -> Tuple[str, float]:
        """Evaluate user's answer against correct answer.

        Args:
            user_answer: User's answer
            question: Question object with correct answer
            question_text: Question text for context

        Returns:
            Tuple of (result, score_delta)
            - result: "correct" | "partially_correct" | "partially_incorrect" | "incorrect" | "skipped"
              | "unmatched" (MCQ only: the answer names no option — see ``UNMATCHED``)
            - score_delta: Points to add (0, 0.25, 0.5, or 1.0)

        Example:
            >>> evaluator = AnswerEvaluator()
            >>> result, points = await evaluator.evaluate(
            ...     "paris",
            ...     question,
            ...     "What is the capital of France?"
            ... )
            >>> result
            'correct'
            >>> points
            1.0
        """
        # Handle skip or empty
        if not user_answer or user_answer.strip() == "":
            return "skipped", 0.0

        correct_answer = question.correct_answer
        if isinstance(correct_answer, list):
            correct_answer = correct_answer[0]  # Use first if multiple

        # Open-shape questions (46.B7) carry a short `headline_answer` gist — the
        # gettable answer a player can speak while driving — alongside the long
        # `correct_answer` resolution. Score against the gist (generously), since
        # the full resolution would never match a short spoken answer.
        scoring_answer = question.headline_answer or correct_answer

        # Fast path: Normalized exact match
        if normalize_text(user_answer) == normalize_text(str(scoring_answer)):
            return "correct", 1.0

        # Check alternative answers
        for alt in question.alternative_answers:
            if normalize_text(user_answer) == normalize_text(alt):
                return "correct", 1.0

        # MCQ fast-path: match against option keys or values (no partial credit)
        if question.possible_answers:
            return self._evaluate_mcq(user_answer, question)

        # #185 E: a transcript that clearly SOUNDS like the answer ("Carling" for
        # "curling") is correct without asking the judge. Only ever accepts —
        # anything it does not recognise goes on to the LLM unchanged.
        if sounds_like_any(
            user_answer, [str(scoring_answer), *question.alternative_answers]
        ):
            logger.info(
                "Sound-alike accepted without LLM: heard=%r expected=%r",
                user_answer,
                str(scoring_answer),
            )
            return "correct", 1.0

        # LLM evaluation for nuanced scoring
        result = await self._llm_evaluate(
            user_answer=user_answer,
            correct_answer=str(scoring_answer),
            question_text=question_text or question.question,
            alternative_answers=question.alternative_answers,
        )

        # Map result to score delta
        score_map = {
            "correct": 1.0,
            "partially_correct": 0.5,
            "partially_incorrect": 0.25,
            "incorrect": 0.0,
        }

        return result, score_map.get(result, 0.0)

    def _evaluate_mcq(
        self,
        user_answer: str,
        question: Question,
    ) -> Tuple[str, float]:
        """Evaluate an MCQ answer spoken or typed in any form the player uses.

        ``match_option`` resolves the label, letter, ordinal, colloquial form or
        the option text itself (#185 G). No partial credit for MCQ — the player
        picked from finite options — and no guess: an answer that names no
        single option is ``UNMATCHED``, never "incorrect" by default.

        Args:
            user_answer: What the player said ("C", "tretia", "Paríž", …)
            question: Question with possible_answers dict

        Returns:
            Tuple of (result, score_delta)
        """
        options = question.possible_answers  # {"a": "Paris", "b": "London", ...}
        selected_key = match_option(user_answer, options)
        if selected_key is None:
            return UNMATCHED, 0.0

        # Resolve correct_answer to a key (it might be stored as "a" or "Paris")
        correct = question.correct_answer
        if isinstance(correct, list):
            correct = correct[0]
        correct_key = correct
        if correct_key not in options:
            # correct_answer is a value — find its key
            for key, value in options.items():
                if normalize_text(str(correct)) == normalize_text(value):
                    correct_key = key
                    break

        return ("correct", 1.0) if selected_key == correct_key else ("incorrect", 0.0)

    async def _llm_evaluate(
        self,
        user_answer: str,
        correct_answer: str,
        question_text: str,
        alternative_answers: list[str] | None = None,
    ) -> str:
        """Use LLM for nuanced answer evaluation.

        Args:
            user_answer: User's answer
            correct_answer: Correct answer
            question_text: Question text
            alternative_answers: Accepted alternative phrasings of the answer

        Returns:
            Result: correct | partially_correct | partially_incorrect | incorrect
        """
        alternatives_line = ""
        if alternative_answers:
            alternatives_line = (
                "Also Accepted Answers: " + " | ".join(alternative_answers) + "\n"
            )

        eval_prompt = f"""You are a fair quiz answer evaluator for a voice quiz played in a car. Compare the user's answer to the correct answer.

The user's answer is a speech-to-text transcript of the player talking in a moving car. The recogniser is set to the language of the quiz, so it makes predictable mistakes: foreign words and names come back respelled the way they sound in that language, or as a similar-sounding real word or brand name (e.g. "Carling" or "Karling" for "curling"), and road noise can swap or drop a sound.

Question: {question_text}
Correct Answer: {correct_answer}
{alternatives_line}User's Answer (voice transcript): {user_answer}

Rules:
- "correct": The answer captures the key concept correctly. Accept:
  - Valid paraphrases that express the same fact in different words (e.g., "his parachute didn't open" for "His parachute failed to open", "it goes faster than sound" for "It breaks the sound barrier")
  - Anything matching one of the Also Accepted Answers, if listed
  - Shorter forms that contain the essential element (e.g., "sequoia" for "giant sequoia", "carbon" for "carbon dioxide")
  - Common abbreviations (NYC for New York City, WW2 for World War II)
  - Minor spelling errors that don't change the meaning
  - Transcripts that SOUND like the correct answer when read aloud, even when spelled differently or when they happen to spell a different real word or brand (e.g., "Carling" for "curling", "Šekspír" for "Shakespeare", "Njuton" for "Newton")
  - More specific correct answers (e.g., "carbon dioxide" when answer is "carbon")
- Never accept a sound-alike that names a different answer that would itself be a plausible answer to this question (e.g., "Manet" when the answer is "Monet", "Austria" for "Australia", "Iraq" for "Iran"). Numbers, years and ordinals must be the same number, whether spoken as words or digits ("Henry VII" is not "Henry VIII").
- "partially_correct": Has the right general idea but missing important qualifiers or has minor factual errors
- "partially_incorrect": Mentions something related but is mostly wrong
- "incorrect": Completely wrong, unrelated, or nonsensical answer

The key principle: judge what the player most likely SAID, not how it was spelled. If the user clearly knows the answer, mark it correct; when the only doubt comes from the transcription, give the player the benefit of the doubt.
If they're in the right ballpark but not quite there, mark it partially_correct.

Respond with EXACTLY one of these words: correct, partially_correct, partially_incorrect, incorrect"""

        response = await self.client.chat.completions.create(
            model=self.model,
            temperature=self.temperature,
            messages=[
                {
                    "role": "system",
                    "content": "You are a fair quiz evaluator for a voice quiz. Accept answers that demonstrate the user knows the correct information, judging speech transcripts by how they sound.",
                },
                {"role": "user", "content": eval_prompt},
            ],
        )

        result_text = response.choices[0].message.content.lower().strip()

        # Parse result with exact matches first
        if result_text == "correct":
            return "correct"
        elif result_text == "partially_correct":
            return "partially_correct"
        elif result_text == "partially_incorrect":
            return "partially_incorrect"
        elif result_text == "incorrect":
            return "incorrect"

        # Fallback parsing on word boundaries, negative verdicts first:
        # "incorrect" contains "correct", so a plain substring match would
        # score a rejected answer ("Incorrect.") as full credit.
        for pattern, verdict in (
            (r"\bpartially[ _]incorrect\b", "partially_incorrect"),
            (r"\bpartially[ _]correct\b", "partially_correct"),
            (r"\bincorrect\b", "incorrect"),
            (r"\bcorrect\b", "correct"),
        ):
            if re.search(pattern, result_text):
                return verdict

        # Default to incorrect if unclear
        return "incorrect"
