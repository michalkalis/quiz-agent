"""#128 — every generation prompt must carry the widened language-portability rule.

The founder was served "a murder of crows" in a Slovak session: a genuine English
collective noun whose literal Slovak translation ("vražda") is a fabricated fact.
The model had tagged it `language_dependent: false` *correctly* under the old
rubric, which only ever named orthography and wordplay — and most prompts carried
no rule at all, only a `"language_dependent": false` line inside their JSON output
example, which biases the model toward false for everything.

These tests pin the widened rule into every prompt that can emit a question, and
pin that it survives PromptBuilder's `.format()` render for the wired ones (a
stray brace in the rule text would otherwise blow up generation at runtime).
"""

from pathlib import Path

import pytest

PROMPTS_DIR = Path(__file__).resolve().parents[2] / "prompts"

# Every prompt that emits a question object with a `language_dependent` field.
# Kids/themed/rewrite are not wired into a running pipeline today, but they are
# question-emitting prompts and must not drift back to a rule-free `false` example.
PROMPTS = [
    "question_generation.md",
    "question_generation_v2_cot.md",
    "question_generation_v3_fact_first.md",
    "question_generation_entertainment.md",
    "question_generation_open.md",
    "question_generation_kids.md",
    "question_generation_themed.md",
    "question_rewrite.md",
]

HEADING = "## Language Portability (HARD RULE)"

# 2026-07-30 prompt consolidation: the two active fact-first templates carry
# the rule inside THE CONTRACT under this heading; the legacy templates keep
# the original standalone section. Either heading satisfies "the rule exists".
CONTRACT_HEADING = "**Language portability**"


def _has_rule_heading(text: str) -> bool:
    return HEADING in text or CONTRACT_HEADING in text


# The classes the old orthography-only rubric missed. Each is a distinct failure
# mode, so losing any one of them re-opens the bug for that class.
REQUIRED_CLASSES = [
    "collective nouns",
    "a murder of crows",
    "idioms, proverbs, set phrases",
    "naming quirks",
]


@pytest.mark.parametrize("prompt_file", PROMPTS)
def test_prompt_carries_the_widened_portability_rule(prompt_file):
    text = (PROMPTS_DIR / prompt_file).read_text(encoding="utf-8")
    assert _has_rule_heading(text), (
        f"{prompt_file}: no language-portability rule section"
    )
    for phrase in REQUIRED_CLASSES:
        assert phrase in text, f"{prompt_file}: portability rule lost '{phrase}'"


@pytest.mark.parametrize("prompt_file", PROMPTS)
def test_rule_states_the_translation_test_and_the_flag(prompt_file):
    """The rule is useless as a taxonomy alone: the model needs the operational
    test (translate literally, check the answer still holds) and the field to set."""
    text = (PROMPTS_DIR / prompt_file).read_text(encoding="utf-8")
    assert "translated literally" in text, f"{prompt_file}: no literal-translation test"
    assert "Set `language_dependent: true`" in text, (
        f"{prompt_file}: rule never names the field to set"
    )


@pytest.mark.parametrize(
    "prompt_file",
    [
        "question_generation.md",
        "question_generation_v2_cot.md",
        "question_generation_v3_fact_first.md",
        "question_generation_entertainment.md",
        "question_generation_open.md",
    ],
)
def test_rule_survives_prompt_builder_render(prompt_file):
    """The wired prompts go through `.format()`, so this both proves the rule
    reaches the LLM and that its text introduced no unescaped brace."""
    from app.generation.prompt_builder import PromptBuilder

    rendered = PromptBuilder(str(PROMPTS_DIR / prompt_file)).build_prompt(
        count=10,
        categories=["general"],
        facts_section="FACT: test fact",
        mcq_patterns_section="",
    )
    assert _has_rule_heading(rendered)
    assert "a murder of crows" in rendered
