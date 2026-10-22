"""`app.corpus.importer` — the importer core shared by the CLI and the weekly job (#202).

Why these tests exist: the weekly job (#202) auto-publishes what this code
approves, with nobody reading the rows first. The move out of the CLI must not
change a single status decision, and the two fail-closed rules that protect the
App Store corpus (no source -> never approved, held/failed rows never enter)
must hold on the function path exactly as on the CLI path.

DB and OpenAI are faked: the engine is a recorder, `_existing_ids` is stubbed.
"""

from __future__ import annotations

import json
import uuid
from contextlib import asynccontextmanager
from datetime import UTC, datetime
from pathlib import Path

import app.corpus.importer as lib
import pytest
import scripts.import_questions_json as cli
from app.db.models.question import question_to_row
from app.scoring.machine_approval import GATE_VERSION
from quiz_shared.models.question import Question

UNTIL = datetime(2027, 3, 15, tzinfo=UTC)


def _id(name: str) -> str:
    """Stable UUID per readable name (the INSERT path needs real UUIDs)."""
    return str(uuid.uuid5(uuid.NAMESPACE_DNS, name))


def _clean(qid: str, language: str = "en", **overrides) -> dict:
    row = {
        "id": _id(qid),
        "question": f"Which planet in our solar system spins fastest on its axis? ({qid})",
        "correct_answer": "Jupiter",
        "topic": "Space",
        "category": "entertainment",
        "difficulty": "medium",
        "language": language,
        "source_url": "https://en.wikipedia.org/wiki/Jupiter",
        "generation_metadata": {
            "extra": {"verified": True, "verification_score": 0.9, "factcheck_tier": "web"}
        },
    }
    row.update(overrides)
    return row


def _fixture_rows() -> list[dict]:
    held = _clean("q_held")
    held["generation_metadata"]["extra"]["held_for_review"] = True
    return [
        _clean("q_en"),
        _clean("q_sk", language="sk"),  # native sk rows are approvable (#177)
        _clean("q_cs", language="cs"),
        _clean("q_nosrc", source_url=None),
        _clean("q_de", language="de"),
        held,
    ]


class _FakeConn:
    def __init__(self, sink: list) -> None:
        self._sink = sink

    async def execute(self, stmt):
        self._sink.append(stmt)

        class _Res:
            rowcount = 1

        return _Res()


class _FakeEngine:
    def __init__(self) -> None:
        self.statements: list = []
        self.disposed = False

    @asynccontextmanager
    async def begin(self):
        yield _FakeConn(self.statements)

    async def dispose(self) -> None:
        self.disposed = True


class _FakeSession:
    def __init__(self, *a, **kw) -> None: ...

    async def __aenter__(self):
        return self

    async def __aexit__(self, *exc):
        return False


@pytest.fixture
def fake_db(monkeypatch: pytest.MonkeyPatch) -> _FakeEngine:
    engine = _FakeEngine()
    monkeypatch.setattr(lib, "AsyncSession", _FakeSession)

    async def _none_existing(session, ids):
        return set()

    monkeypatch.setattr(lib, "_existing_ids", _none_existing)
    return engine


def _write(tmp_path: Path, rows: list[dict]) -> Path:
    path = tmp_path / "batch.json"
    path.write_text(json.dumps(rows))
    return path


@pytest.mark.asyncio
async def test_cli_and_function_give_identical_review_statuses(
    tmp_path: Path, fake_db: _FakeEngine
) -> None:
    """Parity is the whole point of the move: the scheduled job must approve
    exactly the rows the hand-run CLI would, sk included."""
    rows = _fixture_rows()
    cli_questions = cli._load_questions([_write(tmp_path, rows)], lib.AUTO_REVIEW_STATUS)
    cli_statuses = {q.id: (q.review_status, q.reviewed_by) for q in cli_questions}

    result = await lib.import_questions(
        lib.parse_questions(rows, lib.AUTO_REVIEW_STATUS),
        database_url_or_engine=fake_db,
        execute=False,
    )

    assert result.statuses == {qid: s for qid, (s, _) in cli_statuses.items()}
    assert result.statuses[_id("q_sk")] == "approved"
    assert result.statuses[_id("q_cs")] == "approved"
    assert cli_statuses[_id("q_sk")][1] == GATE_VERSION
    # Counts the CLI prints come from the same result.
    assert result.approved == 3 and result.pending == 2
    assert fake_db.statements == []  # dry run wrote nothing


@pytest.mark.asyncio
async def test_row_without_source_url_never_becomes_approved(fake_db: _FakeEngine) -> None:
    """Source is mandatory (founder 2026-09-09): an unsourced fact must not
    reach the App Store, whichever language or entry point."""
    rows = [_clean(f"q{lang}", language=lang, source_url=src)
            for lang in ("en", "sk", "cs") for src in (None, "", "   ")]
    rows = [{**r, "id": _id(f"nosrc-{i}")} for i, r in enumerate(rows)]
    result = await lib.import_questions(
        lib.parse_questions(rows, lib.AUTO_REVIEW_STATUS),
        database_url_or_engine=fake_db,
        execute=False,
    )
    assert set(result.statuses.values()) == {"pending_review"}
    assert set(result.pending_reasons.values()) == {"no_source_url"}


@pytest.mark.asyncio
async def test_held_rows_are_skipped_with_a_reason_and_never_inserted(
    fake_db: _FakeEngine, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("OPENAI_API_KEY", "sk-test")
    monkeypatch.setattr(lib, "OpenAI", lambda: object())
    monkeypatch.setattr(
        lib, "_embed_batch", lambda client, texts: [[0.1] * lib.EMBEDDING_DIM for _ in texts]
    )
    inserted_ids: list[str] = []
    real = lib._row_to_insert_dict
    monkeypatch.setattr(
        lib, "_row_to_insert_dict", lambda row: inserted_ids.append(str(row.id)) or real(row)
    )
    rows = _fixture_rows()
    result = await lib.import_questions(
        lib.parse_questions(rows, lib.AUTO_REVIEW_STATUS),
        database_url_or_engine=fake_db,
        execute=True,
    )
    assert result.skipped == {_id("q_held"): "held_for_review"}
    assert _id("q_held") not in result.statuses
    assert result.to_insert == 5
    assert len(inserted_ids) == 5
    assert len(fake_db.statements) == 1  # one batched INSERT
    assert result.pending_reasons[_id("q_de")] == "language='de'"


@pytest.mark.asyncio
async def test_boost_until_reaches_the_db_row_dict(
    fake_db: _FakeEngine, monkeypatch: pytest.MonkeyPatch
) -> None:
    """#195: a dropped `boost_until` ships the fresh batch UNBOOSTED with no
    error. Pin the last hop before the INSERT, on the function path."""
    monkeypatch.setenv("OPENAI_API_KEY", "sk-test")
    monkeypatch.setattr(lib, "OpenAI", lambda: object())
    monkeypatch.setattr(
        lib, "_embed_batch", lambda client, texts: [[0.1] * lib.EMBEDDING_DIM for _ in texts]
    )
    captured: list[dict] = []
    real = lib._row_to_insert_dict
    monkeypatch.setattr(lib, "_row_to_insert_dict", lambda row: captured.append(real(row)) or captured[-1])

    questions = lib.parse_questions([_clean("q_boost", boost_until=UNTIL.isoformat())], lib.AUTO_REVIEW_STATUS)
    await lib.import_questions(questions, database_url_or_engine=fake_db, execute=True)

    assert captured[0]["boost_until"] == UNTIL
    assert question_to_row(questions[0]).boost_until == UNTIL


class _StubLocalScope:
    """Labels every row it is given as Slovak-local; records what it saw."""

    def __init__(self) -> None:
        self.seen: list[str] = []

    async def label(self, questions, batch_size=25):
        from app.generation.local_scope_classifier import LocalScope, apply_local_scope

        for q in questions:
            self.seen.append(q.id)
            apply_local_scope(q, LocalScope(scope="sk", reason="Bratislava MHD"))
        return len(questions)


@pytest.mark.asyncio
async def test_new_rows_are_labelled_local_before_insert(
    fake_db: _FakeEngine, monkeypatch: pytest.MonkeyPatch
) -> None:
    """#206: every corpus writer goes through this importer, so this is where a
    new question gets its "local" label — without it, a player who switched
    local questions off would still get every newly generated one. A row that
    already carries a verdict (labelled JSON) is not classified twice."""
    monkeypatch.setenv("OPENAI_API_KEY", "sk-test")
    monkeypatch.setenv("LOCAL_SCOPE_CLASSIFICATION", "1")
    monkeypatch.setattr(lib, "OpenAI", lambda: object())
    monkeypatch.setattr(
        lib, "_embed_batch", lambda client, texts: [[0.1] * lib.EMBEDDING_DIM for _ in texts]
    )
    captured: list[dict] = []
    real = lib._row_to_insert_dict
    monkeypatch.setattr(lib, "_row_to_insert_dict", lambda row: captured.append(real(row)) or captured[-1])

    already = _clean("q_done", language="sk")
    already["generation_metadata"]["extra"]["local_scope"] = {"scope": None, "reason": "x"}
    questions = lib.parse_questions(
        [_clean("q_mhd", language="sk"), already], lib.AUTO_REVIEW_STATUS
    )
    stub = _StubLocalScope()
    result = await lib.import_questions(
        questions, database_url_or_engine=fake_db, execute=True, local_scope_classifier=stub
    )

    assert stub.seen == [_id("q_mhd")]
    assert result.local_scope_labelled == 1
    by_id = {str(r["id"]): r for r in captured}
    assert by_id[_id("q_mhd")]["local_scope"] == "sk"
    assert by_id[_id("q_mhd")]["provenance"]["extra"]["local_scope"]["scope"] == "sk"
    assert by_id[_id("q_done")]["local_scope"] is None


@pytest.mark.asyncio
async def test_execute_without_openai_key_raises_and_writes_nothing(
    fake_db: _FakeEngine, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.delenv("OPENAI_API_KEY", raising=False)
    seen: list[lib.ImportResult] = []
    with pytest.raises(lib.EmbeddingKeyMissing):
        await lib.import_questions(
            lib.parse_questions([_clean("q1")], lib.AUTO_REVIEW_STATUS),
            database_url_or_engine=fake_db,
            execute=True,
            on_plan=seen.append,
        )
    assert fake_db.statements == []
    assert seen and seen[0].needs_embedding == 1  # the plan was still reported


@pytest.mark.asyncio
async def test_explicit_status_forces_every_row(fake_db: _FakeEngine) -> None:
    """The human quarantine path must stay absolute even for a row the machine
    would approve."""
    result = await lib.import_questions(
        lib.parse_questions([_clean("q1")], "pending_review"),
        database_url_or_engine=fake_db,
        review_status="pending_review",
        execute=False,
    )
    assert result.statuses == {_id("q1"): "pending_review"}
    assert result.block_reasons == {}


def test_passed_in_engine_is_borrowed_not_disposed(fake_db: _FakeEngine) -> None:
    import asyncio

    asyncio.run(
        lib.import_questions([], database_url_or_engine=fake_db, execute=False)
    )
    assert fake_db.disposed is False


def test_question_model_roundtrip_keeps_parse_defaults() -> None:
    (q,) = lib.parse_questions([_clean("q1")], lib.AUTO_REVIEW_STATUS)
    assert isinstance(q, Question)
    assert (q.embedding_model, q.embedding_dim) == (lib.EMBEDDING_MODEL, lib.EMBEDDING_DIM)


@pytest.mark.asyncio
async def test_cli_dry_run_output_shape_is_unchanged(
    tmp_path: Path, fake_db: _FakeEngine, monkeypatch: pytest.MonkeyPatch, capsys
) -> None:
    """The CLI stayed a wrapper: same report lines, same exit code, no writes."""
    import argparse

    monkeypatch.setattr(lib, "engine", fake_db)
    args = argparse.Namespace(
        json_path=[str(_write(tmp_path, _fixture_rows()))],
        database_url=None,
        review_status=lib.AUTO_REVIEW_STATUS,
        batch_size=100,
        dry_run=True,
        execute=False,
    )
    assert await cli._run(args) == 0
    out = capsys.readouterr().out
    assert "REJECTED unverified/held rows: 1" in out
    assert "Unique across files:       5" in out
    assert "Would insert:              5 (review_status='auto')" in out
    assert f"machine-approved:        3 (reviewed_by={GATE_VERSION!r})" in out
    assert "no_source_url" in out
    assert "Inserted:" not in out
    assert fake_db.statements == []
