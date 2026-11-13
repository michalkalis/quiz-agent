"""Shared-quiz rows (#232 — share a quiz by link): the share and one result
per person. A person is every id they play under (see ``person_ids``), so a
sign-in or sign-out never makes the same player look new."""

from __future__ import annotations

import secrets
import uuid
from typing import List, Optional

from sqlalchemy import delete, select, text
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from ..db.base import utcnow
from ..db.models import AnonymousIdentity, SharedQuiz, SharedQuizResult


async def person_ids(db: AsyncSession, subject_id: str) -> List[str]:
    """Every id the same person plays under: the subject, the account its
    anonymous id was signed in to, and that account's other anonymous ids.
    Sign-in moves plays to the account and sign-out returns the device to
    its anon id, so a once-per-person guard on one id alone could be replayed."""
    ids = {subject_id}
    upgraded = (
        await db.execute(
            select(AnonymousIdentity.upgraded_to_user_id).where(
                AnonymousIdentity.anon_id == subject_id
            )
        )
    ).scalar_one_or_none()
    owner = upgraded or subject_id
    ids.add(owner)
    linked = await db.execute(
        select(AnonymousIdentity.anon_id).where(
            AnonymousIdentity.upgraded_to_user_id == owner
        )
    )
    ids.update(linked.scalars())
    return sorted(ids)


class SharedQuizStore:
    def __init__(self, sessionmaker: async_sessionmaker[AsyncSession]) -> None:
        self._sm = sessionmaker

    async def person_ids(self, subject_id: str) -> List[str]:
        async with self._sm() as db:
            return await person_ids(db, subject_id)

    async def owned_pack(self, pack_id: str, subject_id: str) -> Optional[dict]:
        """The pack's name, language and generation status when ``subject_id``
        owns it (the same predicate as the session pack-ownership gate)."""
        try:
            pid = uuid.UUID(str(pack_id))
        except (ValueError, TypeError):
            return None
        async with self._sm() as db:
            row = (
                await db.execute(
                    text(
                        "SELECT name, language, generation_status FROM question_packs "
                        "WHERE id = :pid AND user_id = :uid LIMIT 1"
                    ),
                    {"pid": pid, "uid": subject_id},
                )
            ).first()
        if row is None:
            return None
        return {"name": row[0], "language": str(row[1]), "status": str(row[2])}

    async def existing(
        self, sender: str, *, session_id: Optional[str], pack_id: Optional[str]
    ) -> Optional[SharedQuiz]:
        """The link this sender already made: one per pack (``pack_id``), else
        one per session — sending twice gives the same link."""
        stmt = select(SharedQuiz).where(SharedQuiz.sender_subject_id == sender)
        if pack_id:
            stmt = stmt.where(SharedQuiz.pack_id == uuid.UUID(str(pack_id)))
        else:
            stmt = stmt.where(
                SharedQuiz.source_session_id == session_id,
                SharedQuiz.pack_id.is_(None),
            )
        async with self._sm() as db:
            return (await db.execute(stmt.limit(1))).scalars().first()

    async def insert(self, **fields) -> tuple[SharedQuiz, bool]:
        """Insert unless the same link already exists (partial unique indexes
        on sender + session / sender + pack) → (share, created)."""
        async with self._sm() as db:
            new_id = (
                await db.execute(
                    pg_insert(SharedQuiz)
                    .values(token=secrets.token_urlsafe(16), **fields)
                    .on_conflict_do_nothing()
                    .returning(SharedQuiz.id)
                )
            ).scalar_one_or_none()
            await db.commit()
            if new_id is not None:
                return await db.get(SharedQuiz, new_id), True
        found = await self.existing(
            fields["sender_subject_id"],
            session_id=fields.get("source_session_id"),
            pack_id=fields.get("pack_id"),
        )
        if found is None:  # pragma: no cover - only a token collision
            raise RuntimeError("shared quiz insert conflicted with no existing row")
        return found, False

    async def by_token(self, token: str) -> Optional[SharedQuiz]:
        async with self._sm() as db:
            return (
                await db.execute(select(SharedQuiz).where(SharedQuiz.token == token))
            ).scalar_one_or_none()

    async def by_id(self, share_id: str) -> Optional[SharedQuiz]:
        async with self._sm() as db:
            return await db.get(SharedQuiz, uuid.UUID(str(share_id)))

    async def begin_play(
        self, share: SharedQuiz, subject_id: str, name: Optional[str], *, once: bool
    ) -> bool:
        """Note that this person started the share. ``once`` (a pack): False
        when this person — under any of their ids — already started this pack
        through any link."""
        async with self._sm() as db:
            ids = await person_ids(db, subject_id)
            if (
                once
                and share.pack_id is not None
                and await self._played_pack(db, share.pack_id, ids)
            ):
                return False
            found = await self._row(db, share.id, ids)
            if found is not None:
                if name and found.finished_at is None:
                    found.display_name = name
                    await db.commit()
                return not once
            inserted = await db.execute(
                pg_insert(SharedQuizResult)
                .values(
                    id=uuid.uuid4(),
                    shared_quiz_id=share.id,
                    subject_id=subject_id,
                    display_name=name,
                    started_at=utcnow(),
                )
                .on_conflict_do_nothing()
            )
            await db.commit()
            return bool(inserted.rowcount) or not once

    async def release_play(self, share_id: uuid.UUID, subject_id: str) -> None:
        """Undo an unfinished ``begin_play`` whose session could not be made."""
        async with self._sm() as db:
            await db.execute(
                delete(SharedQuizResult).where(
                    SharedQuizResult.shared_quiz_id == share_id,
                    SharedQuizResult.subject_id == subject_id,
                    SharedQuizResult.finished_at.is_(None),
                )
            )
            await db.commit()

    async def record_result(
        self,
        share_id: uuid.UUID,
        subject_id: str,
        *,
        score: float,
        total: int,
        session_id: Optional[str],
        name: Optional[str] = None,
    ) -> bool:
        """The person's first finish counts; a later or concurrent one changes
        nothing. True when this call recorded the result."""
        now = utcnow()
        async with self._sm() as db:
            ids = await person_ids(db, subject_id)
            found = await self._row(db, share_id, ids)
            if found is None:
                inserted = await db.execute(
                    pg_insert(SharedQuizResult)
                    .values(
                        id=uuid.uuid4(),
                        shared_quiz_id=share_id,
                        subject_id=subject_id,
                        display_name=name,
                        session_id=session_id,
                        score=score,
                        total=total,
                        started_at=now,
                        finished_at=now,
                    )
                    .on_conflict_do_nothing()
                )
                await db.commit()
                if inserted.rowcount:
                    return True
                # A concurrent start or finish wrote the row first.
                found = await self._row(db, share_id, ids)
                if found is None:
                    return False
            if found.finished_at is not None:
                return False
            found.display_name = name or found.display_name
            found.score, found.total = score, total
            found.session_id, found.finished_at = session_id, now
            await db.commit()
            return True

    async def finished_results(self, share_id: uuid.UUID) -> List[SharedQuizResult]:
        async with self._sm() as db:
            return list(
                (
                    await db.execute(
                        select(SharedQuizResult)
                        .where(
                            SharedQuizResult.shared_quiz_id == share_id,
                            SharedQuizResult.finished_at.is_not(None),
                        )
                        .order_by(SharedQuizResult.started_at)
                    )
                ).scalars()
            )

    @staticmethod
    async def _played_pack(db: AsyncSession, pack_id, ids: List[str]) -> bool:
        return (
            await db.execute(
                select(SharedQuizResult.id)
                .join(SharedQuiz, SharedQuizResult.shared_quiz_id == SharedQuiz.id)
                .where(
                    SharedQuiz.pack_id == pack_id, SharedQuizResult.subject_id.in_(ids)
                )
                .limit(1)
            )
        ).first() is not None

    @staticmethod
    async def _row(
        db: AsyncSession, share_id: uuid.UUID, ids: List[str]
    ) -> Optional[SharedQuizResult]:
        return (
            (
                await db.execute(
                    select(SharedQuizResult)
                    .where(
                        SharedQuizResult.shared_quiz_id == share_id,
                        SharedQuizResult.subject_id.in_(ids),
                    )
                    .order_by(SharedQuizResult.started_at)
                    .limit(1)
                    .with_for_update()
                )
            )
            .scalars()
            .first()
        )
