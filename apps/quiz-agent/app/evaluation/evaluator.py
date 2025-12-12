"""Answer evaluation with nuanced scoring.

Ported from graph.py:445-518
"""

from typing import Tuple
from langchain_openai import ChatOpenAI
from langchain_core.messages import HumanMessage, SystemMessage

import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "../../../..", "packages/shared"))

from quiz_shared.models.question import Question
from quiz_shared.utils.text_normalization import normalize_text


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
        self.llm = ChatOpenAI(model=model, temperature=temperature)

    async def evaluate(
        self,
        user_answer: str,
        question: Question,
        question_text: str = ""
    ) -> Tuple[str, float]:
        """Evaluate user's answer against correct answer.

        Args:
            user_answer: User's answer
            question: Question object with correct answer
            question_text: Question text for context

        Returns:
            Tuple of (result, score_delta)
            - result: "correct" | "partially_correct" | "partially_incorrect" | "incorrect" | "skipped"
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

        # Fast path: Normalized exact match
        if normalize_text(user_answer) == normalize_text(str(correct_answer)):
            return "correct", 1.0

        # Check alternative answers
        for alt in question.alternative_answers:
            if normalize_text(user_answer) == normalize_text(alt):
                return "correct", 1.0

        # LLM evaluation for nuanced scoring
        result = await self._llm_evaluate(
            user_answer=user_answer,
            correct_answer=str(correct_answer),
            question_text=question_text or question.question
        )

        # Map result to score delta
        score_map = {
            "correct": 1.0,
            "partially_correct": 0.5,
            "partially_incorrect": 0.25,
            "incorrect": 0.0
        }

        return result, score_map.get(result, 0.0)

    async def _llm_evaluate(
        self,
        user_answer: str,
        correct_answer: str,
        question_text: str
    ) -> str:
        """Use LLM for nuanced answer evaluation.

        Args:
            user_answer: User's answer
            correct_answer: Correct answer
            question_text: Question text

        Returns:
            Result: correct | partially_correct | partially_incorrect | incorrect
        """
        eval_prompt = f"""You are a fair quiz answer evaluator. Compare the user's answer to the correct answer.

Question: {question_text}
Correct Answer: {correct_answer}
User's Answer: {user_answer}

Rules:
- "correct": The answer captures the key concept correctly. Accept:
  - Shorter forms that contain the essential element (e.g., "sequoia" for "giant sequoia", "carbon" for "carbon dioxide")
  - Common abbreviations (NYC for New York City, WW2 for World War II)
  - Minor spelling errors that don't change the meaning
  - More specific correct answers (e.g., "carbon dioxide" when answer is "carbon")
- "partially_correct": Has the right general idea but missing important qualifiers or has minor factual errors
- "partially_incorrect": Mentions something related but is mostly wrong
- "incorrect": Completely wrong, unrelated, or nonsensical answer

The key principle: if the user clearly knows the answer, mark it correct.
If they're in the right ballpark but not quite there, mark it partially_correct.

Respond with EXACTLY one of these words: correct, partially_correct, partially_incorrect, incorrect"""

        response = await self.llm.ainvoke([
            SystemMessage(content="You are a fair quiz evaluator. Accept answers that demonstrate the user knows the correct information."),
            HumanMessage(content=eval_prompt)
        ])

        result_text = response.content.lower().strip()

        # Parse result with exact matches first
        if result_text == "correct":
            return "correct"
        elif result_text == "partially_correct":
            return "partially_correct"
        elif result_text == "partially_incorrect":
            return "partially_incorrect"
        elif result_text == "incorrect":
            return "incorrect"

        # Fallback parsing
        if "partially_correct" in result_text:
            return "partially_correct"
        elif "partially_incorrect" in result_text:
            return "partially_incorrect"
        elif "correct" in result_text:
            return "correct"
        elif "incorrect" in result_text:
            return "incorrect"

        # Default to incorrect if unclear
        return "incorrect"
