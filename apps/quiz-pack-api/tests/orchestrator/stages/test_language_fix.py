"""LanguageFixStage — the language fix-up of a customer pack round.

Why: a paid trial of Slovak child packs shipped Harry Potter's owl spelled
"Hedwigu" / "Hedwiga" (official Slovak "Hedviga") and "viac, či menej".
The founder (2026-11-18) wants such slips fixed when it is cheap, and every
change recorded so it can be judged later what each step changes and whether
it helps. The fix is a polish step: it may touch wording, spelling, names and
punctuation only, never a fact, a number or what the answer means, never a
child-band cap, and a failure must leave the pack exactly as generated.

The LLM is mocked at the checker's single boundary (``_complete``), so the
real prompt building and parsing run.
"""

from __future__ import annotations

import asyncio
import json
import uuid

import pytest
from app.generation import text_edits
from app.generation.pack_language_check import PackLanguageChecker
from app.orchestrator.context import OrderContext
from app.orchestrator.stages import language_fix
from app.orchestrator.stages.language_fix import LanguageFixStage
from quiz_shared.models.question import Question

OWL = "Ako sa volá sova, ktorú dostal Harry Potter na jedenáste narodeniny?"


@pytest.fixture(autouse=True)
def _key(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-test")


def _q(
    text: str, answer: str = "Hedwiga", explanation: str | None = None, **kw
) -> Question:
    return Question(
        id=f"q_{uuid.uuid4().hex[:8]}",
        question=text,
        correct_answer=answer,
        explanation=explanation,
        topic="Harry Potter",
        category="general",
        difficulty="easy",
        language="sk",
        **kw,
    )


def _ctx(
    questions: list[Question], locked: int = 0, language: str = "sk", audience=None
):
    ctx = OrderContext(
        order_id=uuid.uuid4(),
        prompt="Harry Potter",
        language=language,
        target_count=len(questions),
        audience=audience,
    )
    ctx.questions = questions
    ctx.locked_count = locked
    return ctx


class _Checker(PackLanguageChecker):
    def __init__(self, response=None, delay: float = 0.0) -> None:
        super().__init__(model="claude-opus-5-5")
        self.response = response
        self.delay = delay
        self.prompts: list[str] = []

    async def _complete(self, prompt: str):
        self.prompts.append(prompt)
        if self.delay:
            await asyncio.sleep(self.delay)
        return self.response


def _reply(*items: dict) -> str:
    return json.dumps({"checks": list(items)}, ensure_ascii=False)


def _snapshot(questions: list[Question]) -> list[dict]:
    return [q.model_dump() for q in questions]


async def test_fix_is_applied_and_every_change_recorded_with_before_and_after() -> None:
    saved = _q("Kto poslal Harrymu sovu Hedvigu?", answer="Hagrid")
    new = _q(
        "Ako sa volá Harryho sova?",
        answer="Hedwiga",
        explanation="Snežnú sovu mu kúpil Hagrid, viac, či menej ako darček.",
    )
    ctx = _ctx([saved, new], locked=1)
    checker = _Checker(
        _reply(
            {
                "index": 1,
                "ok": False,
                "problems": [
                    {"kind": "name", "quote": "Hedwiga"},
                    {"kind": "punctuation", "quote": "viac, či menej"},
                ],
                "rewrite": "Ako sa volá Harryho sova?",
                "fields": {
                    "answer": "Hedviga",
                    "explanation": "Snežnú sovu mu kúpil Hagrid, viac či menej ako darček.",
                },
            }
        )
    )

    result = await LanguageFixStage(checker).run(ctx, sink=None)

    # The whole pack is seen: the saved question as context, the new one to check.
    assert "Kto poslal Harrymu sovu Hedvigu?" in checker.prompts[0]
    assert "1. [sk] Ako sa volá Harryho sova?" in checker.prompts[0]
    assert new.correct_answer == "Hedviga"
    assert new.explanation.endswith("viac či menej ako darček.")
    # The saved question is never touched.
    assert (
        saved.question == "Kto poslal Harrymu sovu Hedvigu?"
        and not text_edits.edits(saved)
    )
    by_field = {e["field"]: e for e in text_edits.edits(new)}
    assert set(by_field) == {
        "correct_answer",
        "explanation",
    }  # unchanged stem not recorded
    answer = by_field["correct_answer"]
    assert (answer["step"], answer["before"], answer["after"]) == (
        "language_fix",
        "Hedwiga",
        "Hedviga",
    )
    assert answer["applied"] is True and answer["rejected"] is None
    assert answer["kinds"] == ["name"]
    assert by_field["explanation"]["kinds"] == ["punctuation"]
    assert answer["model"] == "claude-opus-5-5"
    assert result.info["checked"] == 1
    assert result.info["changed_questions"] == 1
    assert result.info["edits_applied"] == 2 and result.info["edits_rejected"] == 0
    assert result.info["kinds_applied"] == {"name": 1, "punctuation": 1}


async def test_an_answer_that_changes_meaning_or_a_changed_number_is_rejected() -> None:
    new = _q("Koľko nôh má pavúk?", answer="Pes", explanation="Pavúk má 8 nôh.")
    before = _snapshot([new])
    ctx = _ctx([new])
    checker = _Checker(
        _reply(
            {
                "index": 1,
                "ok": False,
                "problems": [{"kind": "grammar", "quote": "Pes"}],
                "rewrite": "Koľko nôh má pavúk?",
                "fields": {"answer": "Mačka", "explanation": "Pavúk má 6 nôh."},
            }
        )
    )

    result = await LanguageFixStage(checker).run(ctx, sink=None)

    edits = {e["field"]: e for e in text_edits.edits(new)}
    assert edits["correct_answer"]["rejected"] == "answer_meaning"
    assert edits["explanation"]["rejected"] == "numbers_changed"
    assert not any(e["applied"] for e in edits.values())
    # Originals kept: only the provenance record differs.
    after = _snapshot([new])[0]
    after.pop("generation_metadata"), before[0].pop("generation_metadata")
    assert after == before[0]
    assert result.info["edits_rejected"] == 2
    assert result.info["rejected_by"] == {"answer_meaning": 1, "numbers_changed": 1}
    assert result.info["changed_questions"] == 0


async def test_a_fix_that_breaks_a_child_band_cap_keeps_the_original() -> None:
    # kids_4_6: question at most 14 words.
    new = _q("Ako sa volá Harryho biela sova?", answer="Hedwiga")
    ctx = _ctx([new], audience="kids_4_6")
    long_stem = "Ako sa volá tá krásna biela snežná sova, ktorú Harry Potter dostal od Hagrida na narodeniny?"
    checker = _Checker(
        _reply(
            {
                "index": 1,
                "ok": False,
                "problems": [{"kind": "name", "quote": "Hedwiga"}],
                "rewrite": long_stem,
                "fields": {"answer": "Hedviga"},
            }
        )
    )

    result = await LanguageFixStage(checker).run(ctx, sink=None)

    assert new.question == "Ako sa volá Harryho biela sova?"
    assert (
        new.correct_answer == "Hedwiga"
    )  # all of the question's edits, not just the long one
    assert {e["rejected"] for e in text_edits.edits(new)} == {"kids_cap"}
    assert result.info["rejected_by"] == {"kids_cap": 2}


async def test_mcq_option_fix_moves_the_correct_answer_with_it() -> None:
    options = {"a": "Hedwiga", "b": "Errol", "c": "Prasiatko"}
    new = _q(
        "Ako sa volá Harryho sova?",
        answer="Hedwiga",
        possible_answers=options,
        type="text_multichoice",
    )
    ctx = _ctx([new])
    checker = _Checker(
        _reply(
            {
                "index": 1,
                "ok": False,
                "problems": [{"kind": "name", "quote": "Hedwiga"}],
                "rewrite": "Ako sa volá Harryho sova?",
                "fields": {"options": {"a": "Hedviga", "z": "invented"}},
            }
        )
    )

    await LanguageFixStage(checker).run(ctx, sink=None)

    assert new.possible_answers == {"a": "Hedviga", "b": "Errol", "c": "Prasiatko"}
    assert new.correct_answer == "Hedviga"
    assert [e["field"] for e in text_edits.edits(new)] == ["option:a", "correct_answer"]


@pytest.mark.parametrize("failure", ["no_answer", "garbage", "timeout", "apply_error"])
async def test_a_failing_language_pass_leaves_the_round_unchanged(
    failure: str, monkeypatch: pytest.MonkeyPatch
) -> None:
    new = [
        _q(OWL, explanation="Hedwiga, viac, či menej."),
        _q("Kto je Dobby?", answer="škriatok"),
    ]
    before = _snapshot(new)
    ctx = _ctx(list(new))
    good = _reply(
        {
            "index": 1,
            "ok": False,
            "problems": [{"kind": "name", "quote": "Hedwiga"}],
            "rewrite": OWL,
            "fields": {"answer": "Hedviga"},
        },
        {
            "index": 2,
            "ok": False,
            "problems": [{"kind": "grammar", "quote": "Dobby"}],
            "rewrite": "Kto je Dobby?",
            "fields": {"answer": "škriatok Dobby"},
        },
    )
    checker = {
        "no_answer": _Checker(None),
        "garbage": _Checker("{not json}"),
        "timeout": _Checker(good, delay=1.0),
        "apply_error": _Checker(good),
    }[failure]
    if failure == "timeout":
        monkeypatch.setattr(language_fix, "TIMEOUT_SECONDS", 0.01)
    if failure == "apply_error":
        # The first question is fixed, then recording the second one fails.
        real = text_edits.record
        calls = {"n": 0}

        def flaky(q, **kw):
            calls["n"] += 1
            if calls["n"] > 1:
                raise RuntimeError("boom")
            real(q, **kw)

        monkeypatch.setattr(language_fix.text_edits, "record", flaky)

    result = await LanguageFixStage(checker).run(ctx, sink=None)

    assert _snapshot(ctx.questions) == before
    assert result.info == {"failed": 1, "unchecked": 2}


async def test_packs_in_other_languages_are_not_sent_to_the_check() -> None:
    checker = _Checker(_reply())
    ctx = _ctx([_q("What is the owl called?")], language="en")

    result = await LanguageFixStage(checker).run(ctx, sink=None)

    assert checker.prompts == [] and result.info == {}


async def test_an_ok_verdict_changes_nothing_and_is_counted() -> None:
    new = _q(OWL, answer="Hedviga")
    ctx = _ctx([new])
    checker = _Checker(
        _reply({"index": 1, "ok": True, "problems": [], "rewrite": None})
    )

    result = await LanguageFixStage(checker).run(ctx, sink=None)

    assert text_edits.edits(new) == []
    assert result.info["checked"] == 1 and result.info["flagged"] == 0
