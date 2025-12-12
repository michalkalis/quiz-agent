"""Dynamic prompt builder for question generation."""

import os
from typing import List, Optional

from .examples import EXCELLENT_EXAMPLES, OK_EXAMPLES, BAD_EXAMPLES_TEMPLATE


class PromptBuilder:
    """Builds question generation prompts with dynamic examples."""

    def __init__(self, template_path: Optional[str] = None):
        """Initialize prompt builder.

        Args:
            template_path: Path to prompt template file
        """
        if template_path is None:
            # Default to prompts/question_generation.md relative to this file
            current_dir = os.path.dirname(__file__)
            template_path = os.path.join(
                current_dir, "..", "..", "prompts", "question_generation.md"
            )

        self.template_path = template_path
        self.template = self._load_template()

    def _load_template(self) -> str:
        """Load prompt template from file."""
        with open(self.template_path, "r", encoding="utf-8") as f:
            return f.read()

    def build_prompt(
        self,
        count: int = 10,
        difficulty: str = "medium",
        topics: Optional[List[str]] = None,
        categories: Optional[List[str]] = None,
        question_type: str = "text",
        excluded_topics: Optional[List[str]] = None,
        avoid_questions: Optional[List[str]] = None,
        user_bad_examples: Optional[List[str]] = None,
        excellent_examples: Optional[str] = None,
        ok_examples: Optional[str] = None,
    ) -> str:
        """Build complete prompt with all variables filled.

        Args:
            count: Number of questions to generate
            difficulty: easy, medium, or hard
            topics: List of preferred topics
            categories: List of categories (adults, children, etc.)
            question_type: text or text_multichoice
            excluded_topics: Topics to avoid
            avoid_questions: Previously asked questions to avoid
            user_bad_examples: Questions users rated poorly
            excellent_examples: Custom excellent examples (or use defaults)
            ok_examples: Custom OK examples (or use defaults)

        Returns:
            Complete prompt ready for LLM
        """
        # Use defaults if not provided
        if excellent_examples is None:
            excellent_examples = EXCELLENT_EXAMPLES

        if ok_examples is None:
            ok_examples = OK_EXAMPLES

        # Build topic section
        topic_section = ""
        if topics:
            topic_section = f"\n\n**Preferred Topics:** {', '.join(topics)}"
        if excluded_topics:
            topic_section += f"\n**Avoid Topics:** {', '.join(excluded_topics)}"

        # Build avoid section (previously asked questions)
        avoid_section = ""
        if avoid_questions:
            avoid_section = "\n\n**Do NOT repeat or rephrase these questions:**\n"
            for q in avoid_questions[:10]:  # Limit to 10 to keep prompt reasonable
                avoid_section += f"- {q}\n"

        # Build user feedback section (bad examples from users)
        bad_examples_section = ""
        if user_bad_examples:
            examples_text = "\n".join(f"- {q}" for q in user_bad_examples[:10])
            bad_examples_section = BAD_EXAMPLES_TEMPLATE.format(
                user_bad_examples=examples_text
            )

        # Format main template
        prompt = self.template.format(
            excellent_examples=excellent_examples,
            ok_examples=ok_examples,
            bad_examples_section=bad_examples_section,
            count=count,
            difficulty=difficulty,
            topics=", ".join(topics) if topics else "any",
            categories=", ".join(categories) if categories else "general",
            type=question_type,
            topic_section=topic_section,
            avoid_section=avoid_section,
            user_feedback_section=""  # Reserved for future use
        )

        return prompt

    def build_for_chatgpt(
        self,
        count: int = 10,
        difficulty: str = "medium",
        topics: Optional[List[str]] = None,
        categories: Optional[List[str]] = None,
        question_type: str = "text",
    ) -> str:
        """Build prompt optimized for manual ChatGPT usage.

        Args:
            count: Number of questions to generate
            difficulty: easy, medium, or hard
            topics: List of preferred topics
            categories: List of categories
            question_type: text or text_multichoice

        Returns:
            Prompt formatted for copy-paste to ChatGPT UI
        """
        prompt = self.build_prompt(
            count=count,
            difficulty=difficulty,
            topics=topics,
            categories=categories,
            question_type=question_type
        )

        # Add ChatGPT-specific instructions
        chatgpt_header = f"""
# COPY THIS ENTIRE PROMPT TO CHATGPT

Please generate {count} {difficulty} difficulty quiz questions following the guidelines below.

---
"""

        chatgpt_footer = """
---

Remember to respond ONLY with valid JSON in the format specified above. Do not include any additional text or explanations outside the JSON structure.
"""

        return chatgpt_header + prompt + chatgpt_footer
