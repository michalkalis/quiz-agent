"""#225 — an identical order gets a copy of a finished pack, no generation.

WHY: a second player typing the same prompt (same language + difficulty)
should not cost another ~$4 generation run. The founder's rules decide when a
copy is allowed; each test below pins one of them, so a change to the match
or eligibility rules fails here instead of silently giving players a wrong,
stale or repeated pack.
"""

from __future__ import annotations

import uuid
from datetime import datetime, timedelta, timezone
from unittest.mock import MagicMock

import httpx
import pytest
from sqlalchemy import select, text
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.models.job import GenerationJob
from app.db.models.order import GenerationOrder
from app.db.models.pack import QuestionPack
from app.db.models.question import QuestionRow
from app.pack_reuse import prompt_key
from tests.api.conftest import _bearer
from tests.storekit._chain_fixtures import JWSFactory

SOURCE_OWNER = "player-a"
BUYER = "player-b"
PROMPT = "Harry Potter"
COUNT = 20  # pack_20


async def _seed_source(
    session: AsyncSession,
    *,
    owner: str = SOURCE_OWNER,
    prompt: str = PROMPT,
    difficulty: str | None = "hard",
    language: str = "en",
    order_status: str = "delivered",
    pack_status: str = "complete",
    questions: int = COUNT,
    environment: str | None = "Sandbox",  # the test JWS is Sandbox
    expires_at: datetime | None = None,
) -> tuple[GenerationOrder, QuestionPack]:
    order = GenerationOrder(
        user_id=owner,
        transaction_id=f"seed-{uuid.uuid4().hex}",
        product_id="pack_20",
        prompt=prompt,
        prompt_key=prompt_key(prompt),
        difficulty=difficulty,
        target_count=COUNT,
        language=language,
        status=order_status,
        storekit_environment=environment,
        delivered_at=datetime.now(timezone.utc),
    )
    session.add(order)
    await session.flush()
    pack = QuestionPack(
        order_id=order.id,
        user_id=owner,
        prompt=prompt,
        language=language,
        target_count=COUNT,
        actual_count=questions,
        generation_status=pack_status,
    )
    session.add(pack)
    await session.flush()
    order.pack_id = pack.id
    for i in range(questions):
        session.add(
            QuestionRow(
                question=f"HP question {i}",
                type="text",
                correct_answer=f"answer {i}",
                topic="harry potter",
                category="entertainment",
                difficulty=difficulty or "medium",
                language=language,
                review_status="pending_review",
                pack_id=pack.id,
                expires_at=expires_at,
            )
        )
    await session.commit()
    return order, pack


@pytest.fixture(autouse=True)
async def _ratings_table(test_session: AsyncSession) -> None:
    """quiz-agent owns `question_ratings`; the pack-api test DB may lack it."""
    await test_session.execute(
        text(
            "CREATE TABLE IF NOT EXISTS question_ratings ("
            " id text PRIMARY KEY, question_id text NOT NULL, rating integer NOT NULL,"
            " created_at timestamptz NOT NULL DEFAULT now())"
        )
    )
    await test_session.execute(
        text(
            "CREATE TABLE IF NOT EXISTS anonymous_identities ("
            " anon_id text PRIMARY KEY, upgraded_to_user_id text,"
            " created_at timestamptz NOT NULL DEFAULT now(),"
            " last_seen_at timestamptz NOT NULL DEFAULT now())"
        )
    )
    await test_session.execute(text("DELETE FROM question_ratings"))
    await test_session.execute(
        text("DELETE FROM anonymous_identities WHERE anon_id LIKE 'reuse-test-%'")
    )
    await test_session.commit()


async def _order(
    client: httpx.AsyncClient,
    make_jws: JWSFactory,
    *,
    user: str = BUYER,
    prompt: str = "  harry   POTTER!! ",
    difficulty: str | None = "hard",
    language: str = "en",
) -> uuid.UUID:
    tx = str(uuid.uuid4().int)[:16]
    body = {
        "transaction_id": tx,
        "product_id": "pack_20",
        "prompt": prompt,
        "language": language,
        "target_count": COUNT,
    }
    if difficulty is not None:
        body["difficulty"] = difficulty
    jws = make_jws(payload_overrides={"transactionId": tx, "originalTransactionId": tx})
    resp = await client.post(
        "/v1/orders", json=body, headers={"X-StoreKit-JWS": jws, **_bearer(user)}
    )
    assert resp.status_code == 202, resp.text
    return uuid.UUID(resp.json()["order_id"])


async def _load(session: AsyncSession, order_id: uuid.UUID) -> GenerationOrder:
    session.expire_all()
    return (
        await session.execute(select(GenerationOrder).where(GenerationOrder.id == order_id))
    ).scalar_one()


@pytest.mark.asyncio
async def test_identical_order_gets_a_copy_without_generation(
    client: httpx.AsyncClient,
    make_jws: JWSFactory,
    test_session: AsyncSession,
    arq_mock: MagicMock,
) -> None:
    """Case, spacing and punctuation don't matter; the buyer gets the pack at
    once, for zero generation cost, as their own copy."""
    source_order, source_pack = await _seed_source(test_session)
    source_id, source_pack_id = source_order.id, source_pack.id

    order_id = await _order(client, make_jws)

    arq_mock.enqueue_job.assert_not_called()
    order = await _load(test_session, order_id)
    assert order.status == "delivered"
    assert order.reused_from_order_id == source_id
    assert order.llm_cost_usd == 0
    copy = await test_session.get(QuestionPack, order.pack_id)
    assert copy.id != source_pack_id
    assert copy.user_id == BUYER  # quiz-agent's ownership check reads this
    assert (copy.generation_status, copy.actual_count) == ("complete", COUNT)

    copied = (
        await test_session.execute(select(QuestionRow).where(QuestionRow.pack_id == copy.id))
    ).scalars().all()
    original = (
        await test_session.execute(
            select(QuestionRow).where(QuestionRow.pack_id == source_pack_id)
        )
    ).scalars().all()
    assert sorted(q.question for q in copied) == sorted(q.question for q in original)
    assert not {q.id for q in copied} & {q.id for q in original}
    assert len(original) == COUNT  # the source pack is untouched

    job = await test_session.get(GenerationJob, order.job_id)
    assert job.status == "done"
    # The SSE stream replays step_log and only closes on a terminal step.
    assert job.step_log[-1]["step"] == "done"

    snap = await client.get(f"/v1/orders/{order_id}", headers=_bearer(BUYER))
    assert snap.json()["status"] == "delivered"


@pytest.mark.asyncio
@pytest.mark.parametrize(
    "overrides",
    [
        {"difficulty": "medium"},  # founder: only for the same difficulty
        {"language": "sk"},
        {"prompt": "Harry Potter knihy"},  # different text = different pack
        {"user": SOURCE_OWNER},  # same player again → new questions
    ],
)
async def test_no_copy_when_the_order_differs(
    client: httpx.AsyncClient,
    make_jws: JWSFactory,
    test_session: AsyncSession,
    arq_mock: MagicMock,
    overrides: dict,
) -> None:
    await _seed_source(test_session)

    order_id = await _order(client, make_jws, **overrides)

    arq_mock.enqueue_job.assert_called_once()
    order = await _load(test_session, order_id)
    assert order.status == "in_progress"
    assert order.reused_from_order_id is None


@pytest.mark.asyncio
@pytest.mark.parametrize(
    "source",
    [
        {"order_status": "refunded"},
        {"pack_status": "generating"},
        {"pack_status": "failed"},
        {"questions": COUNT - 5},  # partial pack
        # Expired questions are skipped in the game: the copy would be short.
        {"expires_at": datetime.now(timezone.utc) - timedelta(days=1)},
        # Admin test order / other StoreKit environment never feeds a purchase.
        {"environment": None},
        {"environment": "Production"},
    ],
)
async def test_unfinished_or_refunded_packs_are_not_copied(
    client: httpx.AsyncClient,
    make_jws: JWSFactory,
    test_session: AsyncSession,
    arq_mock: MagicMock,
    source: dict,
) -> None:
    """A pack that never fully succeeded must not spread to other players."""
    await _seed_source(test_session, **source)

    await _order(client, make_jws)

    arq_mock.enqueue_job.assert_called_once()


@pytest.mark.asyncio
async def test_low_rated_pack_is_not_copied(
    client: httpx.AsyncClient,
    make_jws: JWSFactory,
    test_session: AsyncSession,
    arq_mock: MagicMock,
) -> None:
    """A player rated one of its questions 1–2 of 5: generate fresh instead."""
    _, pack = await _seed_source(test_session)
    qid = (
        await test_session.execute(
            select(QuestionRow.id).where(QuestionRow.pack_id == pack.id).limit(1)
        )
    ).scalar_one()
    await test_session.execute(
        text("INSERT INTO question_ratings (id, question_id, rating, created_at)"
             " VALUES ('r1', :q, 2, now())"),
        {"q": str(qid)},
    )
    await test_session.commit()

    await _order(client, make_jws)

    arq_mock.enqueue_job.assert_called_once()


@pytest.mark.asyncio
async def test_low_rating_on_a_copy_stops_further_copies(
    client: httpx.AsyncClient,
    make_jws: JWSFactory,
    test_session: AsyncSession,
    arq_mock: MagicMock,
) -> None:
    """Buyers of copies rate the copied question ids; their verdict must reach
    the original, or a bad pack keeps spreading."""
    await _seed_source(test_session)
    copy_order = await _load(test_session, await _order(client, make_jws, user="player-b"))
    qid = (
        await test_session.execute(
            select(QuestionRow.id).where(QuestionRow.pack_id == copy_order.pack_id).limit(1)
        )
    ).scalar_one()
    await test_session.execute(
        text("INSERT INTO question_ratings (id, question_id, rating, created_at)"
             " VALUES ('r2', :q, 1, now())"),
        {"q": str(qid)},
    )
    await test_session.commit()

    await _order(client, make_jws, user="player-c")

    arq_mock.enqueue_job.assert_called_once()


@pytest.mark.asyncio
async def test_same_person_signed_out_still_gets_new_questions(
    client: httpx.AsyncClient,
    make_jws: JWSFactory,
    test_session: AsyncSession,
    arq_mock: MagicMock,
) -> None:
    """Signed out, the device orders under its anon id, which is linked to the
    account that owns the source pack: still the same player."""
    await test_session.execute(
        text(
            "INSERT INTO anonymous_identities"
            " (anon_id, upgraded_to_user_id, created_at, last_seen_at)"
            " VALUES ('reuse-test-anon', :acct, now(), now())"
        ),
        {"acct": SOURCE_OWNER},
    )
    await test_session.commit()
    await _seed_source(test_session)

    await _order(client, make_jws, user="reuse-test-anon")

    arq_mock.enqueue_job.assert_called_once()


@pytest.mark.asyncio
async def test_copies_never_chain_and_each_buyer_gets_own_pack(
    client: httpx.AsyncClient,
    make_jws: JWSFactory,
    test_session: AsyncSession,
    arq_mock: MagicMock,
) -> None:
    source_order, _ = await _seed_source(test_session)
    source_id = source_order.id

    first_id = await _order(client, make_jws, user="player-b")
    second_id = await _order(client, make_jws, user="player-c")

    arq_mock.enqueue_job.assert_not_called()
    first = await _load(test_session, first_id)
    first_from, first_pack = first.reused_from_order_id, first.pack_id
    second = await _load(test_session, second_id)
    # Both copy the original (never the first copy) into separate packs.
    assert first_from == second.reused_from_order_id == source_id
    assert first_pack != second.pack_id


@pytest.mark.asyncio
async def test_switch_off_always_generates(
    client: httpx.AsyncClient,
    make_jws: JWSFactory,
    test_session: AsyncSession,
    arq_mock: MagicMock,
    app_settings,
) -> None:
    """The kill switch: reuse can be stopped without a deploy."""
    app_settings.pack_reuse_enabled = False
    await _seed_source(test_session)

    await _order(client, make_jws)

    arq_mock.enqueue_job.assert_called_once()


def test_prompt_key_ignores_case_spacing_punctuation_not_diacritics() -> None:
    assert prompt_key("Harry Potter") == prompt_key("  harry   POTTER!! ")
    assert prompt_key("Harry Potter") == prompt_key("Harry-Potter?")
    assert prompt_key("Pán prsteňov") != prompt_key("Pan prstenov")
    assert prompt_key("Harry Potter") != prompt_key("Harry Potter knihy")
