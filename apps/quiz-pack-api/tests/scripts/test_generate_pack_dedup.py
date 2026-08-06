"""Tests for the 42.27 `--dedup-store` flag on `scripts/generate_pack.py`.

Why these matter:
- The default (`noop`) must keep the pre-42.27 CLI behaviour — a one-shot
  fresh pack has no corpus to dedup against, so `DedupStage` must find no
  duplicates. Any regression here would start dropping freshly generated
  questions against an empty/irrelevant store.
- `pgvector` is the opt-in that wires the live corpus into the dry-run so an
  operator can dedup a batch against real history; it must build a real
  async `PgvectorQuestionStore` (#150 — no sync bridge in front of it, that
  blocked the loop) and fail loud (not silently no-op) when `DATABASE_URL`
  is absent.

These assert the store *selection* wiring only — no DB query, so no embedder
call. The end-to-end pgvector drop is covered in `tests/db/test_pgvector_dedup`.
"""

from __future__ import annotations

import inspect

import pytest

from quiz_shared.database.pgvector_client import PgvectorQuestionStore

import scripts.generate_pack as generate_pack


def test_dedup_store_defaults_to_noop():
    args = generate_pack._parse_args(["--prompt", "history of flight", "--dry-run"])
    assert args.dedup_store == "noop"


def test_build_noop_store_is_default_noop():
    store = generate_pack._build_dedup_store("noop")
    assert isinstance(store, generate_pack._NoopQuestionStore)
    # #150 — DedupStage awaits find_duplicates; a sync double would raise.
    assert inspect.iscoroutinefunction(store.find_duplicates)


def test_build_pgvector_store_is_async_store(monkeypatch):
    # Valid URL → engine is created lazily (no connection), so no DB needed.
    monkeypatch.setenv(
        "DATABASE_URL", "postgresql+asyncpg://quiz:quiz@localhost:5432/quiz_pack"
    )
    store = generate_pack._build_dedup_store("pgvector")
    # #150 — the async store goes straight to DedupStage, no sync bridge.
    assert isinstance(store, PgvectorQuestionStore)


def test_pgvector_store_fails_loud_without_database_url(monkeypatch):
    monkeypatch.delenv("DATABASE_URL", raising=False)
    with pytest.raises(SystemExit):
        generate_pack._build_dedup_store("pgvector")
