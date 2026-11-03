"""Reuse a finished custom pack for an identical order (#225).

When another player already got a complete pack for the same prompt text,
language and difficulty, a new order is answered with a copy of those
questions instead of a fresh generation run (~$4 saved per pack, instant
delivery). Founder rules (2026-11-02):

- Match = the same text, ignoring letter case, spacing and punctuation.
  Diacritics stay significant ("Pán prsteňov" != "Pan prstenov").
- Full price either way; the purchase path in `create_order` is unchanged.
- The same player ordering the same prompt again gets new questions.

The copy is a new pack owned by the buyer with new question rows, so the
quiz-agent ownership check (`question_packs.user_id`) and the source pack stay
untouched. Any failure here falls back to normal generation.
"""

from __future__ import annotations

import hashlib
import logging
import unicodedata
from datetime import UTC, datetime

from sqlalchemy import func, insert, literal, or_, select, text
from sqlalchemy.dialects.postgresql import UUID as PGUUID
from sqlalchemy.ext.asyncio import AsyncSession

from .config import Settings
from .db.models.job import GenerationJob, append_step
from .db.models.order import GenerationOrder
from .db.models.pack import QuestionPack
from .db.models.question import QuestionRow

logger = logging.getLogger(__name__)

# A player rating of 1–2 (of 5) on any question keeps the pack from spreading.
LOW_RATING_MAX = 2

_SWITCH_QUERY = text("SELECT value FROM app_switches WHERE key = 'pack_reuse_enabled'")

# Columns the copy sets itself instead of taking from the source row.
_FRESH_COLUMNS = {"id", "pack_id", "created_at", "usage_count", "user_ratings"}


def prompt_key(prompt: str) -> str:
    """Stable match key for a prompt: NFKC, case-folded, punctuation and
    symbols as spaces, whitespace collapsed. Hashed so the key has a fixed
    size (a 1000-char prompt can exceed a btree entry) and does not repeat
    the prompt text."""
    folded = unicodedata.normalize("NFKC", prompt).casefold()
    spaced = "".join(
        " " if unicodedata.category(ch)[0] in "PS" else ch for ch in folded
    )
    normalized = " ".join(spaced.split())
    return hashlib.sha256(normalized.encode("utf-8")).hexdigest()


async def reuse_enabled(session: AsyncSession, settings: Settings) -> bool:
    """Live kill switch: quiz-agent's `app_switches` row, env as default."""
    try:
        async with session.begin_nested():
            raw = (await session.execute(_SWITCH_QUERY)).scalar_one_or_none()
    except Exception as e:  # noqa: BLE001 — a broken read must not block orders
        logger.warning("pack reuse switch read failed, using env value: %r", e)
        return settings.pack_reuse_enabled
    if raw is None:
        return settings.pack_reuse_enabled
    return raw != "false"


_IDENTITY_QUERY = text(
    "SELECT anon_id, upgraded_to_user_id FROM anonymous_identities"
    " WHERE anon_id = :uid OR upgraded_to_user_id = :uid"
    " OR upgraded_to_user_id = ("
    "   SELECT upgraded_to_user_id FROM anonymous_identities WHERE anon_id = :uid)"
)


def _same(column, value):
    return column.is_(None) if value is None else column == value


async def _identity_ids(session: AsyncSession, user_id: str) -> set[str]:
    """All ids of one person: the account plus every anon id linked to it.

    A signed-out device falls back to its linked anon id, so comparing raw ids
    would treat the same person as a new player. quiz-agent owns the table;
    a failed read keeps just the given id."""
    ids = {user_id}
    try:
        async with session.begin_nested():
            rows = (await session.execute(_IDENTITY_QUERY, {"uid": user_id})).all()
    except Exception as e:  # noqa: BLE001
        logger.warning("identity lookup failed, using the raw id: %r", e)
        return ids
    for anon_id, account_id in rows:
        ids.add(anon_id)
        if account_id:
            ids.add(account_id)
    return ids


async def _find_source(
    session: AsyncSession, order: GenerationOrder
) -> tuple[GenerationOrder, QuestionPack] | None:
    o = GenerationOrder
    same_key = (
        o.prompt_key == order.prompt_key,
        o.language == order.language,
        _same(o.difficulty, order.difficulty),
        _same(o.category, order.category),
        _same(o.theme, order.theme),
    )

    # Same player, same prompt again → new questions (founder 2026-11-02).
    buyer_ids = await _identity_ids(session, order.user_id)
    prior_own = await session.scalar(
        select(func.count())
        .select_from(o)
        .where(*same_key, o.user_id.in_(buyer_ids), o.id != order.id)
    )
    if prior_own:
        return None

    # Low ratings count on the original and on every copy of it (copies get
    # new question ids, so ratings land there).
    not_low_rated = text(
        "NOT EXISTS (SELECT 1 FROM questions q"
        " JOIN question_packs p ON p.id = q.pack_id"
        " JOIN generation_orders go ON go.id = p.order_id"
        " JOIN question_ratings r ON r.question_id = q.id::text"
        " WHERE (go.id = generation_orders.id"
        "        OR go.reused_from_order_id = generation_orders.id)"
        " AND r.rating <= :low)"
    ).bindparams(low=LOW_RATING_MAX)

    stmt = (
        select(o, QuestionPack)
        .join(QuestionPack, QuestionPack.id == o.pack_id)
        .where(
            *same_key,
            o.id != order.id,
            o.user_id.is_not(None),
            o.user_id.not_in(buyer_ids),
            o.status == "delivered",
            # Only packs made for a real purchase of the same kind: Sandbox
            # (TestFlight, may run on the Claude-subscription backup) never
            # feeds Production, admin test orders (NULL) feed nothing.
            o.storekit_environment.is_not(None),
            o.storekit_environment == order.storekit_environment,
            # Copy from originals only, never from a copy.
            o.reused_from_order_id.is_(None),
            QuestionPack.generation_status == "complete",
            QuestionPack.actual_count >= order.target_count,
            not_low_rated,
        )
        .order_by(o.delivered_at.desc())
        .limit(1)
    )
    row = (await session.execute(stmt)).first()
    return (row[0], row[1]) if row else None


async def _copy_pack(
    session: AsyncSession,
    order: GenerationOrder,
    source_pack: QuestionPack,
) -> tuple[QuestionPack, int]:
    now = datetime.now(UTC)
    pack = QuestionPack(
        order_id=order.id,
        user_id=order.user_id,
        name=source_pack.name,
        description=source_pack.description,
        prompt=order.prompt,
        category=order.category,
        theme=order.theme,
        language=order.language,
        target_count=order.target_count,
        actual_count=0,
        generation_status="complete",
        generated_at=now,
    )
    session.add(pack)
    await session.flush()

    table = QuestionRow.__table__
    copied = [c for c in table.columns if c.name not in _FRESH_COLUMNS]
    source_ids = (
        select(table.c.id)
        .where(
            table.c.pack_id == source_pack.id,
            table.c.review_status.not_in(("rejected", "archived")),
            # The game skips expired questions; don't sell them as playable.
            or_(table.c.expires_at.is_(None), table.c.expires_at > func.now()),
        )
        .order_by(table.c.created_at, table.c.id)
        .limit(order.target_count)
        .scalar_subquery()
    )
    rows = select(
        func.gen_random_uuid(),
        literal(pack.id, PGUUID(as_uuid=True)),
        func.now(),
        literal(0),
        text("'{}'::jsonb"),
        *copied,
    ).where(table.c.id.in_(source_ids))
    result = await session.execute(
        insert(table).from_select(
            ["id", "pack_id", "created_at", "usage_count", "user_ratings",
             *(c.name for c in copied)],
            rows,
        )
    )
    count = result.rowcount or 0
    pack.actual_count = count
    return pack, count


async def try_reuse(
    session: AsyncSession,
    order: GenerationOrder,
    job: GenerationJob,
    settings: Settings,
) -> bool:
    """Deliver the committed `order` from a matching finished pack.

    True = delivered and committed, no generation needed. False = generate as
    usual; any partial copy is rolled back and `order`/`job` are reloaded so
    the caller can enqueue them."""
    try:
        if not await reuse_enabled(session, settings):
            return False
        # Lock + reload the order like `PersistStage.persist_batch`: a sign-in
        # (`rekey_purchases`) moving it to the account either already committed
        # (we read the account id) or waits for our commit and then moves the
        # copied pack too.
        await session.get(
            GenerationOrder, order.id, with_for_update=True, populate_existing=True
        )
        found = await _find_source(session, order)
        if found is None:
            return False
        source_order, source_pack = found
        pack, count = await _copy_pack(session, order, source_pack)
        if count < order.target_count:
            raise _TooFew(count)
        order.pack_id = pack.id
        order.status = "delivered"
        order.delivered_at = datetime.now(UTC)
        order.reused_from_order_id = source_order.id
        order.llm_cost_usd = 0
        order.search_cost_cents = 0
        job.status = "done"
        job.progress = 100
        job.total_cost_cents = 0
        # SSE clients replay step_log and stop at a terminal step.
        await append_step(
            session, job.id, "done", info={"reused_from_order_id": str(source_order.id)}
        )
        await session.commit()
    except Exception as exc:
        if isinstance(exc, _TooFew):
            logger.info("pack reuse skipped for order %s: %s", order.id, exc)
        else:
            logger.exception("pack reuse failed for order %s; generating", order.id)
        await session.rollback()
        await session.refresh(order)
        await session.refresh(job)
        return False
    logger.info(
        "pack_reused order_id=%s source_order_id=%s pack_id=%s questions=%d",
        order.id, source_order.id, pack.id, count,
    )
    return True


class _TooFew(Exception):
    """Rejected/archived questions left the source short of the order size."""

    def __init__(self, count: int) -> None:
        super().__init__(f"only {count} usable questions in the source pack")
