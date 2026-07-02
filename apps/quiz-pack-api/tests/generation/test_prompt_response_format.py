"""46.A1 — the generation prompts' response-format JSON must declare BOTH
`correct_answer` and `explanation` as separate fields.

Why it matters: the v3/v2 prompt bodies instruct the model to "put the
discarded context in `explanation`", but historically the response-format
schema listed no `explanation` key — so the model had nowhere to land that
context and kept it inside `correct_answer`, producing the verbose answers the
issue-46 audit found. This test pins the contract so the schema can never
silently lose the field again.
"""

import re
from pathlib import Path

import pytest

PROMPTS_DIR = Path(__file__).resolve().parents[2] / "prompts"

PROMPTS = [
    "question_generation_v3_fact_first.md",
    "question_generation_v2_cot.md",
    # #76 F-3a — the entertainment prompt is a fact-first variant, so it inherits
    # the same correct_answer/explanation response-format contract; pin it here so
    # an edit to the entertainment tone can never silently drop those fields.
    "question_generation_entertainment.md",
]


def _response_format_block(text: str) -> str:
    """Extract the ```json block immediately under '## Response Format'."""
    section = text.split("## Response Format", 1)
    assert len(section) == 2, "missing '## Response Format' section"
    match = re.search(r"```json\n(.*?)\n```", section[1], re.DOTALL)
    assert match, "no ```json``` block under Response Format"
    return match.group(1)


@pytest.mark.parametrize("prompt_file", PROMPTS)
def test_response_format_declares_correct_answer_and_explanation(prompt_file):
    block = _response_format_block((PROMPTS_DIR / prompt_file).read_text(encoding="utf-8"))
    assert '"correct_answer"' in block, f"{prompt_file}: response format missing correct_answer"
    assert '"explanation"' in block, f"{prompt_file}: response format missing explanation"


def test_entertainment_prompt_renders_absolute_phrasing_rule():
    """#76 F-3b — current/dated entertainment questions must be anchored to an
    explicit year, never relative time ("the latest", "this year's"): the
    generation LLM is blind to today's date, so a relative-time question rots
    silently the moment it ages (research §5). The rule lives only in the
    prompt text, so this pins that it survives PromptBuilder's `.format()`
    render into the prompt the LLM actually sees — a tone edit can never
    silently drop it.
    """
    from app.generation.prompt_builder import PromptBuilder

    rendered = PromptBuilder(
        str(PROMPTS_DIR / "question_generation_entertainment.md")
    ).build_prompt(
        count=10,
        categories=["entertainment"],
        facts_section="FACT: test fact",
        mcq_patterns_section="",
    )
    assert "Absolute phrasing" in rendered
    assert "anchor every dated fact to an explicit year" in rendered
