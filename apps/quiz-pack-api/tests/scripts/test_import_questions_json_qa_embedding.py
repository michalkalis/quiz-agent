"""#170 D2/D10 — `scripts/import_questions_json.py` fills `embedding_qa`.

Why: the QA dedup branch refuses to run over a corpus with rows that carry a
question embedding but no question+answer embedding. Every row that enters
the corpus through this importer must therefore land with BOTH vectors — or
each import would leave behind a paid backfill for someone to remember. The
second input text must be the shared `qa_text` (one definition for writers
and readers of the column), sent in the same batch call as the question text.

Live-DB test: needs TEST_DATABASE_URL; skipped otherwise.
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
import uuid
from pathlib import Path

import pytest
import scripts.import_questions_json as importer
from app.db.engine import normalize_async_url
from quiz_shared.utils.qa_text import qa_text
from sqlalchemy import text
from sqlalchemy.ext.asyncio import create_async_engine

APP_ROOT = Path(__file__).resolve().parents[2]


def _test_url() -> str:
    url = os.environ.get("TEST_DATABASE_URL") or os.environ.get("DATABASE_URL")
    if not url:
        pytest.skip("TEST_DATABASE_URL / DATABASE_URL not set")
    return url


@pytest.fixture(scope="module", autouse=True)
def _alembic_head() -> None:
    raw = _test_url()
    env = os.environ.copy()
    env["DATABASE_URL"] = raw
    subprocess.run(
        [sys.executable, "-m", "alembic", "upgrade", "head"],
        cwd=APP_ROOT,
        env=env,
        check=True,
        capture_output=True,
        text=True,
    )


@pytest.mark.asyncio
async def test_import_embeds_question_and_qa_text_in_one_batch(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    url = _test_url()
    ids = [str(uuid.uuid4()) for _ in range(2)]
    rows = [
        {
            "id": ids[0],
            "question": "Which element makes up most of the air we breathe?",
            "type": "text_multichoice",
            "possible_answers": {"a": "Oxygen", "b": "Nitrogen"},
            "correct_answer": "b",  # legacy option letter → resolved to option text
            "topic": "Science",
            "category": "science-nature",
            "difficulty": "easy",
        },
        {
            "id": ids[1],
            "question": "Which river flows through Vienna?",
            "correct_answer": "Danube",
            "topic": "Geography",
            "category": "travel-places",
            "difficulty": "easy",
        },
    ]
    path = tmp_path / "batch.json"
    path.write_text(importer.json.dumps(rows))

    calls: list[list[str]] = []

    def fake_embed_batch(client, texts: list[str]) -> list[list[float]]:
        calls.append(list(texts))
        vectors = []
        for i, _ in enumerate(texts):
            vec = [0.0] * importer.EMBEDDING_DIM
            vec[i] = 1.0
            vectors.append(vec)
        return vectors

    monkeypatch.setenv("OPENAI_API_KEY", "sk-test-placeholder")
    monkeypatch.setattr(importer, "OpenAI", lambda: object())
    monkeypatch.setattr(importer, "_embed_batch", fake_embed_batch)

    args = argparse.Namespace(
        json_path=[str(path)],
        database_url=url,
        review_status="pending_review",
        batch_size=100,
        dry_run=False,
        execute=True,
    )
    engine = create_async_engine(normalize_async_url(url))
    try:
        assert await importer._run(args) == 0

        # One call per batch, question texts first, then the SHARED qa_text
        # for the same rows in the same order — never a second definition.
        assert len(calls) == 1
        assert calls[0] == [
            rows[0]["question"],
            rows[1]["question"],
            qa_text(rows[0]["question"], "b", rows[0]["possible_answers"]),
            qa_text(rows[1]["question"], "Danube", None),
        ]
        assert calls[0][2].endswith("Answer: Nitrogen")

        async with engine.connect() as conn:
            result = await conn.execute(
                text(
                    "SELECT id::text, embedding IS NOT NULL AS has_q, "
                    "embedding_qa IS NOT NULL AS has_qa, embedding_model, "
                    "embedding_qa_model, embedding::text <> embedding_qa::text AS differ "
                    "FROM questions WHERE id = ANY(CAST(:ids AS uuid[]))"
                ),
                {"ids": ids},
            )
            landed = {r.id: r for r in result}
        assert set(landed) == set(ids)
        for r in landed.values():
            assert r.has_q and r.has_qa
            assert r.embedding_model == importer.EMBEDDING_MODEL
            assert r.embedding_qa_model == importer.EMBEDDING_MODEL
            assert r.differ  # the QA vector is its own embedding, not a copy
    finally:
        async with engine.begin() as conn:
            await conn.execute(
                text("DELETE FROM questions WHERE id = ANY(CAST(:ids AS uuid[]))"),
                {"ids": ids},
            )
        await engine.dispose()
