"""Source-edit staleness and the approved-translation read path
(#168 — batch translation pipeline SK/CS, T13/DD3 + DD5).

WHY these tests: once serving is gated on `approved_languages`, the dangerous
state is an approved translation of English text that has since been edited.
Nothing about that state looks wrong — the gate says approved, the row exists,
the reconcile job would find column and table in perfect agreement — and the
player is simply told something the English question no longer says. The only
place that can notice is the write path that performs the edit, so these tests
pin the demotion to `PgvectorQuestionStore.upsert` and pin the *scope* of the
hash: a real wording change demotes, an unrelated admin touch must not (or the
next `set-category` sweep would wipe out a whole language's corpus).
"""

from __future__ import annotations

import os
import subprocess
import sys
import unicodedata
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import AsyncIterator

import pytest
import pytest_asyncio
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine, AsyncSession, async_sessionmaker

from app.db.engine import build_engine, normalize_async_url
from quiz_shared.database.pgvector_client import EMBEDDING_DIM, PgvectorQuestionStore
from quiz_shared.models.question import Question
from quiz_shared.utils.source_hash import compute_source_hash, source_hash_for

APP_ROOT = Path(__file__).resolve().parents[2]


def _test_url() -> str:
    url = os.environ.get("TEST_DATABASE_URL") or os.environ.get("DATABASE_URL")
    if not url:
        pytest.skip("TEST_DATABASE_URL / DATABASE_URL not set")
    return normalize_async_url(url)


@pytest.fixture(scope="module", autouse=True)
def _alembic_head() -> None:
    """Bring the test DB to head once per module so the tables exist."""
    raw = os.environ.get("TEST_DATABASE_URL") or os.environ.get("DATABASE_URL")
    if not raw:
        pytest.skip("TEST_DATABASE_URL / DATABASE_URL not set")
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


@pytest_asyncio.fixture
async def engine() -> AsyncIterator[AsyncEngine]:
    eng = build_engine(_test_url())
    try:
        yield eng
    finally:
        await eng.dispose()


@pytest_asyncio.fixture
async def factory(engine: AsyncEngine):
    return async_sessionmaker(engine, class_=AsyncSession, expire_on_commit=False)


@pytest_asyncio.fixture
async def store(factory) -> PgvectorQuestionStore:
    # Fixed embedder: nothing here is about semantics, and the OpenAI embedder
    # would make the suite non-hermetic.
    return PgvectorQuestionStore(
        session_factory=factory, embedder=lambda _t: [0.0] * EMBEDDING_DIM
    )


def _question(qid: uuid.UUID, *, stem: str, category: str = "hobbies-interests"):
    return Question(
        id=str(qid),
        question=stem,
        type="text",
        correct_answer="Italy",
        alternative_answers=["Italia"],
        explanation="Rosso corsa was Italy's national racing colour.",
        topic="motorsport",
        category=category,
        difficulty="medium",
        review_status="approved",
        source="generated",
        embedding=[0.0] * EMBEDDING_DIM,
        embedding_model="test-fixture",
        embedding_dim=EMBEDDING_DIM,
        created_at=datetime.now(timezone.utc),
    )


async def _seed_approved_translation(
    session: AsyncSession, qid: uuid.UUID, language: str, source_hash: str
) -> None:
    await session.execute(
        text(
            "INSERT INTO question_translations "
            "(id, question_id, language, status, question, correct_answer, "
            " alternative_answers, model, prompt_version, source_hash) "
            "VALUES (:id, :qid, :lang, 'approved', :q, :a, "
            " '[\"Italia\"]'::jsonb, 'test-model', 'v1', :h)"
        ),
        {
            "id": uuid.uuid4(),
            "qid": qid,
            "lang": language,
            "q": f"[{language}] Ktorá krajina?",
            "a": "Taliansko",
            "h": source_hash,
        },
    )
    await session.execute(
        text(
            "UPDATE questions SET approved_languages = "
            "array_append(approved_languages, :lang) WHERE id = :qid"
        ),
        {"lang": language, "qid": qid},
    )
    await session.commit()


async def _state(session: AsyncSession, qid: uuid.UUID):
    langs = await session.scalar(
        text("SELECT approved_languages FROM questions WHERE id = :qid"), {"qid": qid}
    )
    rows = (
        await session.execute(
            text(
                "SELECT language, status FROM question_translations "
                "WHERE question_id = :qid ORDER BY language"
            ),
            {"qid": qid},
        )
    ).all()
    return sorted(langs or []), {lang: status for lang, status in rows}


async def _cleanup(session: AsyncSession, qid: uuid.UUID) -> None:
    await session.execute(
        text("DELETE FROM questions WHERE id = :qid"), {"qid": qid}
    )
    await session.commit()


async def test_upsert_source_edit_demotes_translation(store, factory) -> None:
    """Editing the English stem must, in the same write, stop SK/CS serving.

    The gate is a materialized array, so an edit that left `approved_languages`
    alone would keep routing Slovak sessions to a translation of the *old*
    wording. Both legs are asserted because either one alone still serves: the
    row must go `stale` (system of record) AND the language must leave the
    column (retrieval index).
    """
    qid = uuid.uuid4()
    original = _question(qid, stem="Which country's racing colour was red?")
    async with factory() as session:
        try:
            assert await store.add(original) is True
            source_hash = source_hash_for(original)
            await _seed_approved_translation(session, qid, "sk", source_hash)
            await _seed_approved_translation(session, qid, "cs", source_hash)
            assert await _state(session, qid) == (
                ["cs", "sk"],
                {"cs": "approved", "sk": "approved"},
            )

            edited = _question(qid, stem="Which country's racing colour was rosso?")
            assert await store.upsert(edited) is True

            languages, statuses = await _state(session, qid)
            assert languages == []
            assert statuses == {"cs": "stale", "sk": "stale"}
        finally:
            await _cleanup(session, qid)


async def test_upsert_of_an_untranslated_field_keeps_the_translation(
    store, factory
) -> None:
    """A category re-map must not demote a perfectly good translation.

    `POST /questions/set-category` sweeps the corpus; if the hash covered
    fields nobody translates, one taxonomy pass would invalidate every
    translation in the corpus and silently take a whole language offline.
    """
    qid = uuid.uuid4()
    original = _question(qid, stem="Which country's racing colour was red?")
    async with factory() as session:
        try:
            assert await store.add(original) is True
            await _seed_approved_translation(
                session, qid, "sk", source_hash_for(original)
            )

            recategorized = _question(
                qid,
                stem="Which country's racing colour was red?",
                category="science-tech",
            )
            assert await store.upsert(recategorized) is True

            assert await _state(session, qid) == (["sk"], {"sk": "approved"})
        finally:
            await _cleanup(session, qid)


async def test_get_translations_returns_only_approved_rows(store, factory) -> None:
    """The serve read must ignore non-approved rows and other languages.

    A missing key is how the retriever learns to *drop* a candidate (DD5). If
    this returned a `pending` or `stale` row, the drop would never happen and
    unverified text would reach a player behind a passing gate.
    """
    approved_qid = uuid.uuid4()
    stale_qid = uuid.uuid4()
    approved = _question(approved_qid, stem="Approved question?")
    stale = _question(stale_qid, stem="Stale question?")
    async with factory() as session:
        try:
            assert await store.add(approved) is True
            assert await store.add(stale) is True
            await _seed_approved_translation(
                session, approved_qid, "sk", source_hash_for(approved)
            )
            await _seed_approved_translation(
                session, stale_qid, "sk", source_hash_for(stale)
            )
            await session.execute(
                text(
                    "UPDATE question_translations SET status = 'stale' "
                    "WHERE question_id = :qid"
                ),
                {"qid": stale_qid},
            )
            await session.commit()

            found = await store.get_translations(
                [str(approved_qid), str(stale_qid)], "sk"
            )
            assert set(found) == {str(approved_qid)}
            assert found[str(approved_qid)]["correct_answer"] == "Taliansko"
            assert found[str(approved_qid)]["alternative_answers"] == ["Italia"]

            assert await store.get_translations([str(approved_qid)], "cs") == {}
        finally:
            await _cleanup(session, approved_qid)
            await _cleanup(session, stale_qid)


def test_source_hash_ignores_cosmetic_churn_but_not_wording() -> None:
    """Whitespace and Unicode form are not edits; a changed word is.

    Without normalization, an editor that saves decomposed accents or a trailing
    space would demote every translation it touched — the pipeline would spend
    real money retranslating text that did not change, and the founder would
    learn to ignore staleness reports.
    """
    base = dict(
        question="Aká je najvyššia hora?",
        possible_answers={"a": "Gerlach", "b": "Kriváň"},
        correct_answer="Gerlach",
        alternative_answers=["Gerlachovský štít"],
        explanation=None,
    )
    # Same text: padded with whitespace and with decomposed (NFD) accents.
    cosmetic = dict(
        base,
        question=unicodedata.normalize("NFD", "  Aká je najvyššia hora?  "),
    )
    assert compute_source_hash(**base) == compute_source_hash(**cosmetic)

    # `None` explanation and `""` explanation are the same absence of text.
    empty_explanation = dict(base, explanation="")
    assert compute_source_hash(**base) == compute_source_hash(**empty_explanation)

    # A real wording change is a different question.
    reworded = dict(base, question="Aká je najvyššia hora Slovenska?")
    assert compute_source_hash(**base) != compute_source_hash(**reworded)

    # So is a changed distractor: the translation of the options is now wrong.
    redistracted = dict(base)
    redistracted["possible_answers"] = {"a": "Gerlach", "b": "Rysy"}
    assert compute_source_hash(**base) != compute_source_hash(**redistracted)
