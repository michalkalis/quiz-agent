"""/v1/orders — create, read, list, retry generation orders.

`POST /v1/orders` authenticates via a StoreKit JWS in the `X-StoreKit-JWS`
header, **or** (#95 founder path, payments deferred) via the `X-Admin-Key`
header, and creates (or idempotently returns) a generation order + job. A
quiz-agent bearer JWT is also REQUIRED (#103 F3) alongside either of those —
a bearer-less order writes `user_id=NULL`, which orphans the generated pack:
the quiz-agent ownership check requires `user_id = :subject_id` (NULL never
matches → 404) and it never appears in `GET /v1/orders`, so the pack is paid
for, generated (LLM cost spent), and then permanently unplayable/unlistable.

`GET /v1/orders` lists the caller's own orders (bearer JWT required).

`GET /v1/orders` lists the caller's own orders (bearer JWT required).

`GET /v1/orders/{order_id}` returns the order plus a snapshot of its job.
Requires the admin key or a bearer JWT matching the order's `user_id` — the
Phase-1 unauthenticated read is closed (#95).

Ops note: prod machines auto-suspend; the first order after idle waits for the
worker machine to wake, so early progress can sit at 0% for tens of seconds —
accepted for the founder-only phase (#95 Session 1).
"""

from __future__ import annotations

import uuid
from datetime import datetime
from decimal import Decimal
from typing import Annotated, Optional

from fastapi import APIRouter, Depends, Header, HTTPException, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel, ConfigDict
from redis.asyncio import Redis
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from sse_starlette.sse import EventSourceResponse

from arq.connections import ArqRedis

from ...config import Settings, get_settings
from ...db.models.job import GenerationJob
from ...db.models.order import GenerationOrder
from ...db.session import AsyncSessionLocal, get_session
from ...sse import event_stream
from ...sse.jws_cache import verify_jws_cached
from ...storekit import AppleJWSVerifier, JWSError, JWSWrongBundle
from ..deps import (
    admin_key_presented,
    check_admin_key,
    get_arq_pool,
    get_jws_verifier,
    get_redis_url,
    optional_user,
    require_user,
)

router = APIRouter(prefix="/v1/orders", tags=["orders"])

# Server-authoritative product → question count mapping.
_PRODUCT_TIERS: dict[str, int] = {
    "pack_10": 10,
    "pack_20": 20,
    "pack_30": 30,
    "pack_50": 50,
}

_ALLOWED_LANGUAGES = {"en", "sk", "cs"}

# Admin-created orders (#95) synthesize their own transaction ids. The prefix
# keeps them disjoint from Apple's numeric transaction ids so a founder order
# can never squat the idempotency slot of a future real purchase.
_ADMIN_TX_PREFIX = "admin-"


# ---------------------------------------------------------------------------
# Request / response models
# ---------------------------------------------------------------------------


class CreateOrderRequest(BaseModel):
    transaction_id: str
    product_id: str
    prompt: str
    language: str
    target_count: int  # informational; server derives authoritative count from product_id
    category: Optional[str] = None
    theme: Optional[str] = None


class OrderCreatedResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    order_id: uuid.UUID
    status: str
    created_at: datetime


class JobSnapshotResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    job_id: uuid.UUID
    status: str
    progress: int
    retry_count: int
    total_cost_cents: int
    error: Optional[str]
    updated_at: datetime


class OrderSnapshotResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    order_id: uuid.UUID
    status: str
    product_id: str
    target_count: int
    language: str
    category: Optional[str]
    theme: Optional[str]
    created_at: datetime
    delivered_at: Optional[datetime]
    pack_id: Optional[uuid.UUID]
    # Measured spend (#95 decision 5); fine to expose while prod is
    # founder-only — hide behind the admin key before real users.
    llm_cost_usd: Optional[Decimal]
    search_cost_cents: int
    # #103 F4c: set on terminal failure (_handle_failure / the sweep) so a
    # client/admin can actually see it — previously written but never read.
    refund_eligible: bool
    job: Optional[JobSnapshotResponse]


class OrderListResponse(BaseModel):
    orders: list[OrderSnapshotResponse]


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _validate_guards(body: CreateOrderRequest) -> None:
    """Raise HTTPException for prompt length or language violations."""
    if not (10 <= len(body.prompt.strip()) <= 1000):
        raise HTTPException(
            status_code=422,
            detail="prompt must be between 10 and 1000 characters (after stripping whitespace)",
        )
    if body.language not in _ALLOWED_LANGUAGES:
        raise HTTPException(
            status_code=422,
            detail=f"language must be one of {sorted(_ALLOWED_LANGUAGES)}",
        )


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------


@router.post("", status_code=202, response_model=OrderCreatedResponse)
async def create_order(
    request: Request,
    body: CreateOrderRequest,
    session: Annotated[AsyncSession, Depends(get_session)],
    arq_pool: Annotated[ArqRedis, Depends(get_arq_pool)],
    verifier: Annotated[AppleJWSVerifier, Depends(get_jws_verifier)],
    settings: Annotated[Settings, Depends(get_settings)],
    user_id: Annotated[str, Depends(require_user)],
    x_storekit_jws: Annotated[Optional[str], Header()] = None,
) -> OrderCreatedResponse:
    """Create a generation order from a verified StoreKit JWS or admin key.

    The admin-key path (#95, payments deferred) skips StoreKit entirely: the
    founder build sends `X-Admin-Key` plus a self-generated
    `admin-{uuid}` transaction id. A quiz-agent bearer JWT is REQUIRED
    alongside either path (#103 F3) — it links the order to that account so
    it shows up in `GET /v1/orders` and so the generated pack is ever
    playable (the quiz-agent ownership check needs a real `user_id`; NULL
    never matches). `require_user` raises 401 before this body runs when the
    bearer is missing or invalid, and 503 if bearer auth isn't configured.

    Returns 202 on creation and 200 on idempotent replay (same transaction_id).
    """
    if x_storekit_jws:
        # 1. Verify JWS
        try:
            tx = verifier.verify(x_storekit_jws)
        except JWSWrongBundle as exc:
            raise HTTPException(status_code=403, detail=str(exc)) from exc
        except JWSError as exc:
            raise HTTPException(status_code=401, detail=str(exc)) from exc

        # 2. Cross-check body vs JWS payload
        if body.transaction_id != tx.transaction_id or body.product_id != tx.product_id:
            raise HTTPException(status_code=400, detail="JWS payload does not match body")
    elif admin_key_presented(request):
        check_admin_key(request, settings)
        if not body.transaction_id.startswith(_ADMIN_TX_PREFIX):
            raise HTTPException(
                status_code=400,
                detail=f"admin orders must use a {_ADMIN_TX_PREFIX!r}-prefixed transaction_id",
            )
    else:
        raise HTTPException(
            status_code=401,
            detail="X-StoreKit-JWS or X-Admin-Key header is required",
        )

    # 3. Authoritative target_count from product_id
    target_count = _PRODUCT_TIERS.get(body.product_id)
    if target_count is None:
        raise HTTPException(
            status_code=400,
            detail=f"unknown product_id {body.product_id!r}; valid: {sorted(_PRODUCT_TIERS)}",
        )

    # 4. Guards (before any DB write)
    _validate_guards(body)

    # 5. Idempotency check
    stmt = select(GenerationOrder).where(GenerationOrder.transaction_id == body.transaction_id)
    existing = (await session.execute(stmt)).scalars().first()
    if existing is not None:
        return JSONResponse(  # type: ignore[return-value]
            status_code=200,
            content={
                "order_id": str(existing.id),
                "status": existing.status,
                "created_at": existing.created_at.isoformat(),
            },
        )

    # 6. Insert order + job
    order = GenerationOrder(
        user_id=user_id,
        transaction_id=body.transaction_id,
        product_id=body.product_id,
        prompt=body.prompt,
        language=body.language,
        target_count=target_count,
        category=body.category,
        theme=body.theme,
        status="pending",
    )
    session.add(order)
    await session.flush()  # get order.id

    job = GenerationJob(order_id=order.id, status="queued")
    session.add(job)
    await session.flush()  # get job.id

    order.job_id = job.id
    await session.flush()

    await session.commit()

    # 7. Enqueue ARQ — after commit so the worker can read the row.
    # #103 F4a: a Redis blip here used to leave the order 'pending' forever
    # (replay just returns it, and retry needs 'failed' — a 409). Mark it
    # failed+refund_eligible immediately instead so the client sees a clear
    # error and can retry via POST /v1/orders/{id}/retry rather than polling
    # a silently stuck order. The periodic sweep (app.worker.sweep) is the
    # remaining safety net for orders that slip past this point.
    try:
        await arq_pool.enqueue_job("process_order", str(order.id))
    except Exception as exc:
        job.status = "failed"
        job.error = f"enqueue failed: {exc!r}"
        order.status = "failed"
        order.refund_eligible = True
        await session.commit()
        raise HTTPException(
            status_code=503,
            detail=(
                "failed to enqueue generation job; order marked failed — "
                "retry via POST /v1/orders/{order_id}/retry"
            ),
        ) from exc

    # 8. Transition to in_progress
    order.status = "in_progress"
    await session.commit()

    return OrderCreatedResponse(order_id=order.id, status=order.status, created_at=order.created_at)


def _job_snapshot(job: Optional[GenerationJob]) -> Optional[JobSnapshotResponse]:
    if job is None:
        return None
    return JobSnapshotResponse(
        job_id=job.id,
        status=job.status,
        progress=job.progress,
        retry_count=job.retry_count,
        total_cost_cents=job.total_cost_cents,
        error=job.error,
        updated_at=job.updated_at,
    )


def _order_snapshot(
    order: GenerationOrder, job: Optional[GenerationJob]
) -> OrderSnapshotResponse:
    return OrderSnapshotResponse(
        order_id=order.id,
        status=order.status,
        product_id=order.product_id,
        target_count=order.target_count,
        language=order.language,
        category=order.category,
        theme=order.theme,
        created_at=order.created_at,
        delivered_at=order.delivered_at,
        pack_id=order.pack_id,
        llm_cost_usd=order.llm_cost_usd,
        search_cost_cents=order.search_cost_cents,
        refund_eligible=order.refund_eligible,
        job=_job_snapshot(job),
    )


@router.get("", response_model=OrderListResponse)
async def list_orders(
    session: Annotated[AsyncSession, Depends(get_session)],
    subject: Annotated[str, Depends(require_user)],
) -> OrderListResponse:
    """List the caller's own orders, newest first (#95 "My packs").

    Ownership comes from the quiz-agent bearer JWT — the same identity the
    voice-quiz app already holds, so delivered packs land in the right
    account without a second login.
    """
    stmt = (
        select(GenerationOrder)
        .where(GenerationOrder.user_id == subject)
        .order_by(GenerationOrder.created_at.desc())
    )
    orders = (await session.execute(stmt)).scalars().all()

    jobs_by_id: dict[uuid.UUID, GenerationJob] = {}
    job_ids = [o.job_id for o in orders if o.job_id is not None]
    if job_ids:
        job_stmt = select(GenerationJob).where(GenerationJob.id.in_(job_ids))
        jobs_by_id = {
            j.id: j for j in (await session.execute(job_stmt)).scalars().all()
        }

    return OrderListResponse(
        orders=[_order_snapshot(o, jobs_by_id.get(o.job_id)) for o in orders]
    )


@router.get("/{order_id}", response_model=OrderSnapshotResponse)
async def get_order(
    request: Request,
    order_id: uuid.UUID,
    session: Annotated[AsyncSession, Depends(get_session)],
    settings: Annotated[Settings, Depends(get_settings)],
    subject: Annotated[Optional[str], Depends(optional_user)],
) -> OrderSnapshotResponse:
    """Return order + job snapshot.

    Authz (#95, closes the Phase-1 unauthenticated read): a valid admin key
    sees any order; otherwise the bearer JWT subject must own the order.
    Auth is checked before existence so unauthenticated callers can't probe
    which order ids exist.
    """
    is_admin = False
    if admin_key_presented(request):
        check_admin_key(request, settings)
        is_admin = True
    elif subject is None:
        raise HTTPException(
            status_code=401,
            detail="Bearer token or X-Admin-Key is required",
        )

    stmt = select(GenerationOrder).where(GenerationOrder.id == order_id)
    order = (await session.execute(stmt)).scalars().first()
    if order is None:
        raise HTTPException(status_code=404, detail=f"order {order_id} not found")

    if not is_admin and order.user_id != subject:
        raise HTTPException(status_code=403, detail="order belongs to another account")

    job: Optional[GenerationJob] = None
    if order.job_id is not None:
        job_stmt = select(GenerationJob).where(GenerationJob.id == order.job_id)
        job = (await session.execute(job_stmt)).scalars().first()

    return _order_snapshot(order, job)


@router.post("/{order_id}/retry", status_code=202, response_model=OrderCreatedResponse)
async def retry_order(
    request: Request,
    order_id: uuid.UUID,
    session: Annotated[AsyncSession, Depends(get_session)],
    arq_pool: Annotated[ArqRedis, Depends(get_arq_pool)],
    verifier: Annotated[AppleJWSVerifier, Depends(get_jws_verifier)],
    redis_url: Annotated[str, Depends(get_redis_url)],
    settings: Annotated[Settings, Depends(get_settings)],
    x_storekit_jws: Annotated[Optional[str], Header()] = None,
) -> OrderCreatedResponse:
    """Re-enqueue a failed order (M-2).

    Authz: ``X-StoreKit-JWS`` must verify and its ``transaction_id`` must match
    the order's recorded ``transaction_id`` (verification reuses the 60s Redis
    cache from #33 Task 1.11) — or a valid ``X-Admin-Key`` (#95: admin orders
    have no JWS, and a failed founder order must stay retryable).

    Flow:
        409 if ``order.status != 'failed'``.
        422 if ``job.manual_retry_count >= 3`` (#103 F1: the manual-retry
        budget, separate from ``retry_count`` — the ARQ auto-attempt counter
        that is always 3 on a terminal failure, which used to make this
        endpoint permanently 422 for every real failure).
        Otherwise: ``SELECT ... FOR UPDATE`` row-locks order + job (R14 —
        prevents double-enqueue under concurrent retries), resets job to
        ``queued``/``progress=0``/``error=NULL``/``retry_count=0`` (fresh ARQ
        attempt sequence), increments ``manual_retry_count``, flips order to
        ``pending`` → commit → ARQ enqueue → ``in_progress``.
    """
    tx = None
    if x_storekit_jws:
        redis_conn: Redis = Redis.from_url(redis_url, decode_responses=True)
        try:
            try:
                tx = await verify_jws_cached(x_storekit_jws, verifier, redis_conn)
            except JWSWrongBundle as exc:
                raise HTTPException(status_code=403, detail=str(exc)) from exc
            except JWSError as exc:
                raise HTTPException(status_code=401, detail=str(exc)) from exc
        finally:
            await redis_conn.aclose()
    elif admin_key_presented(request):
        check_admin_key(request, settings)
    else:
        raise HTTPException(
            status_code=401,
            detail="X-StoreKit-JWS or X-Admin-Key header is required",
        )

    # Row-lock order: concurrent retries must serialise so we don't double-enqueue
    # (ARQ's own dedup is best-effort, not transactional — see R14).
    order_stmt = (
        select(GenerationOrder).where(GenerationOrder.id == order_id).with_for_update()
    )
    order = (await session.execute(order_stmt)).scalars().first()
    if order is None:
        raise HTTPException(status_code=404, detail=f"order {order_id} not found")

    if tx is not None and order.transaction_id != tx.transaction_id:
        raise HTTPException(
            status_code=403,
            detail="JWS transaction_id does not match this order",
        )

    if order.status != "failed":
        raise HTTPException(
            status_code=409,
            detail=(
                f"order status is {order.status!r}; only 'failed' orders can be retried"
            ),
        )

    if order.job_id is None:
        raise HTTPException(status_code=409, detail="order has no job to retry")

    job_stmt = (
        select(GenerationJob).where(GenerationJob.id == order.job_id).with_for_update()
    )
    job = (await session.execute(job_stmt)).scalars().first()
    if job is None:
        raise HTTPException(status_code=409, detail="order has no job to retry")

    if job.manual_retry_count >= 3:
        raise HTTPException(
            status_code=422,
            detail=(
                f"retry cap reached (manual_retry_count={job.manual_retry_count}, "
                "max=3)"
            ),
        )

    job.status = "queued"
    job.progress = 0
    job.error = None
    job.retry_count = 0
    job.manual_retry_count = job.manual_retry_count + 1
    order.status = "pending"
    await session.commit()

    await arq_pool.enqueue_job("process_order", str(order.id))

    order.status = "in_progress"
    await session.commit()

    return OrderCreatedResponse(
        order_id=order.id, status=order.status, created_at=order.created_at
    )


@router.get("/{order_id}/stream")
async def stream_order(
    order_id: uuid.UUID,
    verifier: Annotated[AppleJWSVerifier, Depends(get_jws_verifier)],
    redis_url: Annotated[str, Depends(get_redis_url)],
    x_storekit_jws: Annotated[Optional[str], Header()] = None,
    last_event_id: Annotated[Optional[str], Header()] = None,
) -> EventSourceResponse:
    """Stream generation progress as SSE events.

    Authz: ``X-StoreKit-JWS`` must verify to a ``SignedTransaction`` whose
    ``transaction_id`` matches the order's recorded ``transaction_id``.

    ``Last-Event-ID`` header: resume from that event (inclusive-exclusive,
    i.e. only events with ``event_id > Last-Event-ID`` are emitted). Omitting
    the header is treated as ``-1`` — all events replay from the beginning.
    """
    if not x_storekit_jws:
        raise HTTPException(status_code=401, detail="X-StoreKit-JWS header is required")

    # Open a *dedicated* Redis connection for this SSE request (pubsub holds a
    # socket open; we must not reuse the ARQ pool connection).
    redis_conn: Redis = Redis.from_url(redis_url, decode_responses=True)
    try:
        try:
            tx = await verify_jws_cached(x_storekit_jws, verifier, redis_conn)
        except JWSWrongBundle as exc:
            raise HTTPException(status_code=403, detail=str(exc)) from exc
        except JWSError as exc:
            raise HTTPException(status_code=401, detail=str(exc)) from exc

        # Fetch order to cross-check transaction_id.
        async with AsyncSessionLocal() as session:
            stmt = select(GenerationOrder).where(GenerationOrder.id == order_id)
            order = (await session.execute(stmt)).scalars().first()

        if order is None:
            raise HTTPException(status_code=404, detail=f"order {order_id} not found")

        if order.transaction_id != tx.transaction_id:
            raise HTTPException(
                status_code=403,
                detail="JWS transaction_id does not match this order",
            )

        # Parse Last-Event-ID; sentinel -1 means "replay everything".
        try:
            resume_from = int(last_event_id) if last_event_id is not None else -1
        except ValueError:
            resume_from = -1

    finally:
        # Close the verify-cache connection; event_stream opens its own.
        await redis_conn.aclose()

    return EventSourceResponse(
        event_stream(
            order_id=str(order_id),
            last_event_id=resume_from,
            session_factory=AsyncSessionLocal,
            redis_url=redis_url,
        ),
        headers={"X-Accel-Buffering": "no"},
    )
