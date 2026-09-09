"""``ingest`` writes pending rows with the per-question cost share (T15, DD9).

Why it matters: "translate in batches as testers grow" is an unpriced decision
unless every row carries its share of the batch spend; and an unreadable
usage number must land as NULL, never a fake 0 that prices translation as free.
Ingest is also the ONLY writer of translation rows, so its idempotence is what
lets a killed job re-enter without duplicating.
"""

from __future__ import annotations

import uuid
from decimal import Decimal
from pathlib import Path

import pytest
from scripts.translation_runner import workset as ws
from scripts.translation_runner.translate import ingest_job
from sqlalchemy import text

from tests.scripts.conftest import delete_questions, make_question

pytestmark = pytest.mark.asyncio


def _job(tmp_path: Path, job_id: str, qids: list[uuid.UUID], cost_usd) -> ws.Job:
    job = ws.Job(job_id, jobs_dir=tmp_path)
    job.append({"kind": "meta", "language": "sk", "model": "session:opus"})
    for qid in qids:
        job.append(
            {
                "kind": "translation",
                "qid": str(qid),
                "language": "sk",
                "payload": {
                    "question": "Ktorá krajina?",
                    "possible_answers": None,
                    "correct_answer": "Taliansko",
                    "alternative_answers": ["Itália"],
                    "explanation": "Rosso corsa.",
                    "headline_answer": None,
                },
                "model": "session:opus",
                "transport": "session",
                "prompt_version": "corpus-v1",
                "source_hash": "a" * 64,
                "correct_answer_key": None,
            }
        )
    job.append({"kind": "cost", "usd": cost_usd, "n_requests": len(qids)})
    return job


async def test_batch_cost_is_persisted_per_question_to_cost_cents(
    translation_engine, question_store, tmp_path
) -> None:
    qids = [uuid.uuid4() for _ in range(3)]
    for qid in qids:
        assert await question_store.add(make_question(qid)) is True
    try:
        # $0.03 over 3 questions → 1.0000 cent each.
        job = _job(tmp_path, "sk-cost", qids, 0.03)
        assert await ingest_job(translation_engine, job, log=lambda _m: None) == 3
        async with translation_engine.connect() as conn:
            rows = (
                await conn.execute(
                    text(
                        "SELECT status, cost_cents, source_hash, batch_id "
                        "FROM question_translations WHERE question_id = ANY(:ids)"
                    ),
                    {"ids": qids},
                )
            ).all()
        assert len(rows) == 3
        assert {r.status for r in rows} == {"pending"}
        assert {r.cost_cents for r in rows} == {Decimal("1.0000")}
        assert {r.batch_id for r in rows} == {"sk-cost"}
        assert all(r.source_hash == "a" * 64 for r in rows)

        # Re-running ingest is a no-op: the JSONL remembers what landed.
        assert await ingest_job(translation_engine, job, log=lambda _m: None) == 0

        # An unavailable usage read stores NULL, never a fake 0 (DD9).
        job2 = _job(tmp_path, "sk-nocost", qids[:1], None)
        assert await ingest_job(translation_engine, job2, log=lambda _m: None) == 1
        async with translation_engine.connect() as conn:
            cents = (
                await conn.execute(
                    text(
                        "SELECT cost_cents FROM question_translations "
                        "WHERE question_id = :qid AND language = 'sk'"
                    ),
                    {"qid": qids[0]},
                )
            ).scalar_one()
        assert cents is None
    finally:
        await delete_questions(translation_engine, qids)
