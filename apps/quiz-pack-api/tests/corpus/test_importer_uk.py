"""#231 — Ukrainian as a fourth language: what the importer lets through for uk.

Why: for sk/cs the naturalness verdict is a label written after the review
status, and that stays. For uk no native speaker reads the rows before they
would serve, so a row the editor flagged (``ok: false``) or never checked must
not come out machine-approved. And the reject tier of the uk topic policy (the
war since 2014, current politics) must never enter the corpus at all.
"""

from __future__ import annotations

import app.corpus.importer as lib
import pytest
from app.generation.naturalness_check import Naturalness, apply_naturalness

from tests.corpus import test_importer as base
from tests.corpus.test_importer import _clean, _FakeEngine, _id

fake_db = base.fake_db  # the recorder engine fixture, shared

_UK_QUESTION = "Яка планета обертається швидше за всіх? ({})"


def _uk(name: str, **overrides) -> dict:
    overrides.setdefault("question", _UK_QUESTION.format(name))
    return _clean(name, language="uk", **overrides)


class _Verdicts:
    """Gives each row the verdict named in ``ok_by_name``."""

    def __init__(self, ok_by_name: dict[str, bool]) -> None:
        self.ok = {_id(name): ok for name, ok in ok_by_name.items()}

    async def label(self, questions, batch_size=20):
        for q in questions:
            apply_naturalness(q, Naturalness(ok=self.ok[q.id]))
        return len(questions)


@pytest.fixture
def no_embedding(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("OPENAI_API_KEY", "sk-test")
    monkeypatch.setattr(lib, "OpenAI", lambda: object())
    monkeypatch.setattr(
        lib, "_embed_batch", lambda client, texts: [[0.1] * lib.EMBEDDING_DIM for _ in texts]
    )


@pytest.mark.asyncio
async def test_uk_needs_a_passing_naturalness_verdict_sk_does_not(
    fake_db: _FakeEngine, no_embedding: None, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("NATURALNESS_CHECK", "1")
    rows = [_uk("uk_ok"), _uk("uk_bad"), _clean("sk_bad", language="sk")]
    verdicts = _Verdicts({"uk_ok": True, "uk_bad": False, "sk_bad": False})

    result = await lib.import_questions(
        lib.parse_questions(rows, lib.AUTO_REVIEW_STATUS),
        database_url_or_engine=fake_db,
        execute=True,
        naturalness_checker=verdicts,
    )

    assert result.statuses[_id("uk_ok")] == "approved"
    assert result.statuses[_id("uk_bad")] == "pending_review"
    assert result.pending_reasons[_id("uk_bad")] == "naturalness=not_ok"
    # sk/cs unchanged: the verdict stays a label there.
    assert result.statuses[_id("sk_bad")] == "approved"
    assert (result.approved, result.pending) == (2, 1)
    assert result.block_reasons == {"naturalness=not_ok": 1}


@pytest.mark.asyncio
async def test_uk_without_a_verdict_stays_pending(
    fake_db: _FakeEngine, no_embedding: None, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The check switched off (or failed) must not read as "natural"."""
    monkeypatch.setenv("NATURALNESS_CHECK", "0")  # no live LLM call
    result = await lib.import_questions(
        lib.parse_questions([_uk("uk_unchecked")], lib.AUTO_REVIEW_STATUS),
        database_url_or_engine=fake_db,
        execute=True,
    )
    assert result.statuses[_id("uk_unchecked")] == "pending_review"
    assert result.pending_reasons[_id("uk_unchecked")] == "naturalness=missing"


@pytest.mark.asyncio
async def test_uk_reject_tier_never_enters_and_hold_tier_waits_for_a_human(
    fake_db: _FakeEngine,
) -> None:
    rows = [
        _uk("war", question="Яке місто 2022 року пережило облогу «Азовсталі»?"),
        _uk("mongols", question="Що сталося після монгольського вторгнення 1240 року?"),
    ]
    result = await lib.import_questions(
        lib.parse_questions(rows, lib.AUTO_REVIEW_STATUS),
        database_url_or_engine=fake_db,
        execute=False,
    )
    assert result.skipped[_id("war")].startswith("uk_policy=topic_policy:reject(")
    assert _id("war") not in result.statuses
    assert result.statuses[_id("mongols")] == "pending_review"
    assert result.pending_reasons[_id("mongols")].startswith(
        "uk_policy=topic_policy:hold("
    )
