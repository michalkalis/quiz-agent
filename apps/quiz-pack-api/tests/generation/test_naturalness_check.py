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


def _flagged(text: str = PUB_QUIZ, rewrite: str | None = REWRITE) -> Question:
    from app.generation.naturalness_check import Naturalness, apply_naturalness

    q = _question(text)
    q.embedding, q.embedding_qa = [0.1], [0.2]
    apply_naturalness(q, Naturalness(ok=False, problems=[{"kind": "calque", "quote": "nad pivom"}], rewrite=rewrite))
    return q


def test_apply_rewrite_keeps_the_original_and_clears_stale_vectors() -> None:
    """#211 211.4: a swapped row must be auditable and undoable (the original
    text stays in the verdict) and must not keep vectors of the old text, or
    dedup and retrieval would compare against words players never see."""
    from app.generation.naturalness_check import apply_rewrite

    q = _flagged()
    assert apply_rewrite(q, "founder-pairs-2026-10-23") is True
    assert q.question == REWRITE
    verdict = q.generation_metadata.extra["naturalness"]
    assert verdict["original_question"] == PUB_QUIZ
    assert verdict["applied_by"] == "founder-pairs-2026-10-23"
    assert q.embedding is None and q.embedding_qa is None
    # a second run must not swap again (the original would be lost)
    assert apply_rewrite(q, "import") is False
    assert q.generation_metadata.extra["naturalness"]["original_question"] == PUB_QUIZ


def test_apply_rewrite_leaves_ok_and_unchecked_rows_alone() -> None:
    from app.generation.naturalness_check import (
        Naturalness,
        apply_naturalness,
        apply_rewrite,
    )

    unchecked = _question(POPRAD)
    ok = _question(POPRAD)
    apply_naturalness(ok, Naturalness(ok=True))
    assert not apply_rewrite(unchecked, "import") and not apply_rewrite(ok, "import")
    assert unchecked.question == POPRAD == ok.question


@pytest.mark.asyncio
async def test_prompt_asks_for_the_smallest_meaning_preserving_edit() -> None:
    """The 4 rewrites the founder rejected (10-23) changed the meaning, added
    words or rebuilt a sound sentence; the prompt must forbid each of those and
    the verdict must carry the prompt version so old verdicts can be told apart."""
    from app.generation.naturalness_check import (
        PROMPT_VERSION,
        Naturalness,
        apply_naturalness,
    )

    checker = _checker_with(_checks({"index": 1, "ok": True, "problems": [], "rewrite": None}))
    await checker.check([_question(POPRAD)])
    prompt = checker.prompts[0]
    for rule in ("smallest edit", "Never add words", "never rebuild", "keep the exact meaning"):
        assert rule in prompt
    q = _question(POPRAD)
    apply_naturalness(q, Naturalness(ok=True))
    assert q.generation_metadata.extra["naturalness"]["version"] == PROMPT_VERSION == 2


@pytest.mark.asyncio
async def test_rewrite_with_a_look_alike_cyrillic_letter_is_discarded() -> None:
    """10-23 re-check: a rewrite of "minisériu" came back as "minisériа" with a
    Cyrillic "а". It looks identical, so nobody would catch it in review, and
    once swapped in it breaks search and speech. Such a verdict stays unchecked."""
    checker = _checker_with(_checks({
        "index": 1, "ok": False,
        "problems": [{"kind": "grammar", "quote": "minisériu"}],
        "rewrite": "Britská minisériа Adolescence získala osem cien Emmy. Akých?",
    }))
    assert await checker.check([_question("Britská minisériu Adolescence získala osem cien Emmy. Akých?")]) == [None]


@pytest.mark.asyncio
async def test_non_latin_letters_already_in_the_question_are_kept() -> None:
    """A Japanese or Greek name in the question is not a look-alike swap."""
    text = "Hra Ghost of Yōtei nesie meno podľa sopky 羊蹄山. Na ktorom ostrove leží?"
    checker = _checker_with(_checks({
        "index": 1, "ok": False,
        "problems": [{"kind": "unnatural", "quote": "nesie meno"}],
        "rewrite": "Hra Ghost of Yōtei je pomenovaná podľa sopky 羊蹄山. Na ktorom ostrove leží?",
    }))
    [verdict] = await checker.check([_question(text)])
    assert verdict is not None and verdict.rewrite.startswith("Hra Ghost")
