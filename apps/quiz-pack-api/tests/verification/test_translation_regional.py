"""#168 — batch translation pipeline SK/CS: the regional flag is a flag.

Locked decision 3(d) says regional relevance FLAGS and never drops. That is a
one-word difference from "rejects" and exactly the kind of rule that erodes
the first time someone adds a filter, so it is pinned structurally here: the
approval decision has no way to read the flag, and the flag's only job is to
land in ``question_translations.verification`` for the human review loop.
"""

from __future__ import annotations

import inspect

import pytest
from app.translation_verification.judge import JudgeResult, approval_status
from app.translation_verification.regional import RegionalClassifier, RegionalRelevance


class _FakeMessage:
    def __init__(self, text: str) -> None:
        self.content = text


def _classifier_returning(raw: str | None) -> RegionalClassifier:
    classifier = RegionalClassifier(model="gpt-4o-mini")

    class _Client:
        def __init__(self) -> None:
            self.prompts: list[str] = []

        async def ainvoke(self, prompt: str):
            self.prompts.append(prompt)
            if raw is None:
                raise RuntimeError("provider down")
            return _FakeMessage(raw)

    classifier._client = _Client()
    return classifier


def test_regional_flag_never_blocks_approval() -> None:
    """A regionally irrelevant row still reaches ``approved`` when the three
    blocking stages pass — and cannot do otherwise, because ``approval_status``
    takes no regional argument at all (locked decision 3(d))."""
    flagged = RegionalRelevance(True, "Assumes knowledge of US state capitals.")

    status = approval_status(
        guards_ok=True, answerable=True, judge=JudgeResult(verdict="ok")
    )
    assert status == "approved"

    # Structural guarantee: there is no parameter through which the flag could
    # ever reach the decision, so no future caller can wire it in by accident.
    params = set(inspect.signature(approval_status).parameters)
    assert params == {"guards_ok", "answerable", "judge"}
    assert not any("regional" in p for p in params)
    assert flagged.flag is True  # the row was flagged and still approved


def test_regional_flag_and_reason_persisted_in_verification_json() -> None:
    """The flag is only useful if the reason survives into the row's
    ``verification`` JSONB — that is what the rating web shows a reviewer.
    A bare boolean would make the flag unactionable."""
    result = RegionalRelevance(True, "Asks about a Bundesliga club's home city.")
    payload = result.as_verification_json()

    assert payload == {
        "regional": {
            "flag": True,
            "reason": "Asks about a Bundesliga club's home city.",
        }
    }
    # It must be JSON-serialisable as-is: this dict goes straight into JSONB.
    import json

    assert json.loads(json.dumps(payload))["regional"]["reason"]


@pytest.mark.asyncio
async def test_flags_regionally_specific_question() -> None:
    classifier = _classifier_returning(
        '{"regionally_specific": true, "reason": "US high-school curriculum."}'
    )
    result = await classifier.classify("Which US state has the most counties?", "sk")
    assert result.flag is True
    assert "curriculum" in result.reason
    assert "Slovak" in classifier._client.prompts[0]  # type: ignore[attr-defined]


@pytest.mark.asyncio
async def test_failed_call_is_fail_safe_not_fail_closed() -> None:
    """The opposite of ``ShapeClassifier``: this classifier's failure must not
    hold a row. Holding a translation because a *curation hint* was unavailable
    would be the auto-drop locked decision 3(d) forbids."""
    for raw in (None, "the model rambled without JSON"):
        result = await _classifier_returning(raw).classify("Any question?", "cs")
        assert result.flag is False
        assert result.reason  # the reason records WHY it is not flagged
