"""WAL archive watch (#207.20, resilience design §3.2).

Why: a stuck archiver (R2 outage, revoked token) makes Postgres keep every WAL
segment until the 3 GB volume fills and Postgres stops — all gameplay with it.
The founder must hear about a stuck archive long before that, and past 1.5 GB
the watch must switch archiving off by itself (availability beats PITR). And
the watch must stay silent while archiving is simply not configured, so it can
ship before PITR is switched on.
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

import pytest
from app.monitoring import wal_watch as ww
from quiz_shared.ops_alerts import AlertBook

pytestmark = pytest.mark.asyncio

NOW = datetime(2026, 10, 16, 12, 0, tzinfo=timezone.utc)
MB = 1024 * 1024


class _Mails:
    def __init__(self) -> None:
        self.subjects: list[str] = []

    async def __call__(self, subject: str, body: str) -> bool:
        self.subjects.append(subject)
        return True


def _status(**kw) -> ww.ArchiveStatus:
    base = dict(
        mode="on",
        command="barman-cloud-wal-archive … %p",
        last_archived=NOW - timedelta(minutes=2),
        last_failed=None,
        failed_count=0,
        wal_bytes=64 * MB,
    )
    base.update(kw)
    return ww.ArchiveStatus(**base)


@pytest.fixture
def db(monkeypatch):
    """Fake Postgres: the status it reports and whether archiving got cut."""
    state = {"status": _status(), "disabled": 0}

    async def read_status(engine):
        return state["status"]

    async def disable(engine):
        state["disabled"] += 1
        state["status"] = _status(
            **{**state["status"].__dict__, "command": ww.HEALED_COMMAND}
        )

    monkeypatch.setattr(ww, "read_status", read_status)
    monkeypatch.setattr(ww, "disable_archiving", disable)
    return state


async def test_silent_while_archiving_is_not_configured(db):
    mails = _Mails()
    db["status"] = _status(mode="off", last_archived=None, wal_bytes=2000 * MB)
    await ww.check_wal_archive(None, AlertBook("t", sender=mails), NOW)
    assert mails.subjects == [] and db["disabled"] == 0


async def test_healthy_archiver_sends_nothing(db):
    mails = _Mails()
    await ww.check_wal_archive(None, AlertBook("t", sender=mails), NOW)
    assert mails.subjects == []


async def test_failing_archiver_alerts_once_and_recovers(db):
    mails = _Mails()
    book = AlertBook("t", sender=mails)
    db["status"] = _status(last_failed=NOW - timedelta(minutes=1), failed_count=4)
    await ww.check_wal_archive(None, book, NOW)
    await ww.check_wal_archive(None, book, NOW)  # same state: no second mail
    db["status"] = _status(last_failed=NOW - timedelta(minutes=10))
    await ww.check_wal_archive(None, book, NOW)
    assert mails.subjects == [
        "[Trubbo ALERT] wal archive: failing",
        "[Trubbo OK] wal archive recovered",
    ]


async def test_stalled_archiver_alerts(db):
    """No failure recorded, but nothing shipped for > 15 min although the
    worker heartbeat writes every minute: archiving is stuck."""
    mails = _Mails()
    db["status"] = _status(last_archived=NOW - timedelta(minutes=20))
    await ww.check_wal_archive(None, AlertBook("t", sender=mails), NOW)
    assert mails.subjects == ["[Trubbo ALERT] wal archive: stalled"]


async def test_growing_pg_wal_warns_before_the_self_heal(db):
    mails = _Mails()
    db["status"] = _status(last_failed=NOW, failed_count=99, wal_bytes=600 * MB)
    await ww.check_wal_archive(None, AlertBook("t", sender=mails), NOW)
    assert "[Trubbo ALERT] pg_wal size: high" in mails.subjects
    assert db["disabled"] == 0  # 600 MB is a warning, not yet a cut


async def test_self_heal_cuts_archiving_once_and_reports_the_gap(db):
    mails = _Mails()
    book = AlertBook("t", sender=mails)
    db["status"] = _status(last_failed=NOW, failed_count=999, wal_bytes=1600 * MB)
    await ww.check_wal_archive(None, book, NOW)
    assert db["disabled"] == 1
    assert "[Trubbo ALERT] PITR gap: archiving off" in mails.subjects
    # Next tick: already cut, WAL recycled; no second cut, the gap stays open.
    db["status"] = _status(command=ww.HEALED_COMMAND, wal_bytes=80 * MB)
    await ww.check_wal_archive(None, book, NOW)
    assert db["disabled"] == 1
    assert "PITR gap" in book.open_problems
    # The founder repaired R2 and reset archive_command: gap closes.
    db["status"] = _status()
    await ww.check_wal_archive(None, book, NOW)
    assert mails.subjects[-1] == "[Trubbo OK] PITR gap recovered"
