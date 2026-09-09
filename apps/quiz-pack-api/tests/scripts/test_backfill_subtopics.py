"""`scripts/backfill_subtopics.py` (#170 task 170.7, A4).

Why these tests matter:
- The backfill is the only thing standing between "coverage steering" and
  "random subtopic": with every row NULL, `1/(count + K)` is uniform by
  construction, so the quality guard would measure nothing (D3/D4/B2).
- It is a class `b` script the founder runs against PROD. A preview run
  that quietly wrote rows, or an `--apply` that stored a subtopic the
  founder never approved, would corrupt the corpus in a way no later
  session can distinguish from a real classification — so the preview leg
  and the closed-taxonomy leg are hard failures, not warnings.
- Customer packs are independent of the corpus (locked 3): a pack row must
  never be sent to the model nor updated.

The LLM is mocked in every test. Live-DB tests need TEST_DATABASE_URL
(`make dev-db`); skipped otherwise.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import uuid
from pathlib import Path

import pytest
import pytest_asyncio
import scripts.backfill_subtopics as bs
from app.db.engine import build_engine, normalize_async_url
from app.db.models import GenerationOrder, QuestionPack, QuestionRow
from app.generation.subtopics import subtopics_for
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine, AsyncSession, async_sessionmaker

APP_ROOT = Path(__file__).resolve().parents[2]
TAG = "170-subtopic-backfill-test"
CATEGORY = "science-nature"


def _raw_url() -> str:
    url = os.environ.get("TEST_DATABASE_URL") or os.environ.get("DATABASE_URL")
    if not url:
        pytest.skip("TEST_DATABASE_URL / DATABASE_URL not set")
    return url


@pytest.fixture(scope="module", autouse=True)
def _alembic_head() -> None:
    env = os.environ.copy()
    env["DATABASE_URL"] = _raw_url()
    subprocess.run(
        [sys.executable, "-m", "alembic", "upgrade", "head"],
        cwd=APP_ROOT,
        env=env,
        check=True,
        capture_output=True,
        text=True,
    )


@pytest_asyncio.fixture
async def engine() -> AsyncEngine:
    eng = build_engine(normalize_async_url(_raw_url()))
    try:
        async with eng.begin() as conn:
            await conn.execute(
                text("DELETE FROM questions WHERE topic = :t"), {"t": TAG}
            )
        yield eng
        async with eng.begin() as conn:
            await conn.execute(
                text("DELETE FROM questions WHERE topic = :t"), {"t": TAG}
            )
    finally:
        await eng.dispose()


def _row(**overrides) -> QuestionRow:
    data = {
        "id": uuid.uuid4(),
        "question": "Which planet is closest to the Sun?",
        "type": "text",
        "correct_answer": "Mercury",
        "topic": TAG,
        "category": CATEGORY,
        "difficulty": "easy",
        "language": "en",
        "review_status": "approved",
    }
    data.update(overrides)
    return QuestionRow(**data)


async def _seed(engine: AsyncEngine) -> tuple[uuid.UUID, uuid.UUID, uuid.UUID]:
    """Two live corpus rows + one customer-pack row in the same category."""
    factory = async_sessionmaker(engine, class_=AsyncSession, expire_on_commit=False)
    async with factory() as session:
        order = GenerationOrder(
            transaction_id=f"{TAG}-{uuid.uuid4().hex}",
            product_id="pack_10",
            prompt=TAG,
            target_count=1,
            language="en",
            status="in_progress",
        )
        session.add(order)
        await session.flush()
        pack = QuestionPack(
            order_id=order.id, prompt=TAG, language="en", target_count=1
        )
        session.add(pack)
        await session.flush()

        corpus_a = _row()
        corpus_b = _row(
            question="What gas do plants absorb from the air?",
            correct_answer="Carbon dioxide",
        )
        pack_row = _row(
            question="Which pack question must never be classified?",
            pack_id=pack.id,
        )
        session.add_all([corpus_a, corpus_b, pack_row])
        await session.commit()
        return corpus_a.id, corpus_b.id, pack_row.id


async def _get(engine: AsyncEngine, row_id: uuid.UUID) -> QuestionRow:
    factory = async_sessionmaker(engine, class_=AsyncSession, expire_on_commit=False)
    async with factory() as session:
        row = await session.get(QuestionRow, row_id)
        assert row is not None
        return row


def _fake_classifier(subtopic: str, seen: list[list[str]]):
    """A `classify_batch` double that files every row under one subtopic."""

    async def fake(llm, category, language, approved, rows):
        seen.append([question for _id, question, _a in rows])
        return bs.SubtopicBatch(
            assignments=[
                bs.SubtopicAssignment(index=i, subtopic=subtopic)
                for i in range(len(rows))
            ]
        )

    return fake


def _cli(out: Path, *extra: str) -> list[str]:
    return [
        "--database-url",
        _raw_url(),
        "--out",
        str(out),
        "--category",
        CATEGORY,
        *extra,
    ]


# ── preview vs apply (live DB) ──────────────────────────────────────────────


@pytest.mark.asyncio
async def test_preview_run_writes_the_json_and_leaves_the_db_untouched(
    engine: AsyncEngine, tmp_path, monkeypatch
) -> None:
    """Without --apply nothing is written: the founder reviews first (class `b`)."""
    a, b, _pack = await _seed(engine)
    approved = subtopics_for(CATEGORY)[0]
    seen: list[list[str]] = []
    monkeypatch.setattr(bs, "classify_batch", _fake_classifier(approved, seen))
    monkeypatch.setattr(bs, "_build_llm", lambda model: object())
    out = tmp_path / "preview.json"

    assert await bs.run_cli(_cli(out)) == 0

    payload = json.loads(out.read_text())
    assert payload["applied"] is False
    ids = {item["id"] for item in payload["categories"][CATEGORY]}
    assert {str(a), str(b)} <= ids
    assert all(item["subtopic"] == approved for item in payload["categories"][CATEGORY])
    assert (await _get(engine, a)).subtopic is None
    assert (await _get(engine, b)).subtopic is None


@pytest.mark.asyncio
async def test_apply_writes_the_subtopic_and_a_second_run_sends_nothing(
    engine: AsyncEngine, tmp_path, monkeypatch
) -> None:
    """--apply persists the cell; already-classified rows are never re-sent (idempotent)."""
    a, b, _pack = await _seed(engine)
    approved = subtopics_for(CATEGORY)[0]
    seen: list[list[str]] = []
    monkeypatch.setattr(bs, "classify_batch", _fake_classifier(approved, seen))
    monkeypatch.setattr(bs, "_build_llm", lambda model: object())

    assert await bs.run_cli(_cli(tmp_path / "applied.json", "--apply")) == 0
    assert (await _get(engine, a)).subtopic == approved
    assert (await _get(engine, b)).subtopic == approved
    assert json.loads((tmp_path / "applied.json").read_text())["applied"] is True

    seen.clear()
    assert await bs.run_cli(_cli(tmp_path / "second.json", "--apply")) == 0
    assert seen == []  # no row left to classify → no LLM call at all
    assert json.loads((tmp_path / "second.json").read_text())["total"] == 0


@pytest.mark.asyncio
async def test_out_of_list_subtopic_exits_1_and_writes_nothing(
    engine: AsyncEngine, tmp_path, monkeypatch
) -> None:
    """The taxonomy is closed (locked 5): an invented subtopic aborts the run."""
    a, b, _pack = await _seed(engine)
    seen: list[list[str]] = []
    monkeypatch.setattr(bs, "classify_batch", _fake_classifier("Quantum llamas", seen))
    monkeypatch.setattr(bs, "_build_llm", lambda model: object())
    out = tmp_path / "rejected.json"

    assert await bs.run_cli(_cli(out, "--apply")) == 1

    assert not out.exists()  # no preview either — a rejected run leaves no trace
    assert (await _get(engine, a)).subtopic is None
    assert (await _get(engine, b)).subtopic is None


@pytest.mark.asyncio
async def test_pack_rows_are_never_sent_to_the_model_nor_updated(
    engine: AsyncEngine, tmp_path, monkeypatch
) -> None:
    """Locked 3: custom packs are independent of the corpus (`pack_id IS NULL`)."""
    _a, _b, pack_row = await _seed(engine)
    approved = subtopics_for(CATEGORY)[0]
    seen: list[list[str]] = []
    monkeypatch.setattr(bs, "classify_batch", _fake_classifier(approved, seen))
    monkeypatch.setattr(bs, "_build_llm", lambda model: object())

    assert await bs.run_cli(_cli(tmp_path / "packs.json", "--apply")) == 0

    sent = [q for batch in seen for q in batch]
    assert "Which pack question must never be classified?" not in sent
    assert (await _get(engine, pack_row)).subtopic is None


@pytest.mark.asyncio
async def test_archived_rows_are_not_part_of_the_live_corpus(
    engine: AsyncEngine, tmp_path, monkeypatch
) -> None:
    """Gate F1 R2: live = approved + pending_review; archived rows skew no cell."""
    await _seed(engine)
    factory = async_sessionmaker(engine, class_=AsyncSession, expire_on_commit=False)
    async with factory() as session:
        session.add(_row(question="Archived question?", review_status="archived"))
        await session.commit()
    approved = subtopics_for(CATEGORY)[0]
    seen: list[list[str]] = []
    monkeypatch.setattr(bs, "classify_batch", _fake_classifier(approved, seen))
    monkeypatch.setattr(bs, "_build_llm", lambda model: object())

    assert await bs.run_cli(_cli(tmp_path / "live.json")) == 0
    assert "Archived question?" not in [q for batch in seen for q in batch]


# ── unit (no DB) ────────────────────────────────────────────────────────────


def _rows(n: int) -> list[tuple]:
    return [(uuid.uuid4(), f"Q{i}?", f"A{i}") for i in range(n)]


def test_resolve_accepts_case_and_whitespace_but_stores_the_approved_spelling() -> None:
    """A model echoing sloppy casing is not an invented subtopic — but the DB gets the canonical name."""
    approved = list(subtopics_for(CATEGORY)[:2])
    rows = _rows(2)
    batch = bs.SubtopicBatch(
        assignments=[
            bs.SubtopicAssignment(index=0, subtopic=f"  {approved[0].upper()} "),
            bs.SubtopicAssignment(index=1, subtopic=approved[1]),
        ]
    )
    resolved = bs.resolve_assignments(batch, rows, approved, CATEGORY)
    assert [s for _id, _q, s in resolved] == approved


def test_resolve_rejects_a_skipped_row() -> None:
    """A partial batch would silently leave holes in the coverage map."""
    approved = list(subtopics_for(CATEGORY)[:1])
    batch = bs.SubtopicBatch(
        assignments=[bs.SubtopicAssignment(index=0, subtopic=approved[0])]
    )
    with pytest.raises(bs.BackfillError, match="unclassified"):
        bs.resolve_assignments(batch, _rows(2), approved, CATEGORY)


def test_resolve_rejects_a_duplicated_index() -> None:
    """Two verdicts for one row means the mapping is not trustworthy at all."""
    approved = list(subtopics_for(CATEGORY)[:2])
    batch = bs.SubtopicBatch(
        assignments=[
            bs.SubtopicAssignment(index=0, subtopic=approved[0]),
            bs.SubtopicAssignment(index=0, subtopic=approved[1]),
        ]
    )
    with pytest.raises(bs.BackfillError, match="twice"):
        bs.resolve_assignments(batch, _rows(1), approved, CATEGORY)


def test_unknown_category_is_refused_before_any_call(tmp_path, monkeypatch) -> None:
    """Never steer by a taxonomy that does not exist — `general` has no approved list."""

    def boom(model):
        raise AssertionError("LLM built for a category outside the taxonomy")

    monkeypatch.setattr(bs, "_build_llm", boom)
    args = [
        "--database-url",
        "postgresql+asyncpg://unused/unused",
        "--out",
        str(tmp_path / "nope.json"),
        "--category",
        "general",
    ]
    assert bs.main(args) == 1
    assert not (tmp_path / "nope.json").exists()


def test_prompt_carries_the_full_approved_list_verbatim() -> None:
    """The model can only copy a name it was shown; a trimmed list invites invention."""
    approved = subtopics_for(CATEGORY)
    messages = bs.build_messages(CATEGORY, "en", approved, _rows(2))
    human = messages[-1].content
    assert all(name in human for name in approved)
    assert "0. Q0?" in human and "1. Q1?" in human
