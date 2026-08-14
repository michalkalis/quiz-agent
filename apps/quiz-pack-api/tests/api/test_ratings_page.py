"""The served rating page and the admin gate it must NOT inherit (#154).

`/web` is admin-gated at the router level. Adding the rating page to that
router would have silently locked out every rater; putting it on its own
router could just as silently have unlocked the admin question tool. Both
halves are asserted here against the same app, because either one alone is
compatible with the bug.
"""

from __future__ import annotations

import uuid

import httpx

from tests.api.conftest import TEST_ADMIN_KEY

ADMIN = {"X-Admin-Key": TEST_ADMIN_KEY}

ARM_SENTINEL = "arm-alpha-secret-marker"


async def _register(client: httpx.AsyncClient) -> str:
    resp = await client.post(
        "/v1/ratings/batches",
        json={
            "title": "Kolo 3 — blind",
            "questions": [
                {"qid": "q01", "question": "Which planet has the shortest day?",
                 "answer": "Jupiter", "meta": {"topic": "science"}},
            ],
            "mapping": {"q01": {"arm": ARM_SENTINEL, "original_id": "orig-1"}},
        },
        headers=ADMIN,
    )
    assert resp.status_code == 201, resp.text
    return resp.json()["batch_id"]


async def test_rate_page_served_without_admin_key(
    ratings_client: httpx.AsyncClient,
) -> None:
    batch_id = await _register(ratings_client)
    resp = await ratings_client.get(f"/web/rate/{batch_id}?rater=Michal")
    assert resp.status_code == 200, resp.text
    assert "Which planet has the shortest day?" in resp.text
    # The rater identity reaches the page, so a reload resumes as the same person.
    assert "Michal" in resp.text


async def test_rate_page_carries_no_arm_or_mapping(
    ratings_client: httpx.AsyncClient,
) -> None:
    batch_id = await _register(ratings_client)
    resp = await ratings_client.get(f"/web/rate/{batch_id}")
    assert resp.status_code == 200
    assert ARM_SENTINEL not in resp.text
    assert "orig-1" not in resp.text


async def test_rate_page_unknown_batch_404(ratings_client: httpx.AsyncClient) -> None:
    resp = await ratings_client.get(f"/web/rate/{uuid.uuid4()}")
    assert resp.status_code == 404


async def test_admin_web_pages_still_require_the_key(
    ratings_client: httpx.AsyncClient,
) -> None:
    """The open rate route must not have opened the admin tool next to it."""
    assert (await ratings_client.get("/web/import")).status_code == 401
