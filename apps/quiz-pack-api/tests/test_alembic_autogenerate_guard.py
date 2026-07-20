"""Alembic autogenerate must never consider the co-tenant's tables.

WHY this matters — not just what it does: quiz-pack-api's tables co-locate in
the shared quiz-pack-db cluster with quiz-agent's auth/usage tables
(``anonymous_identities``, ``refresh_tokens``, …) and their dedicated
``alembic_version_quiz_agent`` history table. Autogenerate diffs the
REFLECTED database state against THIS app's metadata; without an
``include_object`` allowlist it sees the co-tenant's tables, finds them
absent from the metadata, and emits ``drop_table`` — a generated migration
could destroy the other app's data (backend arch review 2026-07-18). The
contract pinned here: only tables in this app's own metadata pass the filter,
and the hook is actually wired into ``context.configure``.

``alembic/env.py`` only runs inside Alembic's runtime (``alembic.context``
proxies are populated during a migration run), so this test loads it with a
stub context — which is what lets us assert the wiring, not just the logic.
"""

from __future__ import annotations

import importlib.util
from contextlib import nullcontext
from pathlib import Path
from types import SimpleNamespace

import alembic

ENV_PATH = Path(__file__).resolve().parents[1] / "alembic" / "env.py"


class _StubConfig:
    config_file_name = None  # skip fileConfig
    config_ini_section = "alembic"

    def __init__(self) -> None:
        self._opts: dict[str, str] = {}

    def set_main_option(self, key: str, value: str) -> None:
        self._opts[key] = value

    def get_main_option(self, key: str) -> str | None:
        return self._opts.get(key)

    def get_section(self, name: str, default=None):
        return default


def _load_env_module(monkeypatch):
    """Exec env.py under a stubbed offline alembic context; return the module
    and the kwargs it passed to ``context.configure``."""
    captured: dict = {}
    stub = SimpleNamespace(
        config=_StubConfig(),
        is_offline_mode=lambda: True,
        configure=lambda **kw: captured.update(kw),
        begin_transaction=nullcontext,
        run_migrations=lambda: None,
    )
    monkeypatch.setattr(alembic, "context", stub)
    spec = importlib.util.spec_from_file_location("_pack_alembic_env", ENV_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module, captured


def test_include_object_is_wired_into_configure(monkeypatch) -> None:
    """A correct hook that env.py never passes to configure protects nothing."""
    module, captured = _load_env_module(monkeypatch)
    assert captured.get("include_object") is module.include_object


def test_include_object_allows_own_tables_and_excludes_co_tenant(
    monkeypatch,
) -> None:
    module, _ = _load_env_module(monkeypatch)
    hook = module.include_object

    own_tables = set(module.target_metadata.tables)
    assert own_tables, "metadata unexpectedly empty — models not imported?"
    for name in own_tables:
        assert hook(None, name, "table", False, None), name

    # Reflected co-tenant tables (quiz-agent's auth/usage set, incl. its
    # dedicated version table) must be excluded, or autogenerate emits
    # drop_table for them.
    for foreign in (
        "anonymous_identities",
        "refresh_tokens",
        "alembic_version_quiz_agent",
    ):
        assert foreign not in own_tables  # guard the premise
        assert not hook(None, foreign, "table", True, None), foreign

    # Non-table objects (indexes, constraints) pass through untouched.
    assert hook(None, "ix_anything", "index", False, None)
