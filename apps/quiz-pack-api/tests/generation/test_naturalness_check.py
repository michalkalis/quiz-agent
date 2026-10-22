"""Unit tests for NaturalnessChecker (#211 — natural sk/cs questions).

Why these scenarios: the founder found "Krčmové kvízy, pri ktorých tímy
súťažia nad pivom, dnes nájdete v Bratislave…" in the corpus. The check must
(a) flag exactly that kind of row with a quote and a rewrite the founder can
blind-rate, (b) never touch the question text itself (it is a label, not a
gate: LLM judges are unreliable on sk/cs fluency, the founder decides), (c)
record an "ok" verdict too so the resumable backfill skips checked rows, and
(d) fail safe to "unchecked" on every error, never dropping or blocking a row.
"""

from __future__ import annotations

import json

import pytest
from app.generation.naturalness_check import (
    NaturalnessChecker,
    has_naturalness_verdict,
    needs_check,
)
from quiz_shared.models.question import Question

PUB_QUIZ = (
    "Krčmové kvízy, pri ktorých tímy súťažia nad pivom, dnes nájdete v "
    "Bratislave, Košiciach aj v menších mestách. Z ktorej krajiny tento formát "
    "zábavy pôvodne pochádza?"
)
POPRAD = (
    "Takmer všetky slovenské rieky odnesú vodu cez Dunaj do Čierneho mora. "
    "Rieka Poprad je však výnimka. Do ktorého mora sa jej voda dostane?"
)
REWRITE = "Z ktorej krajiny pôvodne pochádzajú krčmové kvízy, pri ktorých tímy súťažia pri pive?"


def _question(text: str, language: str = "sk") -> Question:
    return Question(
        id=f"q_{abs(hash(text)) % 10_000}",
        question=text,
        correct_answer="answer",
        topic="General",
        category="general",
        difficulty="medium",
        language=language,
    )


def _checker_with(response: str | None) -> NaturalnessChecker:
    checker = NaturalnessChecker(model="claude-opus-5-5")
    checker.prompts: list[str] = []  # type: ignore[misc]

    async def _fake_complete(prompt: str) -> str | None:
        checker.prompts.append(prompt)  # type: ignore[attr-defined]
        return response

    checker._complete = _fake_complete  # type: ignore[assignment]
    return checker


def _checks(*items: dict) -> str:
    return json.dumps({"checks": [{"index": i, **it} for i, it in enumerate(items, 1)]})


FLAGGED = {
    "ok": False,
    "problems": [
        {"kind": "calque", "quote": "súťažia nad pivom"},
        {"kind": "empty_hook", "quote": "dnes nájdete v Bratislave, Košiciach"},
    ],
    "rewrite": REWRITE,
}


@pytest.fixture(autouse=True)
def _key(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-test")


@pytest.mark.asyncio
async def test_pub_quiz_row_is_flagged_with_quote_and_rewrite_text_untouched() -> None:
    pub, poprad = _question(PUB_QUIZ), _question(POPRAD)
    checker = _checker_with(_checks(FLAGGED, {"ok": True, "problems": [], "rewrite": None}))

    assert await checker.label([pub, poprad]) == 2

    verdict = pub.generation_metadata.extra["naturalness"]
    assert verdict["ok"] is False
    assert {p["kind"] for p in verdict["problems"]} == {"calque", "empty_hook"}
    assert verdict["rewrite"] == REWRITE
    assert pub.question == PUB_QUIZ  # a label, never an edit
    assert poprad.generation_metadata.extra["naturalness"]["ok"] is True
    assert has_naturalness_verdict(poprad)  # checked-ok is skipped next run


@pytest.mark.asyncio
async def test_prompt_names_both_failure_kinds_and_allows_a_hook_that_carries_the_point() -> None:
    """The founder rated the carp-vs-KFC home contrast 9/10: the editor must
    not learn that every home reference is bad, only the empty one."""
    checker = _checker_with(_checks(FLAGGED))
    await checker.check([_question(PUB_QUIZ)])
    prompt = checker.prompts[0]
    assert "nad pivom" in prompt and "empty_hook" in prompt
    assert "kapor so šalátom" in prompt
    assert "[sk] " + PUB_QUIZ in prompt


@pytest.mark.parametrize(
    "item",
    [
        {"ok": False, "problems": [{"kind": "calque", "quote": "x"}], "rewrite": None},
        {"ok": True, "problems": [{"kind": "calque", "quote": "x"}], "rewrite": None},
        {"ok": False, "problems": [{"kind": "style", "quote": "x"}], "rewrite": "y"},
    ],
    ids=["flag-without-rewrite", "ok-with-problems", "unknown-kind"],
)
@pytest.mark.asyncio
async def test_inconsistent_verdict_leaves_the_row_unchecked(item: dict) -> None:
    """A flag the founder cannot act on (no rewrite) or a self-contradicting
    verdict is worse than none: leave it for the next run."""
    q = _question(PUB_QUIZ)
    assert await _checker_with(_checks(item)).label([q]) == 0
    assert not has_naturalness_verdict(q)


@pytest.mark.parametrize("response", [None, "not json", '{"checks": "x"}', _checks()])
@pytest.mark.asyncio
async def test_every_failure_fails_safe_to_unchecked(response: str | None) -> None:
    q = _question(PUB_QUIZ)
    assert await _checker_with(response).label([q]) == 0
    assert q.question == PUB_QUIZ and not has_naturalness_verdict(q)


def test_only_native_sk_cs_rows_need_the_check() -> None:
    """English rows are written by an English model; translations already
    have the MQM judge."""
    assert needs_check(_question(PUB_QUIZ, "sk"))
    assert needs_check(_question(PUB_QUIZ, "cs"))
    assert not needs_check(_question("Where do pub quizzes come from?", "en"))
