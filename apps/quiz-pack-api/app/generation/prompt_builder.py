"""Dynamic prompt builder for question generation."""

import os
from typing import List, Optional

from quiz_shared.llm import factory as llm_factory

from .classification import CATEGORIES
from .examples import BAD_EXAMPLES_TEMPLATE, load_gold_standard, load_anti_patterns

# 2026-07-27 live-run F-e — per-question difficulty/category assessment.
# Injected into every generation template via `{classification_section}`;
# the JSON schema lines reference it through `{difficulty_field}` /
# `{category_field}`. The calibration lens matches the scorer's
# (multi_model_scorer.py): a non-native-English adult player.
_MIXED_DIFFICULTY_HEADER = (
    "mixed — aim for roughly 30% easy / 50% medium / 20% hard across the batch"
)

_DIFFICULTY_FIELD = (
    "easy | medium | hard — your honest assessment of THIS question "
    "(see DIFFICULTY & CATEGORY)"
)

_DIFFICULTY_GUIDANCE = """\
**`difficulty` — assess each question honestly** (never copy one value onto the
whole batch). Calibrate for a non-native-English adult player:
- `easy` — most players answer instantly (widely known fact, obvious deduction).
- `medium` — takes real thought or partial knowledge; a motivated player gets there.
- `hard` — only players with genuine knowledge of the area get it; still fair, never arcane."""

_CATEGORY_CLASSIFY_GUIDANCE = """\
**`category` — classify each question** into exactly one player-facing filter id:
{category_ids}.
`category` is the audience/theme filter players pick in the app — it is NOT the
subject (`topic` carries that). Use `kids` only for questions a young child can
enjoy and answer; `adults` only for content unsuited to children; a themed id
(`disney`, `football`, …) only when the question is squarely about that theme.
When in doubt, use `general`."""

_CATEGORY_FIXED_GUIDANCE = """\
**`category`** — this order is for the "{category}" category: set `category` to
exactly "{category}" on every question."""

# 2026-07-30 generation review, section C — model-specific process header.
# Frontier reasoning models (Claude 5-class, gpt-5 family, Gemini 3 pro)
# degrade under prescriptive step-by-step scaffolds: they get the goal and the
# constraints, and plan their own process. Non-frontier models still benefit
# from an explicit checklist. One shared constraint contract + a ~10-line
# model-keyed header — never fork whole prompt files per model (cross-model
# forks drift; the 8 duplicated Language-Portability blocks were the proof).
_FRONTIER_MODEL_MARKERS = (
    "claude-fable-5",
    "claude-opus-5",
    "claude-opus-4-8",
    "claude-sonnet-5",
    "gpt-5",
    "gemini-3",
)

_PROCESS_HEADER_FRONTIER = """\
Work fact-first: pick a source fact worth telling, find the angle that makes a
player feel something (surprise, disbelief, delight), then shape it under THE
CONTRACT below. You own the process — there is no mandated step sequence. Emit
only questions you would defend as genuinely fun; skipping a weak fact is
always better than forcing a mediocre question from it."""

_PROCESS_HEADER_CHECKLIST = """\
For EACH question follow this process:
1. SELECT a source fact (surprising enough, framable, universal).
2. Name the wrong assumption the player will start from (this becomes
   `reasoning.why_interesting`). No wrong assumption = plain recall = pick a
   different fact.
3. Choose a pattern from the Pattern Library and draft the question.
4. Check the draft against THE CONTRACT below: fix or discard on any
   hard-rule violation; weigh the craft guidance with judgment.
5. Emit only questions you would defend as genuinely fun."""


def process_header_for_model(model_id: str) -> str:
    """Model-keyed process header (goal-mode for frontier, checklist otherwise)."""
    bare = model_id.split(":", 1)[-1].lower()
    if any(marker in bare for marker in _FRONTIER_MODEL_MARKERS):
        return _PROCESS_HEADER_FRONTIER
    return _PROCESS_HEADER_CHECKLIST


def prose_response_format(
    question_type: str, category_field: str, difficulty_field: str
) -> str:
    """The free-text JSON output contract (classic/text path).

    The structured MCQ path replaces this with a short tool-schema note via
    the ``response_format_section`` kwarg — shipping a prose JSON contract
    alongside a bound tool schema gave the model two conflicting output
    contracts (generation review A4). ``reasoning`` stays FIRST in the field
    order deliberately: reasoning-before-answer is a verified keeper (review
    section E). ``self_critique`` is gone — self-scored gates on frontier
    models are theater (SELF-[IN]CORRECT; review section B).
    """
    return f"""## Response Format

Return ONLY this JSON structure (no prose around it). Field order matters:
`reasoning` comes BEFORE the question fields.

```json
{{
  "questions": [
    {{
      "reasoning": {{
        "source_fact": "Quote or number of the ONE source fact used",
        "pattern_used": "snake_case pattern key",
        "why_interesting": "The wrong assumption the player starts from, and how the answer overturns it"
      }},
      "question": "Your question text here?",
      "type": "{question_type}",
      "correct_answer": "1-5 words, canonical short form",
      "explanation": "1-2 spoken sentences of payoff behind the answer (discarded answer context belongs here)",
      "possible_answers": null,
      "alternative_answers": [],
      "topic": "Topic name",
      "category": "{category_field}",
      "difficulty": "{difficulty_field}",
      "language_dependent": false,
      "age_appropriate": "all",
      "source_url": "Exact URL copied from that fact's Source line",
      "source_excerpt": "Short snippet from that fact confirming the answer"
    }}
  ]
}}
```

- Text questions: `type` = "text", `possible_answers` = null, fill
  `alternative_answers` with acceptable variations.
- Multiple-choice questions: `type` = "text_multichoice"; `possible_answers`
  is an options dict (4 entries for general MCQ, 2 for true/false);
  `correct_answer` is the lowercase key letter, never the value text;
  `alternative_answers` = []."""


STRUCTURED_MCQ_FORMAT_NOTE = """## Response Format

Emit the batch through the bound tool schema (structured output) — do not
write JSON as prose. Field notes:
- `correct_answer` — the lowercase key letter of the correct option.
- `why_interesting` — the wrong assumption the player starts from and how the
  answer overturns it (if you cannot name one, the question is plain recall:
  pick a different fact or framing).
- `source_url` — the exact URL of the ONE source fact this question was built
  from, copied verbatim; `source_excerpt` — the snippet confirming the answer.
- `language_dependent` — true when the fact only holds as an English lexical
  convention (see THE CONTRACT)."""


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
        difficulty: Optional[str] = None,
        topics: Optional[List[str]] = None,
        categories: Optional[List[str]] = None,
        question_type: str = "text",
        excluded_topics: Optional[List[str]] = None,
        avoid_questions: Optional[List[str]] = None,
        user_bad_examples: Optional[List[str]] = None,
        excellent_examples: Optional[str] = None,
        anti_examples: Optional[str] = None,
        ok_examples: Optional[str] = None,
        generation_model: Optional[str] = None,
        **kwargs,
    ) -> str:
        """Build complete prompt with all variables filled.

        Args:
            count: Number of questions to generate
            difficulty: easy, medium, or hard; None (default) = mixed batch —
                the LLM assesses each question and aims for a spread
            topics: List of preferred topics
            categories: List of categories (adults, children, etc.)
            question_type: text or text_multichoice
            excluded_topics: Topics to avoid
            avoid_questions: Previously asked questions to avoid
            user_bad_examples: Questions users rated poorly
            excellent_examples: Pre-sampled gold examples. Pass these when one
                order fans out into several LLM calls so every call shares one
                sample (keeps the static prompt prefix cacheable); default is
                a fresh sample per call.
            anti_examples: Pre-sampled anti-pattern block (same reasoning).
            ok_examples: Legacy templates only ({ok_examples} placeholder);
                the OK tier was removed from active templates in the
                2026-07-30 example-hygiene pass.
            generation_model: Model id the prompt will be sent to; selects the
                `{process_header}` variant (goal-mode for frontier models,
                checklist otherwise).
            **kwargs: Extra template variables (e.g., facts_section for V3 prompt)

        Returns:
            Complete prompt ready for LLM
        """
        # Use dynamic sampling from the gold-standard library (raises if absent)
        if excellent_examples is None:
            excellent_examples = load_gold_standard(
                topics=topics,
                difficulty=difficulty,
                question_type=question_type,
            )

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
        anti_pattern_text = (
            anti_examples if anti_examples is not None else load_anti_patterns()
        )
        if anti_pattern_text:
            bad_examples_section = f"\n## Anti-Patterns (avoid these failure modes)\n\n{anti_pattern_text}\n"
        if user_bad_examples:
            examples_text = "\n".join(f"- {q}" for q in user_bad_examples[:10])
            bad_examples_section += BAD_EXAMPLES_TEMPLATE.format(
                user_bad_examples=examples_text
            )

        # 2026-07-27 live-run F-e — per-question difficulty/category.
        # `{difficulty}` (the order-level header) shows the explicit target or
        # the mixed-spread instruction; `{difficulty_field}`/`{category_field}`
        # replace the old echo-values in the templates' JSON schema lines, and
        # `{classification_section}` carries the calibration guidance.
        order_category = categories[0] if categories else None
        if order_category:
            category_field = order_category
            category_guidance = _CATEGORY_FIXED_GUIDANCE.format(
                category=order_category
            )
        else:
            category_field = (
                " | ".join(CATEGORIES)
                + " — classify THIS question (see DIFFICULTY & CATEGORY)"
            )
            category_guidance = _CATEGORY_CLASSIFY_GUIDANCE.format(
                category_ids=", ".join(f"`{c}`" for c in CATEGORIES)
            )
        classification_section = (
            "## DIFFICULTY & CATEGORY (per question)\n\n"
            f"{_DIFFICULTY_GUIDANCE}\n\n{category_guidance}"
        )

        # Build format variables dict
        format_vars = {
            "excellent_examples": excellent_examples,
            "ok_examples": ok_examples or "",
            "bad_examples_section": bad_examples_section,
            "count": count,
            "difficulty": difficulty or _MIXED_DIFFICULTY_HEADER,
            "difficulty_field": _DIFFICULTY_FIELD,
            "category_field": category_field,
            "classification_section": classification_section,
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
            # Issue #72 Phase 3 — empty default so the v3 prompt can carry
            # `{craft_guards_section}` unconditionally; the caller fills it
            # via **kwargs only when the `GEN_CRAFT_GUARDS` flag is on.
            "craft_guards_section": "",
            # 2026-07-30 — model-keyed process header + per-path output
            # contract (generation review A4/C). Defaults keep every template
            # coherent for callers that don't pass them.
            "process_header": process_header_for_model(
                generation_model or llm_factory.GEN
            ),
            "response_format_section": prose_response_format(
                question_type, category_field, _DIFFICULTY_FIELD
            ),
        }

        # Merge any extra template variables (e.g., facts_section for V3)
        format_vars.update(kwargs)

        # Format main template
        prompt = self.template.format(**format_vars)

        return prompt
