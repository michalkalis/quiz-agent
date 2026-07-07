"""Default examples for prompt template."""

import json
import os
import random
from typing import Optional


def _get_data_dir() -> str:
    """Get path to data/examples/ directory."""
    return os.path.join(
        os.path.dirname(__file__), "..", "..", "..", "..", "data", "examples"
    )


def load_gold_standard(
    n: int = 5,
    topics: Optional[list[str]] = None,
    difficulty: Optional[str] = None,
    question_type: Optional[str] = None,
) -> str:
    """Load n random gold-standard examples, optionally filtered by topic/difficulty.

    When ``question_type == "text_multichoice"`` the sample is biased toward
    MCQ-shaped exemplars so MCQ batches actually see the option-dict payload
    shape (issue #72 P2.3 / RC-8: the library is ~3/53 MCQ, so a type-blind
    random sample almost never surfaces an MCQ example).

    Returns formatted string suitable for prompt injection.
    """
    path = os.path.join(_get_data_dir(), "gold_standard.json")
    if not os.path.exists(path):
        return EXCELLENT_EXAMPLES  # fallback to hardcoded

    with open(path, "r", encoding="utf-8") as f:
        examples = json.load(f)

    # Issue #72 P2.3 — bias toward type-appropriate exemplars FIRST (before the
    # topic/difficulty narrowing) so MCQ batches reliably see MCQ-shaped
    # examples (RC-8). Mirror the topic filter's filter-then-top-up so a batch
    # is never starved of examples when fewer than n MCQ entries exist; the
    # later topic/difficulty top-ups draw from this MCQ-biased pool, so the MCQ
    # examples survive. Non-MCQ types fall through unchanged.
    if question_type == "text_multichoice":
        mcq = [e for e in examples if e.get("type") == "text_multichoice"]
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


def load_anti_patterns(n: int = 5) -> str:
    """Load n random anti-pattern examples.

    Returns formatted string suitable for prompt injection.
    """
    path = os.path.join(_get_data_dir(), "anti_patterns.json")
    if not os.path.exists(path):
        return ""  # no anti-patterns available

    with open(path, "r", encoding="utf-8") as f:
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


# 5 EXCELLENT examples with WHY explanations
EXCELLENT_EXAMPLES = """
**Example 1: Clever Wordplay**
Q: "Which writer's name is an anagram of 'I am a weakish speller'?"
A: William Shakespeare
**WHY EXCELLENT:** Combines wordplay with famous figure. Creates "aha!" moment when solved. Educational and entertaining.

**Example 2: Surprising Fact**
Q: "What temperature is the same in Celsius and Fahrenheit?"
A: -40 degrees
**WHY EXCELLENT:** Counterintuitive fact that surprises people. Mathematical elegance. Educational value.

**Example 3: Unexpected Connection**
Q: "Which spice was so prized the Dutch traded Manhattan for a tiny Indonesian island to control it?"
A: Nutmeg
**WHY EXCELLENT:** Surprising historical fact. Links familiar place (Manhattan) with unexpected answer. Teaches interesting history.

**Example 4: Scientific Wonder**
Q: "Which planet has a hexagon-shaped storm at its north pole?"
A: Saturn
**WHY EXCELLENT:** Fascinating space fact most people don't know. Visually striking. Universal appeal.

**Example 5: Biological Curiosity**
Q: "Which animal has cube-shaped feces, a feature believed to help mark territory?"
A: Wombat
**WHY EXCELLENT:** Quirky, memorable fact. Unexpected answer. Makes people laugh and learn.
"""

# 3 OK examples with WHY explanations
OK_EXAMPLES = """
**Example 1: Adequate but Predictable**
Q: "What is the capital of France?"
A: Paris
**WHY JUST OK:** Correct trivia but too common. No surprise factor. Everyone knows this. Could add interesting angle about why/how Paris became capital.

**Example 2: Basic Knowledge**
Q: "What year did World War II end?"
A: 1945
**WHY JUST OK:** Important historical fact but straightforward. Lacks engaging hook. Could frame it with surprising detail (e.g., "VJ Day was celebrated on which date?").

**Example 3: Simple Science**
Q: "How many planets are in our solar system?"
A: 8 (or 9 if including Pluto debate)
**WHY JUST OK:** Basic astronomy but could be controversial (Pluto). Lacks surprise. Could improve by asking about dwarf planets or asking "why was Pluto reclassified?"
"""

# Bad examples from user feedback (dynamic, will be populated at runtime)
BAD_EXAMPLES_TEMPLATE = """
## User-Flagged Questions (Avoid these!)

The following questions were rated poorly by users in live quizzes:

{user_bad_examples}

**Common issues:** Too easy/hard for stated difficulty, unclear wording, niche references, boring format.
"""
