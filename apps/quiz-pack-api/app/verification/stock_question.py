"""Stock-question check (#203, founder 2026-10-14).

Founder, on a TestFlight question asking who refused to give up her bus seat in
Alabama in 1955: "a terrible question … not interesting". Since the #166
slim-down nothing in the direct flow catches these: the judges and the
critique that carried a cliché rule are off, and the generation prompt only
asks the batch not to "lean on" classics.

This check asks one narrow question per item: is this a STOCK question, the
kind a regular quiz player has met many times, asked straight? It judges the
question (fact + angle as asked), not how well known the fact is: the founder
rated "a mile was originally a thousand what?" 5/5 although it is easy, and the
research behind #72 found fact familiarity a poor proxy for cliché
(docs/research/question-craft-prior-art-2026-07-10.md, 4.6).

Shape mirrors ``TopicalityClassifier``: one batched call through
``quiz_shared.llm.factory``, never raises, and a question without a usable
verdict is KEPT (fail-safe, like every other check).
"""

from __future__ import annotations

import json
import logging
from dataclasses import dataclass
from typing import Optional, Sequence

from quiz_shared.llm import factory as llm_factory
from quiz_shared.models.question import Question

logger = logging.getLogger(__name__)

# Anchors are the founder's own ratings (calibration 2026-07-09) plus the
# question that started #203. Keep them short: they teach the line, the
# definition carries the rule.
_PROMPT_HEADER = """You review questions for a trivia game played by ordinary \
adults who do a quiz now and then. They are NOT trivia buffs, so judge with \
their eyes, not yours: you have seen almost every fun fact somewhere, they \
have not.

Flag a question as STOCK only when the player gets nothing new from it: the \
answer is a school-textbook or general-culture staple most adults already \
know (or have heard asked many times), and the question just asks them to \
recall it ("who did X", "which city has landmark Y", "what is Z named after", \
"in which year did famous event W happen"). Extra detail added to the stem \
does not rescue such a question.

NOT STOCK: a fact that would surprise or delight most ordinary adults, even \
if trivia fans know it well; a famous subject asked from an angle most people \
never considered; an easy question whose answer is still a small "huh, \
really?". When unsure, answer NOT stock.

STOCK (founder rated 2/5 or refused to rate):
- Who is known as the King of Pop? (Michael Jackson)
- Which element is named after the creator of the periodic table? (Mendelevium)
- Which board game was banned in the Soviet Union? (Monopoly)
- Which city has the Christ the Redeemer statue? (Rio de Janeiro)
- Who refused to give up her bus seat in Alabama in 1955? (Rosa Parks)

NOT STOCK (founder rated 5/5):
- The word "mile" comes from the Latin for a thousand what? (Paces)
- Who are usually the nearest humans to Point Nemo? (Astronauts on the ISS)
- Did Cleopatra live closer in time to the building of the Great Pyramid or to the Moon landing? (Moon landing)
- In Old English, what creature does the name "Dumbledore" mean? (Bumblebee)

Respond with JSON only, no prose:
{"verdicts": [{"index": <1-based int>, "stock": true|false, "reason": "<one short line>"}]}

Questions:
"""


@dataclass
class StockVerdict:
    stock: bool
    reason: str


def _answer_text(answer: object) -> str:
    if isinstance(answer, list):
        return ", ".join(str(a) for a in answer)
    return str(answer)


class StockQuestionChecker:
    """Batched judge; ``check`` never raises and aligns results to the input."""

    def __init__(self, model: Optional[str] = None) -> None:
        self._model = model or llm_factory.STOCK_QUESTION
        self._client = None

    async def _complete(self, prompt: str) -> Optional[str]:
        """Single LLM boundary: raw model text, or ``None`` on any failure."""
        try:
            if self._client is None:
                self._client = llm_factory.chat_model(self._model)
            response = await self._client.ainvoke(prompt)
            return llm_factory.message_text(response)
        except Exception:
            logger.warning("StockQuestionChecker call failed", exc_info=True)
            return None

    @staticmethod
    def build_prompt(questions: Sequence[Question]) -> str:
        lines = [_PROMPT_HEADER]
        for i, q in enumerate(questions, start=1):
            options = ""
            if q.possible_answers:
                options = "   Options: " + " | ".join(
                    str(v) for v in q.possible_answers.values()
                ) + "\n"
            lines.append(
                f"{i}. Q: {q.question}\n{options}   A: {_answer_text(q.correct_answer)}"
            )
        return "\n".join(lines)

    @staticmethod
    def parse(text: str, n: int) -> list[Optional[StockVerdict]]:
        """Verdicts aligned to the batch; ``None`` where the model gave none."""
        result: list[Optional[StockVerdict]] = [None] * n
        start, end = text.find("{"), text.rfind("}") + 1
        if start == -1 or end <= start:
            logger.warning("StockQuestionChecker: no JSON in response; %d kept", n)
            return result
        try:
            data = json.loads(text[start:end])
        except json.JSONDecodeError:
            logger.warning("StockQuestionChecker: malformed JSON; %d kept", n)
            return result
        items = data.get("verdicts") if isinstance(data, dict) else None
        for item in items if isinstance(items, list) else []:
            if not isinstance(item, dict):
                continue
            index, stock = item.get("index"), item.get("stock")
            if not isinstance(index, int) or not 1 <= index <= n:
                continue
            if not isinstance(stock, bool):
                continue
            result[index - 1] = StockVerdict(
                stock=stock, reason=str(item.get("reason") or "")[:200]
            )
        missing = result.count(None)
        if missing:
            logger.warning("StockQuestionChecker: %d/%d without a verdict, kept", missing, n)
        return result

    async def check(self, questions: Sequence[Question]) -> list[Optional[StockVerdict]]:
        if not questions:
            return []
        raw = await self._complete(self.build_prompt(questions))
        if raw is None:
            return [None] * len(questions)
        return self.parse(raw, len(questions))
