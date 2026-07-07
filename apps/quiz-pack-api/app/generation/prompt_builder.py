"""Dynamic prompt builder for question generation."""

import os
from typing import List, Optional

from .examples import OK_EXAMPLES, BAD_EXAMPLES_TEMPLATE, load_gold_standard, load_anti_patterns


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
        **kwargs,
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
            **kwargs: Extra template variables (e.g., facts_section for V3 prompt)

        Returns:
            Complete prompt ready for LLM
        """
        # Use dynamic sampling from gold-standard library (falls back to hardcoded)
        if excellent_examples is None:
            excellent_examples = load_gold_standard(
                n=5,
                topics=topics,
                difficulty=difficulty,
                question_type=question_type,
            )

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

        # Build user feedback section (bad examples from users + anti-patterns)
        bad_examples_section = ""
        anti_pattern_text = load_anti_patterns(n=5)
        if anti_pattern_text:
            bad_examples_section = f"\n## Auto-Selected Anti-Patterns (Avoid these!)\n\n{anti_pattern_text}\n"
        if user_bad_examples:
            examples_text = "\n".join(f"- {q}" for q in user_bad_examples[:10])
            bad_examples_section += BAD_EXAMPLES_TEMPLATE.format(
                user_bad_examples=examples_text
            )

        # Build format variables dict
        format_vars = {
            "excellent_examples": excellent_examples,
            "ok_examples": ok_examples,
            "bad_examples_section": bad_examples_section,
            "count": count,
            "difficulty": difficulty,
            "topics": ", ".join(topics) if topics else "any",
            "categories": ", ".join(categories) if categories else "general",
            "type": question_type,
            "topic_section": topic_section,
            "avoid_section": avoid_section,
            "user_feedback_section": "",  # Reserved for future use
            # Issue #42 task 42.9b — empty default so v2/v3 prompts can carry
            # `{mcq_patterns_section}` unconditionally; the caller fills it
            # via **kwargs when `mcq_patterns` is configured.
            "mcq_patterns_section": "",
            # Issue #72 P2.2 — empty default so the v3 prompt can carry
            # `{escape_hatch_section}` unconditionally; the caller fills it
            # via **kwargs only when the `V3_ESCAPE_HATCH` flag is on. Empty
            # default keeps flag-off output byte-identical to today.
            "escape_hatch_section": "",
        }

        # Merge any extra template variables (e.g., facts_section for V3)
        format_vars.update(kwargs)

        # Format main template
        prompt = self.template.format(**format_vars)

        return prompt

