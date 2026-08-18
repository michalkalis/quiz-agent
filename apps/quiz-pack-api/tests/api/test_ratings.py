"""Ratings store API — the properties the calibration data depends on (#154).

What is actually at stake in each group:

- *Blinding*: if an arm identifier reaches the rater, the whole blind-test
  design is void and the round has to be thrown away. Asserted on the raw
  response bytes, not on parsed fields, because a leak would arrive through a
  field nobody thought to parse.
- *Upsert*: the founder re-rates questions after thinking about them. If a
  re-rate appended instead of updating, the average for that question would be
  a mix of a first impression and a considered one; if two raters collapsed
  into one row, D25 attribution would be silently lost.
- *Auth boundaries*: the batch id is the only credential the rater routes have,
  so "unknown batch" and "export needs admin" are the security surface.
- *Normalisation*: historical 1–5 rounds (#156) and current 1–10 rounds share
  one export; the derived column is what makes them comparable, and the raw
  score must survive untouched next to it.
"""

from __future__ import annotations

import json
import uuid
from typing import Any

import httpx
import pytest
from app.db.models.question import QuestionRow
from app.db.models.rating import Rating
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from tests.api.conftest import TEST_ADMIN_KEY, _bearer

ADMIN = {"X-Admin-Key": TEST_ADMIN_KEY}

# A string that exists ONLY in the server-side mapping. Any appearance of it in
# a rater-facing response is a blinding leak.
ARM_SENTINEL = "arm-alpha-secret-marker"


def _batch_payload(**overrides: Any) -> dict[str, Any]:
    payload: dict[str, Any] = {
        "title": "Kolo 3 — blind",
        "questions": [
            {
                "qid": "q01",
                "question": "Which planet has the shortest day?",
                "answer": "Jupiter",
                "meta": {"topic": "science", "difficulty": "medium"},
            },
            {
                "qid": "q02",
                "question": "What colour is a polar bear's skin?",
                "answer": "Black",
                "meta": {"topic": "nature"},
            },
        ],
        "mapping": {
            "q01": {"arm": ARM_SENTINEL, "original_id": "orig-1"},
            "q02": {"arm": "arm-beta", "original_id": "orig-2"},
        },
    }
    payload.update(overrides)
    return payload


async def _register(client: httpx.AsyncClient, **overrides: Any) -> str:
    resp = await client.post(
        "/v1/ratings/batches", json=_batch_payload(**overrides), headers=ADMIN
    )
    assert resp.status_code == 201, resp.text
    return resp.json()["batch_id"]


# --- batch registration ------------------------------------------------------


async def test_create_batch_requires_admin(ratings_client: httpx.AsyncClient) -> None:
    resp = await ratings_client.post("/v1/ratings/batches", json=_batch_payload())
    assert resp.status_code == 401


async def test_create_batch_returns_token_and_rate_url(
    ratings_client: httpx.AsyncClient,
) -> None:
    resp = await ratings_client.post(
        "/v1/ratings/batches", json=_batch_payload(), headers=ADMIN
    )
    assert resp.status_code == 201, resp.text
    body = resp.json()
    batch_id = uuid.UUID(body["batch_id"])  # the id IS the URL token
    assert body["rate_url_template"].endswith(f"/web/rate/{batch_id}?rater={{rater}}")


async def test_create_batch_rejects_arm_field_on_a_question(
    ratings_client: httpx.AsyncClient,
) -> None:
    """The blinding guard fires at registration, not after the round is rated."""
    leaky = _batch_payload()
    leaky["questions"][0]["arm"] = ARM_SENTINEL
    resp = await ratings_client.post("/v1/ratings/batches", json=leaky, headers=ADMIN)
    assert resp.status_code == 422


async def test_create_batch_rejects_mapping_for_unknown_qid(
    ratings_client: httpx.AsyncClient,
) -> None:
    """A mapping keyed by anything else could never unblind this batch."""
    bad = _batch_payload()
    bad["mapping"]["q99"] = {"arm": "ghost"}
    resp = await ratings_client.post("/v1/ratings/batches", json=bad, headers=ADMIN)
    assert resp.status_code == 400


# --- blinding ----------------------------------------------------------------


async def test_batch_view_leaks_no_arm_or_mapping(
    ratings_client: httpx.AsyncClient,
) -> None:
    batch_id = await _register(ratings_client)
    resp = await ratings_client.get(f"/v1/ratings/batches/{batch_id}?rater=Michal")
    assert resp.status_code == 200
    raw = resp.text
    assert ARM_SENTINEL not in raw
    assert "arm-beta" not in raw
    assert "orig-1" not in raw
    assert "mapping" not in raw
    assert [q["qid"] for q in resp.json()["questions"]] == ["q01", "q02"]


# --- rater routes: auth boundaries -------------------------------------------


async def test_unknown_batch_is_404_not_422(ratings_client: httpx.AsyncClient) -> None:
    """Both a well-formed unknown id and a malformed one answer identically."""
    for bad in (str(uuid.uuid4()), "not-a-uuid"):
        assert (await ratings_client.get(f"/v1/ratings/batches/{bad}")).status_code == 404
        put = await ratings_client.put(
            f"/v1/ratings/batches/{bad}/ratings",
            json={"rater": "Michal", "qid": "q01", "score": 7},
        )
        assert put.status_code == 404


async def test_rating_needs_no_admin_key(ratings_client: httpx.AsyncClient) -> None:
    """The batch id is the capability — raters have no credentials (D25)."""
    batch_id = await _register(ratings_client)
    resp = await ratings_client.put(
        f"/v1/ratings/batches/{batch_id}/ratings",
        json={"rater": "Michal", "qid": "q01", "score": 8, "reason": "surprising"},
    )
    assert resp.status_code == 200, resp.text


@pytest.mark.parametrize(
    "body,expected",
    [
        ({"rater": "Michal", "qid": "nope", "score": 5}, 400),
        ({"rater": "Michal", "qid": "q01", "score": 0}, 422),
        ({"rater": "Michal", "qid": "q01", "score": 11}, 422),
        ({"rater": "   ", "qid": "q01", "score": 5}, 422),
    ],
)
async def test_rating_rejects_bad_input(
    ratings_client: httpx.AsyncClient, body: dict[str, Any], expected: int
) -> None:
    batch_id = await _register(ratings_client)
    resp = await ratings_client.put(
        f"/v1/ratings/batches/{batch_id}/ratings", json=body
    )
    assert resp.status_code == expected, resp.text


# --- upsert semantics --------------------------------------------------------


async def test_two_raters_are_attributed_separately(
    ratings_client: httpx.AsyncClient, test_session: AsyncSession
) -> None:
    batch_id = await _register(ratings_client)
    for rater, score in (("Michal", 8), ("Zuzka", 3)):
        resp = await ratings_client.put(
            f"/v1/ratings/batches/{batch_id}/ratings",
            json={"rater": rater, "qid": "q01", "score": score},
        )
        assert resp.status_code == 200, resp.text

    rows = (await test_session.execute(select(Rating))).scalars().all()
    assert {(r.rater, float(r.score)) for r in rows} == {("Michal", 8.0), ("Zuzka", 3.0)}


async def test_same_rater_twice_updates_one_row(
    ratings_client: httpx.AsyncClient, test_session: AsyncSession
) -> None:
    batch_id = await _register(ratings_client)
    for score, reason in ((4, "first take"), (9, "reconsidered")):
        resp = await ratings_client.put(
            f"/v1/ratings/batches/{batch_id}/ratings",
            json={"rater": "Michal", "qid": "q01", "score": score, "reason": reason},
        )
        assert resp.status_code == 200, resp.text

    count = await test_session.scalar(select(func.count()).select_from(Rating))
    assert count == 1
    row = (await test_session.execute(select(Rating))).scalars().one()
    await test_session.refresh(row)
    assert float(row.score) == 9.0
    assert row.reason == "reconsidered"
    assert row.updated_at >= row.created_at
    # Unblinded server-side from the mapping the rater never received.
    assert row.question_id == "orig-1"
    assert row.source == "web"


async def test_get_batch_returns_only_this_raters_ratings(
    ratings_client: httpx.AsyncClient,
) -> None:
    """Resume-across-devices must not show one rater another's scores."""
    batch_id = await _register(ratings_client)
    await ratings_client.put(
        f"/v1/ratings/batches/{batch_id}/ratings",
        json={"rater": "Michal", "qid": "q01", "score": 8},
    )
    await ratings_client.put(
        f"/v1/ratings/batches/{batch_id}/ratings",
        json={"rater": "Zuzka", "qid": "q02", "score": 2},
    )

    mine = await ratings_client.get(f"/v1/ratings/batches/{batch_id}?rater=Michal")
    assert mine.json()["ratings"] == {
        "q01": {
            "score": 8.0,
            "reason": None,
            "rated_at": mine.json()["ratings"]["q01"]["rated_at"],
            "flags": None,
        }
    }
    anon = await ratings_client.get(f"/v1/ratings/batches/{batch_id}")
    assert anon.json()["ratings"] == {}


# --- editorial checklist flags (D21b) ----------------------------------------


async def test_flags_persist_and_hydrate(
    ratings_client: httpx.AsyncClient, test_session: AsyncSession
) -> None:
    """Checklist flags live in extra["flags"] and come back on GET (resume)."""
    batch_id = await _register(ratings_client)
    resp = await ratings_client.put(
        f"/v1/ratings/batches/{batch_id}/ratings",
        json={
            "rater": "Michal",
            "qid": "q01",
            "score": 7,
            "flags": {"fact_error": True, "stale": False},
        },
    )
    assert resp.status_code == 200, resp.text

    row = (await test_session.execute(select(Rating))).scalars().one()
    assert row.extra == {"flags": {"fact_error": True, "stale": False}}

    mine = await ratings_client.get(f"/v1/ratings/batches/{batch_id}?rater=Michal")
    assert mine.json()["ratings"]["q01"]["flags"] == {
        "fact_error": True,
        "stale": False,
    }


async def test_flags_resubmit_replaces_and_clears(
    ratings_client: httpx.AsyncClient, test_session: AsyncSession
) -> None:
    """A re-rate must be able to change AND clear flags — not just add them."""
    batch_id = await _register(ratings_client)
    url = f"/v1/ratings/batches/{batch_id}/ratings"
    base = {"rater": "Michal", "qid": "q01", "score": 5}
    for flags in ({"duplicate": True}, {"logic_flaw": True}, {}):
        resp = await ratings_client.put(url, json={**base, "flags": flags})
        assert resp.status_code == 200, resp.text

    row = (await test_session.execute(select(Rating))).scalars().one()
    await test_session.refresh(row)
    assert row.extra == {"flags": {}}


async def test_omitted_flags_leave_stored_flags_alone(
    ratings_client: httpx.AsyncClient, test_session: AsyncSession
) -> None:
    """A score-only push (older device, pre-hydrate race) must not wipe flags."""
    batch_id = await _register(ratings_client)
    url = f"/v1/ratings/batches/{batch_id}/ratings"
    await ratings_client.put(
        url,
        json={"rater": "Michal", "qid": "q01", "score": 5, "flags": {"stale": True}},
    )
    resp = await ratings_client.put(
        url, json={"rater": "Michal", "qid": "q01", "score": 9}
    )
    assert resp.status_code == 200, resp.text

    row = (await test_session.execute(select(Rating))).scalars().one()
    await test_session.refresh(row)
    assert float(row.score) == 9.0
    assert row.extra == {"flags": {"stale": True}}


async def test_unknown_flag_key_is_422(ratings_client: httpx.AsyncClient) -> None:
    batch_id = await _register(ratings_client)
    resp = await ratings_client.put(
        f"/v1/ratings/batches/{batch_id}/ratings",
        json={
            "rater": "Michal",
            "qid": "q01",
            "score": 5,
            "flags": {"arm_leak": True},
        },
    )
    assert resp.status_code == 422


async def test_export_carries_top_level_flags(
    ratings_client: httpx.AsyncClient,
) -> None:
    """The correlate/eval scripts read `flags` without digging into extra."""
    batch_id = await _register(ratings_client)
    await ratings_client.put(
        f"/v1/ratings/batches/{batch_id}/ratings",
        json={
            "rater": "Michal",
            "qid": "q01",
            "score": 3,
            "flags": {"fact_error": True},
        },
    )
    await ratings_client.put(
        f"/v1/ratings/batches/{batch_id}/ratings",
        json={"rater": "Michal", "qid": "q02", "score": 8},
    )

    resp = await ratings_client.get("/v1/ratings/export", headers=ADMIN)
    assert resp.status_code == 200
    rows = {r["blinded_qid"]: r for line in resp.text.splitlines() if line.strip()
            for r in [json.loads(line)]}
    assert rows["q01"]["flags"] == {"fact_error": True}
    assert rows["q02"]["flags"] is None


# --- in-app path (#155 wiring, backend half here) ----------------------------


async def _seed_question(session: AsyncSession) -> QuestionRow:
    row = QuestionRow(
        question="Which sea has no coastline?",
        correct_answer="The Sargasso Sea",
        topic="geography",
        category="general",
        difficulty="medium",
    )
    session.add(row)
    await session.commit()
    return row


async def test_in_app_rating_requires_bearer(
    ratings_client: httpx.AsyncClient, test_session: AsyncSession
) -> None:
    question = await _seed_question(test_session)
    resp = await ratings_client.post(
        "/v1/ratings", json={"question_id": str(question.id), "score": 7}
    )
    assert resp.status_code == 401


async def test_in_app_rating_persists_as_in_app_source(
    ratings_client: httpx.AsyncClient, test_session: AsyncSession
) -> None:
    question = await _seed_question(test_session)
    resp = await ratings_client.post(
        "/v1/ratings",
        json={
            "question_id": str(question.id),
            "score": 6,
            "reason": "meh",
            "display_name": "Michal",
        },
        headers=_bearer("account-42"),
    )
    assert resp.status_code == 200, resp.text
    assert resp.json()["rater"] == "account-42"

    row = (await test_session.execute(select(Rating))).scalars().one()
    assert row.source == "in-app"
    assert row.batch_id is None
    assert row.question_id == str(question.id)
    # Snapshot, so the export stays readable if the question is archived.
    assert row.question_text == question.question
    # Identity is the JWT subject, not the display name: renaming must not
    # fork one rater into two.
    assert row.rater == "account-42"
    assert row.extra == {"display_name": "Michal"}


async def test_in_app_rating_unknown_question_404(
    ratings_client: httpx.AsyncClient,
) -> None:
    resp = await ratings_client.post(
        "/v1/ratings",
        json={"question_id": str(uuid.uuid4()), "score": 5},
        headers=_bearer("account-42"),
    )
    assert resp.status_code == 404


# --- export ------------------------------------------------------------------


async def test_export_requires_admin(ratings_client: httpx.AsyncClient) -> None:
    assert (await ratings_client.get("/v1/ratings/export")).status_code == 401


async def test_export_normalizes_without_touching_the_raw_score(
    ratings_client: httpx.AsyncClient, test_session: AsyncSession
) -> None:
    batch_id = await _register(ratings_client)
    await ratings_client.put(
        f"/v1/ratings/batches/{batch_id}/ratings",
        json={"rater": "Michal", "qid": "q01", "score": 8},
    )
    # A historical 1–5 round, the shape #156 backfills.
    test_session.add(
        Rating(
            dedupe_key="backfill:round-1:q07:Michal",
            question_text="Old question",
            rater="Michal",
            score=4,
            scale_min=1,
            scale_max=5,
            source="backfill:round-1",
        )
    )
    await test_session.commit()

    resp = await ratings_client.get("/v1/ratings/export", headers=ADMIN)
    assert resp.status_code == 200
    rows = [json.loads(line) for line in resp.text.splitlines() if line.strip()]
    assert len(rows) == 2
    by_source = {r["source"]: r for r in rows}

    current = by_source["web"]
    assert current["score"] == 8.0 and current["score_normalized_10"] == 8.0
    assert current["rater"] == "Michal" and current["blinded_qid"] == "q01"
    assert current["rated_at"] and current["batch_id"] == batch_id

    old = by_source["backfill:round-1"]
    # 4 on 1–5 sits three quarters up the scale → 1 + 3*(9/4) = 7.75 on 1–10.
    assert old["score"] == 4.0
    assert old["score_normalized_10"] == 7.75
    assert (old["scale_min"], old["scale_max"]) == (1, 5)
