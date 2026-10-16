"""Quiz sessions with TTL, shared by every quiz-agent machine (#207.20).

The stored row is the only copy of a session (``app.session.store``;
Postgres in production), so a request can land on any machine. Two rules keep
concurrent requests from losing each other's writes:

- **Every write is conditional** on the version the writer read
  (``update_session`` raises ``SessionConflict`` when the row moved on). That
  is the backstop: a stale write fails loudly instead of undoing an advance.
- **Writers of an existing session hold its lease** (``session_lock``): an
  in-process ``asyncio.Lock`` (the cheap same-machine path) plus, with a
  ``LeaseStore``, an expiring Postgres lease row, so a duplicate submit landing
  on the other machine waits for the first and then reads its result — the
  same contract the single-machine lock gave (see ``session_lock``).
"""

from __future__ import annotations

import asyncio
import logging
import time
import uuid
from contextlib import asynccontextmanager
from datetime import datetime, timedelta, timezone
from typing import AsyncIterator, Optional

from quiz_shared.models.participant import Participant
from quiz_shared.models.phase import SessionPhase
from quiz_shared.models.session import QuizSession

from ..coordination.leases import LeaseStore, new_holder
from .store import MemorySessionStore, SessionStore

logger = logging.getLogger(__name__)

# A live holder renews its lease every TTL/3 for as long as the request runs;
# a holder killed mid-request (deploy SIGKILL, host loss) frees it within the
# TTL, so the player's retry on the other machine waits at most this long.
SESSION_LEASE_TTL_S = 30.0
# A waiter gives up (503, retryable) after this: today's single-machine lock
# waited without bound, but a submit never legitimately takes this long.
SESSION_LEASE_WAIT_S = 120.0
_LEASE_POLL_MAX_S = 0.25


class SessionConflict(Exception):
    """The session changed after this copy was read; the write was refused."""


class SessionBusy(Exception):
    """Another request holds the session's lease (``wait=False``, or the
    wait exceeded ``SESSION_LEASE_WAIT_S``)."""


class SessionManager:
    def __init__(
        self,
        cleanup_interval: int = 300,
        store: SessionStore | None = None,
        leases: LeaseStore | None = None,
    ):
        """``store`` defaults to the in-process store (tests, DB-less dev);
        ``leases`` None means a single process, where the asyncio lock alone
        serializes."""
        self._store: SessionStore = store or MemorySessionStore()
        self._leases = leases
        # session_id -> [asyncio.Lock, users]; dropped when nobody uses it.
        self._local: dict[str, list] = {}
        self._cleanup_interval = cleanup_interval
        self._cleanup_task: Optional[asyncio.Task] = None

    # ── Lease ──────────────────────────────────────────────────────────────

    @asynccontextmanager
    async def session_lock(
        self, session_id: str, *, wait: bool = True
    ) -> AsyncIterator[None]:
        """Serialize the read→process→write of one session across machines.

        The submit routes hold this across the whole flow: it mutates a copy
        over several awaits (paid STT, judge) and writes it back wholesale, so
        two overlapping submits must not both read the same snapshot. The
        second one waits, then reads the first one's result and takes the
        free resubmission path. ``wait=False`` raises ``SessionBusy`` instead
        of waiting (for best-effort writers that must never delay a reply).

        The Postgres lease is a row with an expiry, not a database lock: no
        connection is held while the caller awaits paid calls."""
        entry = self._local.setdefault(session_id, [asyncio.Lock(), 0])
        lock = entry[0]
        if not wait and lock.locked():
            raise SessionBusy(session_id)
        entry[1] += 1
        try:
            async with lock:
                if self._leases is None:
                    yield
                    return
                name = f"session:{session_id}"
                holder = new_holder()
                await self._acquire_lease(name, holder, wait)
                renew = asyncio.create_task(self._renew_lease(name, holder))
                try:
                    yield
                finally:
                    renew.cancel()
                    try:
                        await self._leases.release(name, holder)
                    except Exception:  # noqa: BLE001 — it expires on its own
                        logger.warning("Lease release failed for %s", name)
        finally:
            entry[1] -= 1
            if entry[1] == 0 and self._local.get(session_id) is entry:
                del self._local[session_id]

    async def _acquire_lease(self, name: str, holder: str, wait: bool) -> None:
        delay = 0.02
        deadline = time.monotonic() + SESSION_LEASE_WAIT_S
        while not await self._leases.try_acquire(name, holder, SESSION_LEASE_TTL_S):
            if not wait or time.monotonic() > deadline:
                raise SessionBusy(name)
            await asyncio.sleep(delay)
            delay = min(delay * 2, _LEASE_POLL_MAX_S)

    async def _renew_lease(self, name: str, holder: str) -> None:
        """Keep a held lease alive while the request runs (a failed renewal
        is retried next round; the TTL covers two misses)."""
        while True:
            await asyncio.sleep(SESSION_LEASE_TTL_S / 3)
            try:
                await self._leases.try_acquire(name, holder, SESSION_LEASE_TTL_S)
            except Exception:  # noqa: BLE001
                logger.warning("Lease renewal failed for %s", name)

    # ── Background cleanup ─────────────────────────────────────────────────

    async def start_cleanup(self):
        if self._cleanup_task is None:
            self._cleanup_task = asyncio.create_task(self._cleanup_loop())

    async def stop_cleanup(self):
        if self._cleanup_task:
            self._cleanup_task.cancel()
            try:
                await self._cleanup_task
            except asyncio.CancelledError:
                pass
            self._cleanup_task = None

    async def _cleanup_loop(self):
        while True:
            try:
                await asyncio.sleep(self._cleanup_interval)
                await self.cleanup_expired()
            except asyncio.CancelledError:
                break
            except Exception as e:
                logger.error("Cleanup error: %s", e)

    async def cleanup_expired(self) -> int:
        """Deactivate expired sessions (idempotent; any machine may run it)."""
        n = await self._store.expire_stale()
        if self._leases is not None:
            await self._leases.purge_expired()
        if n:
            logger.info("Cleaned up %d expired sessions", n)
        return n

    # ── CRUD ───────────────────────────────────────────────────────────────

    async def create_session(
        self,
        max_questions: int = 10,
        difficulty: str = "medium",
        user_id: Optional[str] = None,
        mode: str = "single",
        ttl_minutes: int = 30,
    ) -> QuizSession:
        session_id = f"sess_{uuid.uuid4().hex[:12]}"
        session = QuizSession(
            session_id=session_id,
            user_id=user_id,
            mode=mode,
            max_questions=max_questions,
            current_difficulty=difficulty,
            phase=SessionPhase.IDLE,
            expires_at=datetime.now(timezone.utc) + timedelta(minutes=ttl_minutes),
        )
        if mode == "single":
            session.participants = [
                Participant(
                    participant_id=f"p_{uuid.uuid4().hex[:8]}",
                    user_id=user_id,
                    display_name=user_id or "Player",
                    is_host=True,
                )
            ]
        await self._store.insert(
            session_id, session.model_dump_json(), session.expires_at
        )
        session._store_version = 1
        return session

    async def get_session(self, session_id: str) -> Optional[QuizSession]:
        """A fresh copy of the stored session (mutations stay local until
        ``update_session``), or None when unknown, deleted or expired."""
        stored = await self._store.get(session_id)
        if stored is None:
            return None
        session = QuizSession.model_validate_json(stored.data_json)
        if session.expires_at < datetime.now(timezone.utc):
            await self._store.deactivate(session_id)
            return None
        session._store_version = stored.version
        return session

    async def update_session(self, session: QuizSession) -> bool:
        """Write ``session`` back if nobody else wrote since it was read.

        False when the session is gone (deleted/expired); ``SessionConflict``
        when it changed in the meantime."""
        session.updated_at = datetime.now(timezone.utc)
        new_version = await self._store.update(
            session.session_id,
            session.model_dump_json(),
            session.expires_at,
            session._store_version,
        )
        if new_version is None:
            if await self._store.get(session.session_id) is None:
                return False
            raise SessionConflict(session.session_id)
        session._store_version = new_version
        return True

    async def delete_session(self, session_id: str) -> bool:
        return await self._store.deactivate(session_id)

    async def forget_user(self, user_id: str, db=None) -> tuple[int, int]:
        """Unlink an erased account from its quiz sessions and ratings (GDPR).

        Rows are kept so answers and ratings still count in statistics but no
        longer point at the person; touched sessions are deactivated and their
        version bumped, so an in-flight request holding an old copy cannot
        write the id back. ``db`` = the erasure route's transaction (Postgres
        store). Raises on failure so the caller can abort the erasure.
        Returns (sessions_unlinked, ratings_unlinked)."""
        return await self._store.forget_user(user_id, db)

    async def extend_session(self, session_id: str, minutes: int = 30) -> bool:
        async with self.session_lock(session_id):
            session = await self.get_session(session_id)
            if not session:
                return False
            session.expires_at = datetime.now(timezone.utc) + timedelta(minutes=minutes)
            return await self.update_session(session)

    # ── Multiplayer ────────────────────────────────────────────────────────

    async def add_participant(
        self, session_id: str, display_name: str, user_id: Optional[str] = None
    ) -> Optional[Participant]:
        async with self.session_lock(session_id):
            session = await self.get_session(session_id)
            if not session:
                return None
            participant = Participant(
                participant_id=f"p_{uuid.uuid4().hex[:8]}",
                user_id=user_id,
                display_name=display_name,
                is_host=len(session.participants) == 0,
            )
            session.participants.append(participant)
            await self.update_session(session)
            return participant

    async def remove_participant(self, session_id: str, participant_id: str) -> bool:
        async with self.session_lock(session_id):
            session = await self.get_session(session_id)
            if not session:
                return False
            session.participants = [
                p for p in session.participants if p.participant_id != participant_id
            ]
            if session.participants and not any(
                p.is_host for p in session.participants
            ):
                session.participants[0].is_host = True
            await self.update_session(session)
            return True
