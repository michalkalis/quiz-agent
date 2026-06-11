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

import os

from quiz_shared.models.question import GenerationProvenance, Question
from .prompt_builder import PromptBuilder
from .pattern_routing import verification_mode

try:
    from ..sourcing.models import Fact
except ImportError:
    Fact = None  # sourcing package not installed


class AdvancedQuestionGenerator:
    """Multi-stage question generator with quality optimization."""

    def __init__(
        self,
        generation_model: str = "gpt-4o",
        critique_model: str = "gpt-4o-mini",
        generation_temperature: float = 0.8,
        critique_temperature: float = 0.3,
        prompt_version: str = "v2_cot",
        verbose: bool = False,
    ):
        """Initialize advanced question generator.

        Args:
            generation_model: Model for question generation (default: gpt-4o)
            critique_model: Model for quality critique (default: gpt-4o-mini)
            generation_temperature: Temperature for generation (0.8 for creativity)
            critique_temperature: Temperature for critique (0.3 for consistency)
            prompt_version: Prompt template version (v2_cot uses Chain of Thought)
            verbose: Enable verbose logging of raw responses and parsed fields
        """
        self.verbose = verbose
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

        # Load V3 fact-first template (used when source_facts provided)
        v3_template_path = os.path.join(
            current_dir, "..", "..", "prompts", "question_generation_v3_fact_first.md"
        )
        self.v3_prompt_builder = None
        if os.path.exists(v3_template_path):
            self.v3_prompt_builder = PromptBuilder(template_path=v3_template_path)

        # Issue #46 task 46.B4b — open/logical branch template. Open-shape
        # questions (mechanism + lateral puzzles) are generated through this
        # prompt so they emit the two-field `headline_answer` + `explanation`
        # contract (46.B3); pure puzzles are tagged `pipeline="logical_puzzle"`.
        open_template_path = os.path.join(
            current_dir, "..", "..", "prompts", "question_generation_open.md"
        )
        self.open_prompt_builder = None
        if os.path.exists(open_template_path):
            self.open_prompt_builder = PromptBuilder(template_path=open_template_path)

        # Load critique prompt (prefer V2 calibrated version)
        critique_v2_path = os.path.join(
            current_dir, "..", "..", "prompts", "question_critique_v2.md"
        )
        critique_v1_path = os.path.join(
            current_dir, "..", "..", "prompts", "question_critique.md"
        )
        critique_template_path = critique_v2_path if os.path.exists(critique_v2_path) else critique_v1_path
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
        source_facts: Optional[list] = None,
        mcq_patterns: Optional[set[str]] = None,
        mcq_emphasis: bool = False,
        open_count: int = 0,
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
            source_facts: Optional list of Fact objects for fact-first generation.
                When provided, uses V3 fact-first prompt template instead of V2.
            mcq_patterns: Optional set of reasoning-pattern keys (e.g.
                ``{"true_false", "odd_one_out"}``) for which the LLM must emit
                ``possible_answers`` + a key-letter ``correct_answer``. Routes
                via the ``{mcq_patterns_section}`` prompt placeholder; the
                per-question ``Question.type`` is set later by
                ``GenerationStage`` (#42 task 42.9a) based on the pattern the
                LLM ended up choosing.
            mcq_emphasis: When True (an MCQ-biased order, #42 task 42.20),
                the ``{mcq_patterns_section}`` carries a hard quota — at
                least 7 of every 10 questions must use an MCQ pattern — and
                exempts those patterns from the diversity rule's cap. The
                order prompt never reaches the generation LLM, so this bool
                is the only channel for the emphasis.

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
        # Issue #46 task 46.B4b — generate the open-shape slice through the
        # dedicated open/logical prompt (two-field `headline_answer` +
        # `explanation` contract, 46.B3). Best-of-N / critique stays on the
        # closed slice; the open slice is generated directly so the sentence
        # answer survives the critique judge unchanged.
        open_questions: List[Question] = []
        if open_count > 0:
            print(f"Generating {open_count} open-shape questions...")
            open_questions = await self._generate_batch(
                count=open_count,
                difficulty=difficulty,
                topics=topics,
                categories=categories,
                question_type=question_type,
                excluded_topics=excluded_topics,
                avoid_questions=avoid_questions,
                user_bad_examples=user_bad_examples,
                open_shape=True,
            )
            count = max(0, count - open_count)
        if count == 0:
            return open_questions

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
                source_facts=source_facts,
                mcq_patterns=mcq_patterns,
                mcq_emphasis=mcq_emphasis,
            )

            print(f"Generated {len(raw_questions)} raw questions")

            # Stage 2: Critique each question
            print(f"Stage 2: Critiquing {len(raw_questions)} questions...")
            questions_with_scores = []

            for q in raw_questions:
                critique = await self._critique_question(q)
                provenance = q.generation_metadata or GenerationProvenance()
                merged_extra = dict(provenance.extra)
                merged_extra.update(critique)
                q.generation_metadata = provenance.model_copy(update={
                    "critique_model": self.critique_model,
                    "critique_score": critique.get("overall_score"),
                    "extra": merged_extra,
                })
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

            return open_questions + selected_questions

        else:
            # Simple generation without Best-of-N
            closed_questions = await self._generate_batch(
                count=count,
                difficulty=difficulty,
                topics=topics,
                categories=categories,
                question_type=question_type,
                excluded_topics=excluded_topics,
                avoid_questions=avoid_questions,
                user_bad_examples=user_bad_examples,
                source_facts=source_facts,
                mcq_patterns=mcq_patterns,
                mcq_emphasis=mcq_emphasis,
            )
            return open_questions + closed_questions

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
        source_facts: Optional[list] = None,
        mcq_patterns: Optional[set[str]] = None,
        mcq_emphasis: bool = False,
        open_shape: bool = False,
    ) -> List[Question]:
        """Generate a batch of questions.

        Args:
            source_facts: Optional list of Fact objects. When provided,
                uses V3 fact-first prompt template with facts injected.
            mcq_patterns: Reasoning-pattern keys that must emit MCQ payloads.
                Rendered into ``{mcq_patterns_section}`` of the prompt; the
                LLM is told to set ``reasoning.pattern_used`` to one of the
                snake_case keys and emit ``possible_answers`` + key-letter
                ``correct_answer`` when it picks one.
        """
        # Determine which prompt builder and version to use. The open/logical
        # branch (46.B4b) takes precedence and never uses source_facts — open
        # questions are generated from the dedicated prompt, not fact-first.
        use_open = open_shape and self.open_prompt_builder is not None
        use_fact_first = (
            not use_open and source_facts and self.v3_prompt_builder is not None
        )
        if use_open:
            prompt_builder = self.open_prompt_builder
            prompt_version = "open"
        elif use_fact_first:
            prompt_builder = self.v3_prompt_builder
            prompt_version = "v3_fact_first"
        else:
            prompt_builder = self.prompt_builder
            prompt_version = self.prompt_version

        # Build the facts section for V3 prompt
        extra_kwargs = {}
        if use_fact_first:
            facts_section = self._format_facts_section(source_facts)
            extra_kwargs["facts_section"] = facts_section

        # Issue #42 task 42.9b — render MCQ activation rules into the prompt.
        # Empty section when no MCQ patterns are configured so the prompt
        # reads cleanly for non-MCQ runs (and back-compat with callers that
        # haven't been wired through yet, e.g. ad-hoc scripts).
        extra_kwargs["mcq_patterns_section"] = self._format_mcq_patterns_section(
            mcq_patterns, mcq_emphasis=mcq_emphasis
        )

        # Build prompt
        prompt = prompt_builder.build_prompt(
            count=count,
            difficulty=difficulty,
            topics=topics,
            categories=categories,
            question_type=question_type,
            excluded_topics=excluded_topics,
            avoid_questions=avoid_questions,
            user_bad_examples=user_bad_examples,
            **extra_kwargs,
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
            # Issue #42 task 42.9b — preserve LLM-emitted `pattern_used` so
            # the post-generation type-tagging step in `GenerationStage`
            # (42.9a) can route the question via `PATTERNS_TO_MCQ`. The
            # `_parse_response` → `Question.from_dict` path lands the
            # parsed `reasoning` dict under `generation_metadata.extra`
            # (via GenerationProvenance._absorb_unknown_keys); we lift
            # `pattern_used` into the typed `reasoning_pattern` slot here.
            pattern_used = self._extract_pattern_used(q.generation_metadata)
            # Issue #46 task 46.B4b — tag pure lateral puzzles
            # `pipeline="logical_puzzle"` at generation time so F8's
            # source_url relaxation (46.B4a / D4) applies; open-mechanism
            # questions stay web-verifiable and keep no special pipeline.
            if use_open:
                pipeline = (
                    "logical_puzzle"
                    if verification_mode(pattern_used, q.question) == "logical"
                    else None
                )
            elif use_fact_first:
                pipeline = "fact_first"
            else:
                pipeline = None
            q.generation_metadata = GenerationProvenance(
                model=self.generation_model,
                provider="openai",
                prompt_version=prompt_version,
                generation_temperature=self.generation_llm.temperature,
                pipeline=pipeline,
                reasoning_pattern=pattern_used,
                extra={"stage": "initial_generation"},
            )
            # Extract self-critique if present (from V2/V3 CoT prompt)
            # This will be in the parsed data if using V2/V3 prompt

        # Dedup against gold standard to prevent verbatim copying
        questions = self._dedup_against_gold_standard(questions)

        # Warn if batch lacks structural diversity
        self._check_batch_diversity(questions)

        return questions

    @staticmethod
    def _strip_markdown_fences(content: str) -> str:
        """Remove ```json ... ``` wrappers that LLMs sometimes add around JSON."""
        content = content.strip()
        if content.startswith("```"):
            first_nl = content.find("\n")
            last_fence = content.rfind("```")
            if first_nl != -1 and last_fence > first_nl:
                content = content[first_nl + 1:last_fence].strip()
        return content

    @staticmethod
    def _jaccard_similarity(text_a: str, text_b: str) -> float:
        """Compute Jaccard word-overlap similarity between two texts."""
        words_a = set(text_a.lower().split())
        words_b = set(text_b.lower().split())
        if not words_a or not words_b:
            return 0.0
        intersection = len(words_a & words_b)
        union = len(words_a | words_b)
        return intersection / union if union else 0.0

    def _dedup_against_gold_standard(
        self, questions: List[Question], threshold: float = 0.80
    ) -> List[Question]:
        """Remove questions that are too similar to gold standard examples."""
        gold_path = os.path.join(
            os.path.dirname(__file__), "..", "..", "..", "..", "data", "examples", "gold_standard.json"
        )
        if not os.path.exists(gold_path):
            return questions

        with open(gold_path, "r", encoding="utf-8") as f:
            gold_examples = json.load(f)
        gold_texts = [ex.get("question", "") for ex in gold_examples]

        unique = []
        for q in questions:
            is_copy = False
            for gold_q in gold_texts:
                if self._jaccard_similarity(q.question, gold_q) > threshold:
                    print(f"  Dedup: removed near-copy of gold standard: {q.question[:60]}...")
                    is_copy = True
                    break
            if not is_copy:
                unique.append(q)
        return unique

    @staticmethod
    def _check_batch_diversity(questions: List[Question], threshold: float = 0.30) -> None:
        """Warn if more than threshold fraction of questions start with 'Which'."""
        if not questions:
            return
        which_count = sum(1 for q in questions if q.question.strip().startswith("Which"))
        ratio = which_count / len(questions)
        if ratio > threshold:
            print(
                f"  ⚠ Diversity warning: {which_count}/{len(questions)} "
                f"({ratio:.0%}) questions start with 'Which' (target: ≤{threshold:.0%})"
            )

    @staticmethod
    def _format_mcq_patterns_section(
        mcq_patterns: Optional[set[str]], mcq_emphasis: bool = False
    ) -> str:
        """Render the MCQ-activation block for `{mcq_patterns_section}`.

        Empty string when no patterns are configured so the prompt reads as
        if MCQ wasn't requested (the original non-MCQ behaviour). When
        patterns are present, we emit a single instruction block per
        pattern keyed by the exact snake_case label the routing helper
        (`pattern_routing.choose_question_type`) expects — drift between
        the two would silently downgrade MCQ output to free-form text.

        ``mcq_emphasis`` injects the hard MCQ quota (≥7 of every 10
        questions) plus an unconditional diversity-rule exemption directly
        into the section. The previous wording gated the exemption on "if
        the order prompt declares MULTIPLE-CHOICE EMPHASIS" — a condition
        the generation LLM can never observe, because the order prompt is
        not part of the generation prompt (#42 task 42.20 blocker, root
        cause D). Unbiased runs (the default) keep the diversity rule
        untouched.

        Issue #42 tasks 42.9b + 42.20 blocker fix.
        """
        if not mcq_patterns:
            return ""

        # Per-pattern emission contract. The keys MUST match
        # `PATTERNS_TO_MCQ`; the body tells the LLM what shape of
        # `possible_answers` and `correct_answer` to emit. Order is
        # deterministic so prompt caching stays warm across runs.
        recipes: dict[str, str] = {
            "true_false": (
                "frame the source fact as a single True/False claim "
                "(pick this directly — it is not numbered in the Pattern "
                "Library). Two options, e.g. "
                "`{\"a\": \"True\", \"b\": \"False\"}`, "
                "with `correct_answer` set to `\"a\"` or `\"b\"`."
            ),
            "odd_one_out": (
                "the MCQ form of Pattern Library #9 'The Odd One Out'. "
                "Four options labelled a/b/c/d, with `correct_answer` set to "
                "the key letter of the odd item. Put the reasoning in "
                "`explanation`."
            ),
            "comparison_bet_older_larger": (
                "the MCQ form of Pattern Library #12 'The Comparison Bet' "
                "(which is older / larger / heavier — A or B?). Two options "
                "A and B as `{\"a\": \"<option A>\", \"b\": \"<option B>\"}`, "
                "with `correct_answer` set to the key letter of the "
                "surprising winner."
            ),
            "year_guess": (
                "frame a date/era fact as 'in which year/decade?' (pick "
                "this directly — it is not numbered in the Pattern Library). "
                "Four plausible year/decade options labelled a/b/c/d, with "
                "`correct_answer` set to the key letter of the correct year."
            ),
        }

        lines = [
            "## Multiple-Choice Activation (pattern-driven)",
            "",
            "When you choose any of the patterns listed below, the question "
            "MUST be multiple-choice. You MUST:",
            "",
            "1. Set `reasoning.pattern_used` to the exact snake_case key "
            "(e.g. `true_false`, NOT `\"True/False Bet\"`).",
            "2. Set `type` to `text_multichoice`.",
            "3. Emit `possible_answers` per the shape described below.",
            "4. Set `correct_answer` to the key letter (`\"a\"`, `\"b\"`, …), "
            "not the value.",
            "",
            "**These patterns are selectable choices, not just the numbered "
            "Pattern Library.** `odd_one_out` and `comparison_bet_older_larger` "
            "are the MCQ forms of Library patterns 9 and 12; `true_false` and "
            "`year_guess` are MCQ patterns in their own right — choose them "
            "directly even though they are not numbered in the Library above, "
            "and emit `reasoning.pattern_used` as the exact snake_case key.",
            "",
            "**Distractor quality rule (all MCQ patterns):** every distractor "
            "must be plausible. NEVER include a throwaway wrong option, NEVER "
            "let one option give away the answer through length / specificity, "
            "NEVER include the correct answer as a substring of a distractor.",
            "",
        ]
        if mcq_emphasis:
            lines += [
                "**MULTIPLE-CHOICE EMPHASIS (this order):** at least 7 of "
                "every 10 questions in this batch MUST use one of the "
                "patterns listed below. Those patterns are EXEMPT from the "
                "PATTERN DIVERSITY RULE's per-pattern cap for this order — "
                "repeating them is expected and correct. Emit "
                "`possible_answers` for every question using one of them.",
                "",
            ]
        lines += [
            "**Patterns that require MCQ:**",
            "",
        ]
        for key in sorted(mcq_patterns):
            recipe = recipes.get(
                key,
                "four plausible options labelled a/b/c/d, with "
                "`correct_answer` set to the key letter.",
            )
            lines.append(f"- `{key}` — {recipe}")
        return "\n".join(lines)

    @staticmethod
    def _extract_pattern_used(
        provenance: Optional[GenerationProvenance],
    ) -> Optional[str]:
        """Lift the LLM-emitted `reasoning.pattern_used` out of `extra`.

        `Question.from_dict` puts the parsed `reasoning` dict into
        `generation_metadata` as-is; `GenerationProvenance` routes it to
        `extra["reasoning"]` via `_absorb_unknown_keys`. This helper
        normalises the lookup so `_generate_batch` can pass the value
        into the typed `reasoning_pattern` slot.

        Issue #42 task 42.9b.
        """
        if provenance is None:
            return None
        reasoning = provenance.extra.get("reasoning")
        if not isinstance(reasoning, dict):
            return None
        pattern = reasoning.get("pattern_used")
        return pattern if isinstance(pattern, str) and pattern else None

    @staticmethod
    def _format_facts_section(facts: list) -> str:
        """Format a list of Fact objects into a text section for the prompt.

        Args:
            facts: List of Fact objects (or dicts with 'text', 'source_url', etc.)

        Returns:
            Formatted string of numbered facts for injection into the prompt
        """
        lines = []
        for i, fact in enumerate(facts, 1):
            # Support both Fact dataclass objects and plain dicts
            if hasattr(fact, "text"):
                text = fact.text
                source_url = getattr(fact, "source_url", None)
                source_name = getattr(fact, "source_name", "unknown")
                topic = getattr(fact, "topic", "General")
                surprise = getattr(fact, "surprise_rating", 5.0)
            elif isinstance(fact, dict):
                text = fact.get("text", "")
                source_url = fact.get("source_url")
                source_name = fact.get("source_name", "unknown")
                topic = fact.get("topic", "General")
                surprise = fact.get("surprise_rating", 5.0)
            else:
                continue

            line = f"**Fact {i}** [Topic: {topic}, Surprise: {surprise}/10]"
            line += f"\n  {text}"
            if source_url:
                line += f"\n  Source: {source_name} ({source_url})"
            else:
                line += f"\n  Source: {source_name}"
            lines.append(line)

        return "\n\n".join(lines)

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
            explanation=question.explanation or "(none provided)",
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
            critique_content = self._strip_markdown_fences(response.content)
            start = critique_content.find('{')
            end = critique_content.rfind('}') + 1

            if start == -1 or end <= start:
                # Fallback: assume mediocre (not generous) when parsing fails
                return {
                    "overall_score": 5.0,
                    "verdict": "acceptable",
                    "critique_model": self.critique_model,
                    "error": "No JSON in critique response"
                }

            json_str = critique_content[start:end]
            critique_data = json.loads(json_str)

            # Add critique model info
            critique_data["critique_model"] = self.critique_model

            # Score normalization: if all 6 dimensions scored >8, likely inflated
            scores = critique_data.get("scores", {})
            if scores and all(v > 8 for v in scores.values() if isinstance(v, (int, float))):
                original = critique_data.get("overall_score", 0)
                critique_data["overall_score"] = max(0, original - 0.5)
                critique_data["score_normalized"] = True
                critique_data["original_score"] = original

            return critique_data

        except Exception as e:
            print(f"Error parsing critique: {e}")
            return {
                "overall_score": 5.0,
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
            # Strip markdown code fences that LLMs sometimes wrap around JSON
            content = self._strip_markdown_fences(content)

            if self.verbose:
                print(f"  [verbose] Raw response preview: {content[:200]}...")

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
                    if self.verbose:
                        has_fields = {k: k in q_data for k in ("reasoning", "self_critique", "surprise_factor")}
                        print(f"  [verbose] Question fields: {has_fields}")
                    question = Question.from_dict(
                        q_data,
                        default_difficulty=default_difficulty,
                        default_category=default_category,
                    )
                    self._check_answer_explanation_consistency(question)
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

    def _check_answer_explanation_consistency(self, question: Question) -> None:
        """Log a warning if explanation text doesn't mention the correct answer."""
        if not question.explanation:
            return
        answer_str = str(question.correct_answer).lower().strip()
        if len(answer_str) <= 50 and answer_str not in question.explanation.lower():
            print(
                f"  ⚠ Answer/explanation mismatch: answer '{question.correct_answer}' "
                f"not found in explanation for: {question.question[:80]}..."
            )

