"""Shared fixtures for the /v1/orders API tests (test_orders, test_orders_access)
and the /v1/ratings tests (test_ratings, test_ratings_page — see `ratings_client`).

Moved out of test_orders.py (#95) so both modules use one wiring instead of
cross-module fixture imports (ruff F811). The DB-touching fixtures chain off
`_alembic_head` / `_clean_orders` as *dependencies of `client`* rather than
autouse, so the non-DB modules in this package (test_admin_auth, test_deps)
keep running on hosts without TEST_DATABASE_URL.

Overrides on the minimal test app:
- DB session → test-database (TEST_DATABASE_URL).
- JWS verifier → in-memory test cert chain (no Apple cert file required).
- ARQ pool → MagicMock (no real Redis required).
- Settings → known admin key + JWT secret regardless of the developer's .env.

Bring up the local test DB first: `make dev-db` from apps/quiz-pack-api/.
"""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path
from typing import AsyncIterator
from unittest.mock import AsyncMock, MagicMock

import httpx
import pytest
import pytest_asyncio
from fastapi import FastAPI
from sqlalchemy.ext.asyncio import AsyncEngine, AsyncSession, async_sessionmaker

from app.api.deps import get_arq_pool, get_jws_verifier
from app.api.v1 import orders as orders_module
from app.api.v1.orders import router as orders_router
from app.api.v1.ratings import router as ratings_router
from app.config import Settings, get_settings
from app.db.engine import build_engine, normalize_async_url
from app.db.session import get_session
from app.storekit import AppleJWSVerifier
from app.web.rate import router as web_rate_router
from app.web.routes import router as admin_web_router
from quiz_shared.auth.tokens import TokenService
from tests._isolation import truncate_order_graph, truncate_ratings
from tests.storekit._chain_fixtures import TestChain

APP_ROOT = Path(__file__).resolve().parents[2]

# Deterministic auth config for the test app (#95): a known admin key + JWT
# secret regardless of what the developer's .env carries.
TEST_ADMIN_KEY = "test-admin-key"
TEST_JWT_SECRET = "unit-test-jwt-secret-" + "x" * 64


def _bearer(subject: str) -> dict[str, str]:
    """Mint a real quiz-agent-shaped access token for `subject`.

    #103 F3: order creation now requires this on every call — moved here
    (from tests/api/test_orders_access.py) so tests/api/test_orders.py can
    use it too instead of duplicating the minting logic.
    """
    service = TokenService(
        secret=TEST_JWT_SECRET,
        issuer="quiz-agent",
        audience="quiz-agent-clients",
    )
    return {"Authorization": f"Bearer {service.create_access_token(subject)}"}


@pytest.fixture(scope="module")
def _alembic_head() -> None:
    """Bring the test DB to head once per module so tables exist.

    Mirrors tests/db and tests/worker: these API tests live in tests/api/, which
    pytest collects before tests/db/, so without this they would run against an
    unmigrated DB on a fresh host (issue #73). Idempotent — a no-op once at head.
    """
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
async def test_engine(_alembic_head: None) -> AsyncIterator[AsyncEngine]:
    raw = os.environ.get("TEST_DATABASE_URL") or os.environ.get("DATABASE_URL")
    if not raw:
        pytest.skip("TEST_DATABASE_URL not set — skipping DB-backed tests")
    eng = build_engine(normalize_async_url(raw))
    yield eng
    await eng.dispose()


@pytest_asyncio.fixture
async def test_session(test_engine: AsyncEngine) -> AsyncIterator[AsyncSession]:
    factory = async_sessionmaker(test_engine, class_=AsyncSession, expire_on_commit=False)
    async with factory() as s:
        yield s


@pytest_asyncio.fixture
async def _clean_orders(test_session: AsyncSession) -> AsyncIterator[None]:
    """Start each test from an empty orders/jobs slate.

    These tests POST with fixed transaction_ids, and the orders endpoint is
    idempotent on transaction_id (returns 200 for an existing tx). Against the
    persistent test DB, rows left by a prior gate run would turn the expected
    202 into 200 — so the suite must be re-runnable, not just pass once. Other
    DB-test modules clean up per-id; this module truncates because order_ids are
    server-generated and not all surface to the test. CASCADE clears any
    dependent pack/question rows too.
    """
    await truncate_order_graph(test_session)
    yield


@pytest.fixture
def arq_mock() -> MagicMock:
    pool = MagicMock()
    pool.enqueue_job = AsyncMock(return_value=None)
    return pool


@pytest_asyncio.fixture
async def client(
    test_session: AsyncSession,
    test_chain: TestChain,
    arq_mock: MagicMock,
    _clean_orders: None,
) -> AsyncIterator[httpx.AsyncClient]:
    """Async HTTP client wired against a minimal test app."""
    verifier = AppleJWSVerifier(
        test_chain.root_cert,
        "com.missinghue.hangs",
        "Sandbox",
    )

    async def _override_session() -> AsyncIterator[AsyncSession]:
        yield test_session

    test_settings = Settings(
        admin_api_key=TEST_ADMIN_KEY,
        auth_jwt_secret=TEST_JWT_SECRET,
    )

    test_app = FastAPI()
    test_app.include_router(orders_router)
    test_app.dependency_overrides[get_session] = _override_session
    test_app.dependency_overrides[get_jws_verifier] = lambda: verifier
    test_app.dependency_overrides[get_arq_pool] = lambda: arq_mock
    test_app.dependency_overrides[get_settings] = lambda: test_settings

    async with httpx.AsyncClient(
        transport=httpx.ASGITransport(app=test_app),
        base_url="http://test",
    ) as ac:
        yield ac


@pytest_asyncio.fixture
async def per_request_client(
    test_engine: AsyncEngine,
    test_chain: TestChain,
    arq_mock: MagicMock,
    _clean_orders: None,
) -> AsyncIterator[httpx.AsyncClient]:
    """Same test app as `client`, but every request gets its OWN AsyncSession.

    WHY a second wiring exists: `client` overrides `get_session` with ONE
    shared session for the whole test. That is fine for sequential assertions,
    but it structurally MASKS any defect that only exists between two
    concurrent DB transactions — two requests sharing one session also share
    one transaction, so neither can ever collide with the other's uncommitted
    row. The concurrent-duplicate-create race (adversarial audit 2026-07-30)
    was invisible under `client` and reproducible only here.

    Production is the per-request shape (`app.db.session.get_session` opens a
    session per request), so this fixture is the faithful one for anything
    concurrency-sensitive.
    """
    verifier = AppleJWSVerifier(
        test_chain.root_cert,
        "com.missinghue.hangs",
        "Sandbox",
    )
    factory = async_sessionmaker(
        test_engine, class_=AsyncSession, expire_on_commit=False, autoflush=False
    )

    async def _override_session() -> AsyncIterator[AsyncSession]:
        async with factory() as s:
            yield s

    test_settings = Settings(
        admin_api_key=TEST_ADMIN_KEY,
        auth_jwt_secret=TEST_JWT_SECRET,
    )

    test_app = FastAPI()
    test_app.include_router(orders_router)
    test_app.dependency_overrides[get_session] = _override_session
    test_app.dependency_overrides[get_jws_verifier] = lambda: verifier
    test_app.dependency_overrides[get_arq_pool] = lambda: arq_mock
    test_app.dependency_overrides[get_settings] = lambda: test_settings

    async with httpx.AsyncClient(
        transport=httpx.ASGITransport(app=test_app),
        base_url="http://test",
    ) as ac:
        yield ac


@pytest_asyncio.fixture
async def _clean_ratings(test_session: AsyncSession) -> AsyncIterator[None]:
    """Start each ratings test from an empty ratings/batches slate (#154)."""
    await truncate_ratings(test_session)
    yield


@pytest_asyncio.fixture
async def ratings_client(
    test_session: AsyncSession,
    _clean_ratings: None,
) -> AsyncIterator[httpx.AsyncClient]:
    """Client for the #154 ratings surface.

    Mounts all three routers that share the auth boundary under test — the
    ratings API, the UNGATED rating page, and the admin `/web` tool — because
    the property that matters is the *difference* between them: proving the
    rate page is open is only meaningful next to a `/web/` that still 401s in
    the same app.
    """
    async def _override_session() -> AsyncIterator[AsyncSession]:
        yield test_session

    test_settings = Settings(
        admin_api_key=TEST_ADMIN_KEY,
        auth_jwt_secret=TEST_JWT_SECRET,
    )

    test_app = FastAPI()
    test_app.include_router(ratings_router)
    test_app.include_router(web_rate_router)
    test_app.include_router(admin_web_router)
    test_app.dependency_overrides[get_session] = _override_session
    test_app.dependency_overrides[get_settings] = lambda: test_settings

    async with httpx.AsyncClient(
        transport=httpx.ASGITransport(app=test_app),
        base_url="http://test",
    ) as ac:
        yield ac


@pytest.fixture
def sentry_messages(monkeypatch: pytest.MonkeyPatch) -> list[str]:
    """Collect `sentry_sdk.capture_message` bodies emitted by the orders route.

    The verified→reject trail (#133 V5) is only useful if it actually reaches
    Sentry, so the tests assert the capture, not just the log line. Patched on
    the module object the route calls through and reverted by monkeypatch.
    """
    captured: list[str] = []
    monkeypatch.setattr(
        orders_module.sentry_sdk,
        "capture_message",
        lambda message, *args, **kwargs: captured.append(message),
    )
    return captured
