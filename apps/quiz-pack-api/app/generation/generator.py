"""Question generation service.

Ported from graph.py:359-442 with batch generation support.
"""

import json
import uuid
from typing import List, Optional
from langchain_openai import ChatOpenAI
from langchain_core.messages import HumanMessage

from quiz_shared.models.question import Question
from .prompt_builder import PromptBuilder


class QuestionGenerator:
    """Generates quiz questions using LLM."""

    def __init__(
        self,
        model: str = "gpt-4o-mini",
        temperature: float = 0.7,
        prompt_builder: Optional[PromptBuilder] = None
    ):
        """Initialize question generator.

        Args:
            model: OpenAI model to use
            temperature: Temperature for generation (0.7 for creative)
            prompt_builder: Custom prompt builder (or use default)
        """
        self.llm = ChatOpenAI(model=model, temperature=temperature)
        self.prompt_builder = prompt_builder or PromptBuilder()

    async def generate_questions(
        self,
        count: int = 10,
        difficulty: str = "medium",
        topics: Optional[List[str]] = None,
        categories: Optional[List[str]] = None,
        question_type: str = "text",
        excluded_topics: Optional[List[str]] = None,
        avoid_questions: Optional[List[str]] = None,
        user_bad_examples: Optional[List[str]] = None,
    ) -> List[Question]:
        """Generate batch of quiz questions.

        Args:
            count: Number of questions to generate
            difficulty: easy, medium, or hard
            topics: Preferred topics
            categories: Question categories
            question_type: text or text_multichoice
            excluded_topics: Topics to avoid
            avoid_questions: Previously asked questions to avoid
            user_bad_examples: Questions users rated poorly

        Returns:
            List of Question objects

        Example:
            >>> generator = QuestionGenerator()
            >>> questions = await generator.generate_questions(
            ...     count=10,
            ...     difficulty="medium",
            ...     topics=["science", "history"],
            ...     categories=["adults"]
            ... )
        """
        # Build prompt
        prompt = self.prompt_builder.build_prompt(
            count=count,
            difficulty=difficulty,
            topics=topics,
            categories=categories,
            question_type=question_type,
            excluded_topics=excluded_topics,
            avoid_questions=avoid_questions,
            user_bad_examples=user_bad_examples
        )

        # Call LLM
        response = await self.llm.ainvoke([
            HumanMessage(content=prompt)
        ])

        # Parse JSON response
        questions = self._parse_response(
            response.content,
            default_difficulty=difficulty,
            default_category=categories[0] if categories else "general"
        )

        return questions

    def _parse_response(
        self,
        content: str,
        default_difficulty: str = "medium",
        default_category: str = "general"
    ) -> List[Question]:
        """Parse LLM response into Question objects.

        Args:
            content: LLM response content
            default_difficulty: Default difficulty if not in response
            default_category: Default category if not in response

        Returns:
            List of Question objects
        """
        questions = []

        try:
            # Extract JSON from response (LLM might include extra text)
            start = content.find('{')
            end = content.rfind('}') + 1

            if start == -1 or end <= start:
                print(f"No JSON found in response: {content[:200]}...")
                return []

            json_str = content[start:end]
            data = json.loads(json_str)

            # Handle both single question and batch responses
            if "questions" in data:
                questions_data = data["questions"]
            elif "question" in data:
                # Single question format
                questions_data = [data]
            else:
                print(f"Unexpected JSON structure: {data}")
                return []

            # Convert each question to Question object
            for q_data in questions_data:
                try:
                    question = Question.from_dict(
                        q_data,
                        default_difficulty=default_difficulty,
                        default_category=default_category,
                    )
                    questions.append(question)
                except Exception as e:
                    print(f"Error parsing question: {e}")
                    continue

        except json.JSONDecodeError as e:
            print(f"JSON decode error: {e}")
            print(f"Content: {content[:500]}...")
        except Exception as e:
            print(f"Error parsing response: {e}")

        return questions

    def export_for_chatgpt(
        self,
        count: int = 10,
        difficulty: str = "medium",
        topics: Optional[List[str]] = None,
        categories: Optional[List[str]] = None,
        question_type: str = "text",
    ) -> str:
        """Export prompt for manual ChatGPT usage.

        Args:
            count: Number of questions
            difficulty: Difficulty level
            topics: Topics
            categories: Categories
            question_type: Question type

        Returns:
            Prompt string ready to copy-paste to ChatGPT
        """
        return self.prompt_builder.build_for_chatgpt(
            count=count,
            difficulty=difficulty,
            topics=topics,
            categories=categories,
            question_type=question_type
        )
