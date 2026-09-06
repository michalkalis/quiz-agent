"""#168 — batch translation pipeline SK/CS: the MQM-Quiz judge's contract.

The judge's *accuracy* is measured by ``scripts/translation_judge_eval.py``
against the DD6 reference sets — that is a live-model job and does not belong
in a unit test. What is pinned here is the contract the gate depends on and
that a model can never demonstrate:

- **Fail-closed** (adopted from ``fact_verifier``): a dead call or an
  unparseable reply holds the row. It must never read as "this translation is
  fine", because an unjudged row would otherwise be approved on silence.
- **Critical blocks approval**, major/minor do not — that is the whole point of
  the severity taxonomy.
- The prompt carries both sides plus the reviewed glossary; a judge that only
  saw the target would be a proofreader, not a translation judge.
"""

from __future__ import annotations

import json

import pytest
from app.translation_verification import judge as judge_module
from app.translation_verification.judge import (
    JudgeResult,
    TranslationJudge,
    approval_status,
)

SOURCE = {
    "question": "Which river flows through Prague?",
    "possible_answers": {"a": "The Vltava", "b": "The Elbe"},
    "correct_answer": "The Vltava",
    "correct_answer_key": "a",
    "explanation": "The Vltava runs through Prague.",
}
TARGET = {
    "question": "Která řeka protéká Prahou?",
    "possible_answers": {"a": "Vltava", "b": "Labe"},
    "correct_answer": "Labe",
    "correct_answer_key": "b",
    "explanation": "Labe protéká Prahou.",
}


class _FakeMessage:
    def __init__(self, text: str) -> None:
        self.content = text


def _judge_returning(raw: str | None) -> TranslationJudge:
    judge = TranslationJudge(model="gpt-4o-mini")

    class _Client:
        def __init__(self) -> None:
            self.prompts: list[str] = []

        async def ainvoke(self, prompt: str):
            self.prompts.append(prompt)
            if raw is None:
                raise RuntimeError("provider down")
            return _FakeMessage(raw)

    judge._client = _Client()
    return judge


@pytest.mark.asyncio
async def test_prompt_carries_both_sides_and_the_glossary() -> None:
    judge = _judge_returning('{"findings": [], "overall": "ok"}')
    await judge.judge(SOURCE, TARGET, "cs")
    prompt = judge._client.prompts[0]  # type: ignore[attr-defined]
    assert "Which river flows through Prague?" in prompt
    assert "Která řeka protéká Prahou?" in prompt
    # Answer keys on both sides: an answer_flip is invisible without them.
    assert "correct_answer_key: a" in prompt and "correct_answer_key: b" in prompt
    assert "Czech" in prompt and "GLOSSARY" in prompt


@pytest.mark.asyncio
@pytest.mark.parametrize("raw", [None, "", "no json here", '{"overall": "ok"}'])
async def test_unavailable_or_unparseable_judge_holds_the_row(raw) -> None:
    """Fail-closed: silence is not approval. Note the last case — a reply with
    a verdict but no ``findings`` key is unparseable, not "no defects"."""
    result = await _judge_returning(raw).judge(SOURCE, TARGET, "sk")
    assert result.verdict == "unverified"
    assert result.held_for_review is True
    assert result.blocks_approval is True
    assert approval_status(guards_ok=True, answerable=True, judge=result) == "pending"


@pytest.mark.asyncio
async def test_critical_finding_blocks_and_lesser_findings_do_not() -> None:
    critical = await _judge_returning(
        json.dumps(
            {
                "findings": [
                    {
                        "category": "answer_flip",
                        "severity": "critical",
                        "span": "Labe",
                        "note": "The correct answer moved to the wrong option.",
                    }
                ],
                "overall": "defects",
            }
        )
    ).judge(SOURCE, TARGET, "cs")
    assert critical.verdict == "defects" and critical.has_critical
    assert approval_status(guards_ok=True, answerable=True, judge=critical) == "rejected"

    minor = await _judge_returning(
        json.dumps(
            {
                "findings": [
                    {
                        "category": "register_calque",
                        "severity": "minor",
                        "span": "protéká",
                        "note": "Stiff register.",
                    }
                ],
                "overall": "defects",
            }
        )
    ).judge(SOURCE, TARGET, "cs")
    assert minor.verdict == "defects" and not minor.has_critical
    # Style is review material, not a gate: the row still ships.
    assert approval_status(guards_ok=True, answerable=True, judge=minor) == "approved"


@pytest.mark.asyncio
async def test_unknown_severity_is_read_as_blocking() -> None:
    """A model that invents a severity label ("blocker", "high") has still said
    it found something. Downgrading that to "ignore" would let a defect through
    on a wording accident, so the safe reading is the blocking one."""
    result = await _judge_returning(
        '{"findings": [{"category": "other", "severity": "blocker", '
        '"span": "x", "note": "y"}], "overall": "defects"}'
    ).judge(SOURCE, TARGET, "sk")
    assert result.findings[0].severity == "critical"
    assert result.blocks_approval is True


@pytest.mark.asyncio
async def test_clean_translation_approves_and_serialises() -> None:
    result = await _judge_returning(
        '```json\n{"findings": [], "overall": "ok"}\n```'
    ).judge(SOURCE, TARGET, "sk")
    assert result.verdict == "ok" and not result.blocks_approval
    assert approval_status(guards_ok=True, answerable=True, judge=result) == "approved"
    # The verification fragment goes straight into JSONB.
    assert json.loads(json.dumps(result.as_verification_json()))["verdict"] == "ok"


@pytest.mark.asyncio
async def test_guard_or_answerability_failure_rejects_even_with_a_clean_judge() -> None:
    """The judge is one of three blocking stages, not the only one."""
    clean = JudgeResult(verdict="ok")
    assert approval_status(guards_ok=False, answerable=True, judge=clean) == "rejected"
    assert approval_status(guards_ok=True, answerable=False, judge=clean) == "rejected"


def test_glossary_files_exist_and_are_never_written_by_the_judge() -> None:
    """DD3: the glossary is a reviewed git artefact. An auto-derived one would
    feed unreviewed corrections back into the gate, so the module only reads
    it — and a broken file degrades to "no entries", never to an exception."""
    for language in ("sk", "cs"):
        assert judge_module.load_glossary(language) == []
        path = judge_module._GLOSSARY_DIR / f"{language}.json"
        assert path.exists()
        assert "entries" in json.loads(path.read_text(encoding="utf-8"))
    assert judge_module.load_glossary("de") == []  # missing file, no crash
