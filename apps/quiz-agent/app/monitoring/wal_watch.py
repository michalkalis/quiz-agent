"""Watch over Postgres WAL archiving to R2 (#207.20, resilience design §3.2).

PITR ships every WAL segment to a private R2 bucket (postgres-flex's built-in
barman-cloud, ``archive_timeout`` 300 s). Its one new failure mode: when
archiving fails (R2 outage, revoked token), Postgres keeps every segment in
``pg_wal`` until the disk fills and Postgres stops — and with it all
gameplay. Three layers, run by the monitor leader on every ops-watch tick:

1. alert when the archiver fails or has not shipped a segment for 15 min
   (with ``archive_timeout`` 300 s a healthy archiver ships at least every
   5 min: the worker heartbeat writes every minute);
2. alert when ``pg_wal`` grows past 500 MB;
3. self-heal past 1.5 GB: ``ALTER SYSTEM SET archive_command = '/bin/true'``
   + reload (no restart), so Postgres recycles WAL. Availability beats PITR;
   the nightly dump still covers the gap. The mail says how to undo it.

Logged only, never mailed (founder 2026-10-16, evening: mail only when
players are affected): layer 3 keeps the disk from filling, and the disk
watch in ops_watch still mails if it fills anyway.

Silent while archiving is not configured (``archive_mode`` off), so this can
ship before the archive is switched on.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass
from datetime import datetime, timezone

from quiz_shared.ops_alerts import AlertBook
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine

logger = logging.getLogger(__name__)

STALE_S = 15 * 60
WAL_WARN_BYTES = 500 * 1024 * 1024
WAL_HEAL_BYTES = 1536 * 1024 * 1024
HEALED_COMMAND = "/bin/true"
KEY_ARCHIVE = "wal archive"
KEY_WAL = "pg_wal size"
KEY_GAP = "PITR gap"

_STATUS = text(
    """
    SELECT current_setting('archive_mode') AS mode,
           current_setting('archive_command') AS command,
           a.last_archived_time, a.last_failed_time, a.failed_count,
           (SELECT coalesce(sum(size), 0) FROM pg_ls_waldir()) AS wal_bytes
    FROM pg_stat_archiver a
    """
)

UNDO = (
    "To restore point-in-time recovery once R2 works again: on the DB machine "
    "(fly ssh console -a quiz-pack-db) run psql -p 5433 -U postgres -c "
    '"ALTER SYSTEM RESET archive_command" -c "SELECT pg_reload_conf()", '
    "then take a fresh base backup: flexctl backup create. "
    "Runbook: docs/setup/db-backup.md (PITR)."
)


@dataclass
class ArchiveStatus:
    mode: str
    command: str
    last_archived: datetime | None
    last_failed: datetime | None
    failed_count: int
    wal_bytes: int

    @property
    def configured(self) -> bool:
        return self.mode in ("on", "always")

    @property
    def healed(self) -> bool:
        return self.command.strip() == HEALED_COMMAND


async def read_status(engine: AsyncEngine) -> ArchiveStatus:
    async with engine.connect() as conn:
        row = (await conn.execute(_STATUS)).one()
    return ArchiveStatus(
        mode=row.mode,
        command=row.command,
        last_archived=row.last_archived_time,
        last_failed=row.last_failed_time,
        failed_count=row.failed_count,
        wal_bytes=int(row.wal_bytes),
    )


async def disable_archiving(engine: AsyncEngine) -> None:
    """``ALTER SYSTEM`` cannot run inside a transaction: autocommit."""
    async with engine.connect() as conn:
        conn = await conn.execution_options(isolation_level="AUTOCOMMIT")
        await conn.execute(
            text(f"ALTER SYSTEM SET archive_command = '{HEALED_COMMAND}'")
        )
        await conn.execute(text("SELECT pg_reload_conf()"))


def _mb(n: int) -> str:
    return f"{n / 1024 / 1024:,.0f} MB"


async def check_wal_archive(
    engine: AsyncEngine, book: AlertBook, now: datetime | None = None
) -> ArchiveStatus | None:
    now = now or datetime.now(timezone.utc)
    st = await read_status(engine)
    if not st.configured:
        return st

    if st.healed:
        await book.update(
            KEY_GAP,
            "archiving off",
            "WAL archiving to R2 is switched off (archive_command = /bin/true), "
            "so point-in-time recovery has a gap; the nightly dump still runs. " + UNDO,
            notify_recovery=True,
            mail=False,
        )
        await book.update(KEY_ARCHIVE, None, notify_recovery=False, mail=False)
    else:
        await book.update(KEY_GAP, None, mail=False)
        failing = st.last_failed is not None and (
            st.last_archived is None or st.last_failed > st.last_archived
        )
        stale = st.last_archived is not None and (
            (now - st.last_archived).total_seconds() > STALE_S
        )
        if failing or stale:
            age = (
                f"{(now - st.last_archived).total_seconds() / 60:.0f} min ago"
                if st.last_archived
                else "never"
            )
            await book.update(
                KEY_ARCHIVE,
                "failing" if failing else "stalled",
                f"Postgres WAL archiving to R2 is {'failing' if failing else 'stalled'}: "
                f"last segment shipped {age}, {st.failed_count} failures, "
                f"pg_wal {_mb(st.wal_bytes)}. Until it recovers pg_wal grows "
                f"~190 MB/h; at {_mb(WAL_HEAL_BYTES)} archiving is switched off "
                "automatically to protect the disk. Check R2 status and the "
                "token (fly ssh console -a quiz-pack-db, flexctl backup list).",
                mail=False,
            )
        else:
            await book.update(KEY_ARCHIVE, None, mail=False)

    if st.wal_bytes >= WAL_HEAL_BYTES and not st.healed:
        logger.error("pg_wal %s: switching WAL archiving off", _mb(st.wal_bytes))
        await disable_archiving(engine)
        await book.update(
            KEY_GAP,
            "archiving off",
            f"pg_wal reached {_mb(st.wal_bytes)} because archiving kept failing; "
            "archiving was switched off automatically so the disk does not fill. "
            + UNDO,
            mail=False,
        )
    if st.wal_bytes >= WAL_WARN_BYTES:
        await book.update(
            KEY_WAL, "high", f"pg_wal is {_mb(st.wal_bytes)}.", mail=False
        )
    else:
        await book.update(KEY_WAL, None, mail=False)
    return st
