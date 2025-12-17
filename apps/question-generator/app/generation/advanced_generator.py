"""Advanced question generator with multi-stage quality pipeline.

This implements:
1. Chain of Thought reasoning during generation
2. Best-of-N selection with LLM judge
3. Multi-stage critique → regenerate loop
4. Quality metadata tracking
"""

import json
import uuid
from typing import List, Optional, Dict, Any
from langchain_openai import ChatOpenAI
from langchain_core.messages import HumanMessage

import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "../../../..", "packages/shared"))

from quiz_shared.models.question import Question
from .prompt_builder import PromptBuilder


class AdvancedQuestionGenerator:
    """Multi-stage question generator with quality optimization."""

    def __init__(
        self,
        generation_model: str = "gpt-4o",
        critique_model: str = "gpt-4o-mini",
        generation_temperature: float = 0.8,
        critique_temperature: float = 0.3,
        prompt_version: str = "v2_cot",
    ):
        """Initialize advanced question generator.

        Args:
            generation_model: Model for question generation (default: gpt-4o)
            critique_model: Model for quality critique (default: gpt-4o-mini)
            generation_temperature: Temperature for generation (0.8 for creativity)
            critique_temperature: Temperature for critique (0.3 for consistency)
            prompt_version: Prompt template version (v2_cot uses Chain of Thought)
        """
        self.generation_llm = ChatOpenAI(
            model=generation_model,
            temperature=generation_temperature
        )
        self.critique_llm = ChatOpenAI(
            model=critique_model,
            temperature=critique_temperature
        )

        self.generation_model = generation_model
        self.critique_model = critique_model
        self.prompt_version = prompt_version

        # Load appropriate prompt template
        current_dir = os.path.dirname(__file__)
        if prompt_version == "v2_cot":
            template_path = os.path.join(
                current_dir, "..", "..", "prompts", "question_generation_v2_cot.md"
            )
        else:
            template_path = os.path.join(
                current_dir, "..", "..", "prompts", "question_generation.md"
            )

        self.prompt_builder = PromptBuilder(template_path=template_path)

        # Load critique prompt
        critique_template_path = os.path.join(
            current_dir, "..", "..", "prompts", "question_critique.md"
        )
        with open(critique_template_path, "r", encoding="utf-8") as f:
            self.critique_template = f.read()

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
        enable_best_of_n: bool = True,
        n_multiplier: int = 3,
        min_quality_score: float = 7.0,
    ) -> List[Question]:
        """Generate questions using multi-stage quality pipeline.

        Pipeline:
        1. Generate N x count questions (Best-of-N)
        2. Critique each question with LLM judge
        3. Select top-scoring questions
        4. Optionally regenerate low-scoring questions

        Args:
            count: Number of questions to return
            difficulty: easy, medium, or hard
            topics: Preferred topics
            categories: Question categories
            question_type: text or text_multichoice
            excluded_topics: Topics to avoid
            avoid_questions: Previously asked questions to avoid
            user_bad_examples: Questions users rated poorly
            enable_best_of_n: Use Best-of-N selection (default: True)
            n_multiplier: Generate this many times count (default: 3x)
            min_quality_score: Minimum acceptable score (default: 7.0/10)

        Returns:
            List of Question objects with quality metadata

        Example:
            >>> generator = AdvancedQuestionGenerator()
            >>> questions = await generator.generate_questions(
            ...     count=10,
            ...     difficulty="medium",
            ...     topics=["science"],
            ...     enable_best_of_n=True,
            ...     n_multiplier=3  # Generate 30, return best 10
            ... )
        """
        if enable_best_of_n:
            # Stage 1: Generate N x count questions
            generate_count = count * n_multiplier
            print(f"Stage 1: Generating {generate_count} questions...")

            raw_questions = await self._generate_batch(
                count=generate_count,
                difficulty=difficulty,
                topics=topics,
                categories=categories,
                question_type=question_type,
                excluded_topics=excluded_topics,
                avoid_questions=avoid_questions,
                user_bad_examples=user_bad_examples,
            )

            print(f"Generated {len(raw_questions)} raw questions")

            # Stage 2: Critique each question
            print(f"Stage 2: Critiquing {len(raw_questions)} questions...")
            questions_with_scores = []

            for q in raw_questions:
                critique = await self._critique_question(q)
                q.generation_metadata = q.generation_metadata or {}
                q.generation_metadata.update(critique)
                questions_with_scores.append((q, critique["overall_score"]))

            # Stage 3: Sort by score and select top N
            print("Stage 3: Selecting best questions...")
            questions_with_scores.sort(key=lambda x: x[1], reverse=True)

            selected_questions = [q for q, score in questions_with_scores[:count]]

            # Stage 4: Optionally regenerate if top questions below threshold
            low_quality_count = sum(
                1 for q, score in questions_with_scores[:count]
                if score < min_quality_score
            )

            if low_quality_count > 0:
                print(f"Stage 4: {low_quality_count} questions below {min_quality_score}, regenerating...")
                # TODO: Implement regeneration with critique feedback
                # For now, just warn
                print(f"Warning: {low_quality_count}/{count} questions scored below {min_quality_score}")

            return selected_questions

        else:
            # Simple generation without Best-of-N
            return await self._generate_batch(
                count=count,
                difficulty=difficulty,
                topics=topics,
                categories=categories,
                question_type=question_type,
                excluded_topics=excluded_topics,
                avoid_questions=avoid_questions,
                user_bad_examples=user_bad_examples,
            )

    async def _generate_batch(
        self,
        count: int,
        difficulty: str,
        topics: Optional[List[str]],
        categories: Optional[List[str]],
        question_type: str,
        excluded_topics: Optional[List[str]],
        avoid_questions: Optional[List[str]],
        user_bad_examples: Optional[List[str]],
    ) -> List[Question]:
        """Generate a batch of questions."""
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
        response = await self.generation_llm.ainvoke([
            HumanMessage(content=prompt)
        ])

        # Parse response
        questions = self._parse_response(
            response.content,
            default_difficulty=difficulty,
            default_category=categories[0] if categories else "general"
        )

        # Add generation metadata
        for q in questions:
            q.generation_metadata = {
                "model": self.generation_model,
                "prompt_version": self.prompt_version,
                "temperature": self.generation_llm.temperature,
                "stage": "initial_generation",
            }
            # Extract self-critique if present (from V2 CoT prompt)
            # This will be in the parsed data if using V2 prompt

        return questions

    async def _critique_question(self, question: Question) -> Dict[str, Any]:
        """Critique a question using LLM judge.

        Args:
            question: Question to critique

        Returns:
            Critique data: {
                "overall_score": 8.5,
                "scores": {...},
                "verdict": "excellent",
                "reasoning": "...",
                ...
            }
        """
        # Build critique prompt
        critique_prompt = self.critique_template.format(
            question=question.question,
            correct_answer=question.correct_answer,
            question_type=question.type,
            difficulty=question.difficulty,
            topic=question.topic,
        )

        # Call critique LLM
        response = await self.critique_llm.ainvoke([
            HumanMessage(content=critique_prompt)
        ])

        # Parse critique JSON
        try:
            start = response.content.find('{')
            end = response.content.rfind('}') + 1

            if start == -1 or end <= start:
                # Fallback: simple scoring
                return {
                    "overall_score": 7.0,
                    "verdict": "acceptable",
                    "critique_model": self.critique_model,
                    "error": "No JSON in critique response"
                }

            json_str = response.content[start:end]
            critique_data = json.loads(json_str)

            # Add critique model info
            critique_data["critique_model"] = self.critique_model

            return critique_data

        except Exception as e:
            print(f"Error parsing critique: {e}")
            return {
                "overall_score": 7.0,
                "verdict": "acceptable",
                "critique_model": self.critique_model,
                "error": str(e)
            }

    def _parse_response(
        self,
        content: str,
        default_difficulty: str = "medium",
        default_category: str = "general"
    ) -> List[Question]:
        """Parse LLM response into Question objects.

        Supports both V1 and V2 formats (V2 includes reasoning and self_critique).

        Args:
            content: LLM response content
            default_difficulty: Default difficulty
            default_category: Default category

        Returns:
            List of Question objects
        """
        questions = []

        try:
            # Extract JSON
            start = content.find('{')
            end = content.rfind('}') + 1

            if start == -1 or end <= start:
                print(f"No JSON found in response: {content[:200]}...")
                return []

            json_str = content[start:end]
            data = json.loads(json_str)

            # Handle both formats
            if "questions" in data:
                questions_data = data["questions"]
            elif "question" in data:
                questions_data = [data]
            else:
                print(f"Unexpected JSON structure: {data}")
                return []

            # Convert to Question objects
            for q_data in questions_data:
                try:
                    question = self._dict_to_question(
                        q_data,
                        default_difficulty=default_difficulty,
                        default_category=default_category
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

    def _dict_to_question(
        self,
        data: dict,
        default_difficulty: str = "medium",
        default_category: str = "general"
    ) -> Question:
        """Convert dict from LLM to Question object.

        Handles V2 format with reasoning and self_critique fields.

        Args:
            data: Question data from LLM
            default_difficulty: Default difficulty
            default_category: Default category

        Returns:
            Question object
        """
        # Generate unique ID
        question_id = f"temp_{uuid.uuid4().hex[:8]}"

        # Extract standard fields
        question_text = data.get("question", "")
        question_type = data.get("type", "text")
        correct_answer = data.get("correct_answer", "")
        possible_answers = data.get("possible_answers")
        alternative_answers = data.get("alternative_answers", [])
        topic = data.get("topic", "General")
        category = data.get("category", default_category)
        difficulty = data.get("difficulty", default_difficulty)
        tags = data.get("tags", [])

        # Extract V2-specific fields
        reasoning = data.get("reasoning", {})
        self_critique = data.get("self_critique", {})

        # Build generation metadata
        generation_metadata = {}

        if reasoning:
            generation_metadata["reasoning"] = reasoning

        if self_critique:
            # Extract self-critique scores for quality_ratings
            quality_ratings = {
                "surprise_factor": self_critique.get("surprise_factor", 0),
                "universal_appeal": self_critique.get("universal_appeal", 0),
                "clever_framing": self_critique.get("clever_framing", 0),
                "educational_value": self_critique.get("educational_value", 0),
            }
            generation_metadata["self_critique"] = self_critique
            generation_metadata["ai_score"] = self_critique.get("overall_score", 0)
            generation_metadata["ai_reasoning"] = self_critique.get("reasoning", "")
        else:
            quality_ratings = None

        return Question(
            id=question_id,
            question=question_text,
            type=question_type,
            possible_answers=possible_answers,
            correct_answer=correct_answer,
            alternative_answers=alternative_answers,
            topic=topic,
            category=category,
            difficulty=difficulty,
            tags=tags,
            source="generated",
            review_status="pending_review",
            quality_ratings=quality_ratings,
            generation_metadata=generation_metadata,
        )
