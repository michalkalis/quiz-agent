"""``reconcile`` staleness leg (T17, DD1/DD3).

Why it matters: a consistency-only reconcile passes happily on a stale row —
column and table agree with each other and are both wrong about the English
text. The staleness leg is the backstop for writers that bypass the store, and
it must demote in one transaction so the gate never serves the old text.
"""

from __future__ import annotations

import uuid

import pytest
from scripts.translation_runner.reconcile import reconcile
from sqlalchemy import text

from tests.scripts.conftest import delete_questions, make_question

pytestmark = pytest.mark.asyncio


async def _seed_approved(engine, qid: uuid.UUID, source_hash: str) -> None:
    async with engine.begin() as conn:
        await conn.execute(
            text(
                "INSERT INTO question_translations (id, question_id, language, status, "
                "question, correct_answer, alternative_answers, model, prompt_version, "
                "source_hash) VALUES (:id, :qid, 'sk', 'approved', 'Ktorá krajina?', "
                "'Taliansko', '[]'::jsonb, 'test', 'v1', :h)"
            ),
            {"id": uuid.uuid4(), "qid": qid, "h": source_hash},
        )
        await conn.execute(
            text("UPDATE questions SET approved_languages = '{sk}' WHERE id = :qid"),
            {"qid": qid},
        )


async def test_stale_source_hash_demotes_and_exits_nonzero(
    translation_engine, question_store
) -> None:
    qid = uuid.uuid4()
    assert await question_store.add(make_question(qid)) is True
    try:
        await _seed_approved(translation_engine, qid, "0" * 64)  # not the real hash
        findings = await reconcile(translation_engine, "sk")
        assert findings.clean is False
        assert [f["qid"] for f in findings.stale] == [str(qid)]
        assert findings.stale[0]["old_hash"] == "0" * 64
        assert findings.consistency == []  # demotion kept column ⇔ table
        async with translation_engine.connect() as conn:
            status, langs = (
                await conn.execute(
                    text(
                        "SELECT t.status, q.approved_languages FROM question_translations t "
                        "JOIN questions q ON q.id = t.question_id WHERE t.question_id = :qid"
                    ),
                    {"qid": qid},
                )
            ).one()
        assert status == "stale" and langs == []
        # Second pass: nothing left to find.
        assert (await reconcile(translation_engine, "sk")).clean is True
    finally:
        await delete_questions(translation_engine, [qid])


async def test_consistency_mismatch_is_reported_and_fixed_on_request(
    translation_engine, question_store
) -> None:
    qid = uuid.uuid4()
    assert await question_store.add(make_question(qid)) is True
    try:
        async with translation_engine.begin() as conn:
            await conn.execute(
                text(
                    "UPDATE questions SET approved_languages = '{sk}' WHERE id = :qid"
                ),
                {"qid": qid},
            )
        findings = await reconcile(translation_engine, "sk")
        assert [f["qid"] for f in findings.consistency] == [str(qid)]
        assert (await reconcile(translation_engine, "sk", fix=True)).clean is False
        assert (await reconcile(translation_engine, "sk")).clean is True
    finally:
        await delete_questions(translation_engine, [qid])
