"""#207 task 207.18: the orders switch quiz-agent keeps in the shared DB.

Why these tests matter: the founder pauses custom-pack orders with one live
change (``PUT /admin/app-switches`` on quiz-agent, no machine restart). That
row must refuse new orders here too, server-side, because builds that cached
``/app-config`` or ignore it can still POST; and it must override this app's
env value in both directions, or "resume" would silently stay paused. Without
the row (or without the table, as in this suite's own DB) the env value keeps
deciding, which the existing pause tests in ``test_orders.py`` cover.
"""

from __future__ import annotations

from collections.abc import AsyncIterator

import httpx
import pytest
import pytest_asyncio
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from tests.api.conftest import TEST_ADMIN_KEY, _bearer

BEARER = _bearer("jws-account-1")


def _body(tx_id: str) -> dict:
    return {
        "transaction_id": tx_id,
        "product_id": "pack_20",
        "prompt": "Interesting facts about the solar system",
        "language": "en",
        "target_count": 20,
    }


@pytest_asyncio.fixture
async def switch_row(test_session: AsyncSession) -> AsyncIterator:
    """Mirror of quiz-agent's ``app_switches`` table (its migration 0015)."""
    await test_session.execute(
        text(
            "CREATE TABLE IF NOT EXISTS app_switches (key text PRIMARY KEY, "
            "value text, updated_at timestamptz NOT NULL DEFAULT now())"
        )
    )
    await test_session.commit()

    async def _set(value: str) -> None:
        await test_session.execute(
            text(
                "INSERT INTO app_switches (key, value) VALUES ('orders_enabled', :v) "
                "ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value"
            ),
            {"v": value},
        )
        await test_session.commit()

    yield _set
    await test_session.execute(text("DELETE FROM app_switches WHERE key = 'orders_enabled'"))
    await test_session.commit()


@pytest.mark.asyncio
async def test_db_pause_refuses_new_orders_even_when_env_allows(
    client: httpx.AsyncClient, app_settings, switch_row
) -> None:
    assert app_settings.pack_orders_enabled is True
    await switch_row("false")

    resp = await client.post(
        "/v1/orders",
        json=_body("admin-live-paused"),
        headers={"X-Admin-Key": TEST_ADMIN_KEY, **BEARER},
    )

    assert resp.status_code == 503
    assert resp.json()["detail"] == "Ordering is paused for now. Try again later."


@pytest.mark.asyncio
async def test_db_resume_beats_a_paused_env(
    client: httpx.AsyncClient, app_settings, switch_row
) -> None:
    app_settings.pack_orders_enabled = False
    await switch_row("true")

    resp = await client.post(
        "/v1/orders",
        json=_body("admin-live-resumed"),
        headers={"X-Admin-Key": TEST_ADMIN_KEY, **BEARER},
    )

    assert resp.status_code == 202, resp.text
