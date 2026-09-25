"""Question-only rewrite of an existing translation (blind-test arm B).

Founder 2026-09-21: SK/CS questions copy the English word order, so the
listener cannot tell what is being asked. Arm A re-translates the whole row
under ``translate.QUESTION_STRUCTURE_RULE``; this arm keeps the approved
translation (answer, options, explanation) and rewrites **only** the question
sentence under the same rule — cheaper to review, since nothing gradable
changes.
"""

from __future__ import annotations

import json
from typing import Any

from langchain_core.messages import HumanMessage, SystemMessage
from quiz_shared.llm import factory

from .translate import _SYSTEM, LANGUAGE_NAMES, QUESTION_STRUCTURE_RULE

_INSTRUCTIONS = """Rewrite ONLY the {language} question sentence of this quiz item so that it reads naturally to a {language} listener.

Rules:
{structure_rule}
- Keep every fact, number, date, name and unit of the current {language} question; do not add hints and do not drop context.
- The correct answer, options and explanation stay exactly as they are — the rewritten question must still have the same answer.
- If the current question already follows the structure rule, return it unchanged.
- Return ONLY a JSON object: {{"question": "..."}}. No commentary, no markdown fences.

English source question (for meaning only):
{source_question}

Current {language} item:
{payload}"""


def build_prompt(
    source_question: str, translation: dict[str, Any], language: str
) -> str:
    name = LANGUAGE_NAMES[language]
    return _INSTRUCTIONS.format(
        language=name,
        structure_rule=QUESTION_STRUCTURE_RULE.format(language=name),
        source_question=source_question,
        payload=json.dumps(translation, ensure_ascii=False, indent=2),
    )


def parse_question(text: str) -> str:
    cleaned = text.strip()
    if cleaned.startswith("```"):
        cleaned = cleaned.split("\n", 1)[-1].rsplit("```", 1)[0].strip()
    data = json.loads(cleaned[cleaned.find("{") : cleaned.rfind("}") + 1])
    question = str(data.get("question") or "").strip()
    if not question:
        raise ValueError("rewrite returned an empty question")
    return question


async def rewrite_question(
    chat: Any, source_question: str, translation: dict[str, Any], language: str
) -> str:
    """The rewritten question sentence; raises on an unusable reply."""
    response = await chat.ainvoke(
        [
            SystemMessage(content=_SYSTEM),
            HumanMessage(content=build_prompt(source_question, translation, language)),
        ]
    )
    return parse_question(factory.message_text(response))
