"""46.B3 — the open/logical generation prompt's response-format JSON must
declare the two-field open-answer contract: a short `headline_answer`, a full
`explanation`, and a populated `alternative_answers` list.

Why it matters: open-shape questions (why/how mechanisms + lateral puzzles)
are the ~4% the issue-46 audit found cannot be reduced to a single closed
answer. D7 resolved that they carry a short, evaluator-scored `headline_answer`
(the gettable gist) separate from the read-after `explanation`. This is the
ONLY prompt where a sentence-style answer is allowed — pinning the contract
here keeps the sentence-answer exception from leaking back into the factual
branch and stops the schema from silently dropping `headline_answer`.
"""

import re
from pathlib import Path

PROMPTS_DIR = Path(__file__).resolve().parents[2] / "prompts"
PROMPT_FILE = "question_generation_open.md"


def _response_format_block(text: str) -> str:
    """Extract the ```json block immediately under '## Response Format'."""
    section = text.split("## Response Format", 1)
    assert len(section) == 2, "missing '## Response Format' section"
    match = re.search(r"```json\n(.*?)\n```", section[1], re.DOTALL)
    assert match, "no ```json``` block under Response Format"
    return match.group(1)


def test_open_response_format_declares_headline_explanation_alternatives():
    block = _response_format_block((PROMPTS_DIR / PROMPT_FILE).read_text(encoding="utf-8"))
    assert '"headline_answer"' in block, "open prompt missing headline_answer"
    assert '"explanation"' in block, "open prompt missing explanation"
    assert '"alternative_answers"' in block, "open prompt missing alternative_answers"


def test_open_prompt_caps_headline_and_owns_sentence_exception():
    text = (PROMPTS_DIR / PROMPT_FILE).read_text(encoding="utf-8")
    # The headline gist is capped (D7: short, gettable, evaluator-scored).
    assert "8 words" in text, "open prompt must state the ≤8-word headline cap"
    # The sentence-answer exception must live HERE and nowhere else.
    assert "Sentence-answer exception" in text, (
        "open prompt must own the sentence-answer exception"
    )
