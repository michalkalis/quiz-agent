"""Default examples for prompt template."""

import json
import random
from pathlib import Path
from typing import Optional

from quiz_shared.paths import find_in_ancestors


def example_corpus_path(filename: str) -> Path:
    """Locate a ``data/examples/`` corpus file, or raise.

    Walks up from this module rather than indexing a fixed number of parents so
    the same code resolves in the repo checkout AND in the Docker ``/app``
    layout, where the Dockerfile copies ``data/examples`` next to the app
    (#60.P3 pattern).

    Raises rather than returning a fallback: the deployed image used to carry no
    ``data/`` at all, so gold-standard and anti-pattern injection degraded to
    five hardcoded exemplars — which themselves taught banned shapes (a
    language-dependent anagram, a non-metric figure) to every paid pack, with no
    log line saying so. A missing corpus is a packaging defect and must be loud.
    """
    path = find_in_ancestors(Path(__file__), f"data/examples/{filename}")
    if path is None:
        raise FileNotFoundError(
            f"prompt example corpus data/examples/{filename} not found above "
            f"{Path(__file__).parent} — refusing to generate with degraded "
            "prompts. In the Docker image the corpus is copied by "
            "apps/quiz-pack-api/Dockerfile (and re-included in .dockerignore); "
            "locally it lives in the repo's data/examples/."
        )
    return path


# Only entries the founder actually rated as gold belong in the "Gold
# Standard" prompt section. 21/53 library entries carry ratings 5-7; showing
# them as "9-10/10" anchored generation on mediocre exemplars (generation
# review 2026-07-30, section B — cheapest quality lever in the stack).
MIN_GOLD_RATING = 8


def load_gold_standard(
    n: int = 4,
    topics: Optional[list[str]] = None,
    difficulty: Optional[str] = None,
    question_type: Optional[str] = None,
) -> str:
    """Load n random gold-standard examples, optionally filtered by topic/difficulty.

    Entries below ``MIN_GOLD_RATING`` (founder's ``human_rating``) are
    excluded; an unrated entry is treated as not-gold. When
    ``question_type == "text_multichoice"`` the sample is biased toward
    MCQ-shaped exemplars so MCQ batches actually see the option-dict payload
    shape (issue #72 P2.3 / RC-8).

    Returns formatted string suitable for prompt injection.
    """
    with example_corpus_path("gold_standard.json").open("r", encoding="utf-8") as f:
        all_examples = json.load(f)

    rated_gold = [
        e for e in all_examples
        if isinstance(e.get("human_rating"), (int, float))
        and e["human_rating"] >= MIN_GOLD_RATING
    ]
    examples = rated_gold or all_examples

    # Issue #72 P2.3 — bias toward type-appropriate exemplars FIRST (before the
    # topic/difficulty narrowing) so MCQ batches reliably see MCQ-shaped
    # examples (RC-8). Mirror the topic filter's filter-then-top-up so a batch
    # is never starved of examples when fewer than n MCQ entries exist; the
    # later topic/difficulty top-ups draw from this MCQ-biased pool, so the MCQ
    # examples survive. Non-MCQ types fall through unchanged.
    if question_type == "text_multichoice":
        mcq = [e for e in examples if e.get("type") == "text_multichoice"]
        if not mcq:
            # Shape trumps rating for the MCQ exemplar (RC-8): when no
            # rated-gold MCQ exists, the payload-shape example still has to
            # come from somewhere — draw it from the full library.
            mcq = [e for e in all_examples if e.get("type") == "text_multichoice"]
        if mcq:
            if len(mcq) < n:
                others = [e for e in examples if e not in mcq]
                mcq = mcq + random.sample(others, min(n - len(mcq), len(others)))
            examples = mcq

    # Filter by topic if specified
    if topics:
        topics_lower = [t.lower() for t in topics]
        filtered = [e for e in examples if e.get("topic", "").lower() in topics_lower]
        # If too few matches, add random ones from the full set
        if len(filtered) < n:
            remaining = [e for e in examples if e not in filtered]
            filtered.extend(random.sample(remaining, min(n - len(filtered), len(remaining))))
        examples = filtered

    # Filter by difficulty if specified
    if difficulty:
        diff_filtered = [e for e in examples if e.get("difficulty", "") == difficulty]
        if len(diff_filtered) >= n // 2:  # Use filtered if enough matches
            examples = diff_filtered

    # Sample n examples
    selected = random.sample(examples, min(n, len(examples)))

    # Format as prompt text
    # First n-2 examples: full Q+A. Last 2: pattern-only (no answer) to reduce copying.
    # Issue #42 task 42.10: MCQ entries (type=text_multichoice + possible_answers)
    # render the options dict so the LLM sees the exact MCQ payload shape; the
    # `answer` field for MCQ examples is the key letter, value-resolved inline.
    lines = []
    full_count = max(len(selected) - 2, 1)
    for i, ex in enumerate(selected, 1):
        lines.append(f"**Example {i}: {ex.get('pattern', 'Unknown Pattern')}**")
        lines.append(f'Q: "{ex["question"]}"')
        options = ex.get("possible_answers")
        is_mcq = ex.get("type") == "text_multichoice" and isinstance(options, dict)
        if is_mcq:
            opts_inline = ", ".join(f'{k.upper()}) {v}' for k, v in options.items())
            lines.append(f"Options: {opts_inline}")
        if i <= full_count:
            if is_mcq:
                key = str(ex["answer"]).strip().lower()
                resolved = options.get(key, ex["answer"])
                lines.append(f'A: {key} ({resolved})')
            else:
                lines.append(f'A: {ex["answer"]}')
            lines.append(f'**WHY EXCELLENT:** {ex["why_excellent"]}')
        else:
            lines.append('*(Answer omitted — study the question structure and pattern, not the answer.)*')
        lines.append("")

    return "\n".join(lines)


def load_anti_patterns(n: int = 3) -> str:
    """Load n random anti-pattern examples.

    Returns formatted string suitable for prompt injection.
    """
    with example_corpus_path("anti_patterns.json").open("r", encoding="utf-8") as f:
        examples = json.load(f)

    selected = random.sample(examples, min(n, len(examples)))

    lines = []
    for ex in selected:
        lines.append(f'**BAD:** "{ex["question"]}" -> {ex["answer"]}')
        lines.append(f'**Why it\'s bad:** {ex["why_bad"]}')
        violated = ", ".join(ex.get("violated_principles", []))
        if violated:
            lines.append(f'**Violated principles:** {violated}')
        lines.append("")

    return "\n".join(lines)


# Both hardcoded example tiers were deleted on 2026-07-30:
# - EXCELLENT_EXAMPLES fallback (adversarial audit): the deployed image used
#   to ship without data/, silently degrading every paid pack to hardcoded
#   exemplars that themselves taught banned shapes (a language-dependent
#   anagram, a non-metric figure) — example_corpus_path now fails loud instead.
# - OK_EXAMPLES tier (generation review, section B): mid-tier exemplars
#   literally demonstrated the banned boring formats ("What year did WWII
#   end?"); gold (founder-rated 8+) plus ≤3 anti-patterns are the whole
#   example budget. Legacy templates' `{ok_examples}` placeholder renders
#   empty.

# Bad examples from user feedback (dynamic, will be populated at runtime)
BAD_EXAMPLES_TEMPLATE = """
## User-Flagged Questions (Avoid these!)

The following questions were rated poorly by users in live quizzes:

{user_bad_examples}

**Common issues:** Too easy/hard for stated difficulty, unclear wording, niche references, boring format.
"""
