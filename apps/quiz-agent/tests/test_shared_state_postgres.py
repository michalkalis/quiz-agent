"""Volume state moved to Postgres is shared by every machine (#207.20).

Why each matters:
- translation cache: a translation one machine paid Claude for must be reused
  by the other machine, not bought again;
- alert dedupe: two machines (or a new leader after a deploy) must not mail
  the founder twice for the same problem;
- worker ping: the pack worker pings whichever machine the proxy picks; the
  machine that checks must still see it, or it would report a live worker dead;
- cutover import: the first boot of this release copies the old volume's live
  sessions and paid translations, and later boots never overwrite newer rows.
"""

from __future__ import annotations

import json
import sqlite3
import time
from datetime import datetime, timedelta, timezone
from unittest.mock import AsyncMock

import pytest
from app.legacy_volume_import import import_legacy_state
from app.monitoring import pack_watch as pw
from app.monitoring.shared_state import HeartbeatStore, PostgresAlertState
from app.session.manager import SessionManager
from app.session.store import PostgresSessionStore
from app.translation.store import PostgresTranslationStore
from app.translation.translator import TRANSLATION_PROMPT_VERSION, TranslationService
from quiz_shared.ops_alerts import AlertBook

pytestmark = pytest.mark.asyncio


class _Mails:
    def __init__(self) -> None:
        self.subjects: list[str] = []

    async def __call__(self, subject: str, body: str) -> bool:
        self.subjects.append(subject)
        return True


async def test_translation_paid_on_one_machine_is_reused_on_the_other(
    db_sessionmaker, monkeypatch
):
    monkeypatch.setenv("TRANSLATION_MODEL", "gpt-4o-mini")
    a = TranslationService(store=PostgresTranslationStore(db_sessionmaker))
    b = TranslationService(store=PostgresTranslationStore(db_sessionmaker))
    await a._maybe_store(("question", "What is the capital?", "sk"), "Aké je hlavné?")

    b.client = AsyncMock()  # any LLM call would be a paid duplicate
    assert await b.translate_question("What is the capital?", "sk") == "Aké je hlavné?"
    b.client.chat.completions.create.assert_not_called()


async def test_long_source_text_is_cached(db_sessionmaker):
    """Payload keys are whole JSON payloads; they must not hit the btree
    index size limit (the key is a hash of the text)."""
    store = PostgresTranslationStore(db_sessionmaker)
    long_text = "x" * 20000
    await store.put("payload", long_text, "sk", TRANSLATION_PROMPT_VERSION, "y")
    await store.put("payload", long_text, "sk", TRANSLATION_PROMPT_VERSION, "z")
    assert (
        await store.get("payload", long_text, "sk", TRANSLATION_PROMPT_VERSION) == "z"
    )


async def test_two_machines_mail_an_ongoing_problem_once(db_sessionmaker):
    mails = _Mails()
    a = AlertBook(
        "quiz-agent",
        sender=mails,
        store=PostgresAlertState(db_sessionmaker, "quiz-agent"),
    )
    b = AlertBook(
        "quiz-agent",
        sender=mails,
        store=PostgresAlertState(db_sessionmaker, "quiz-agent"),
    )
    await a.update("disk db", "high", "75 %")
    await b.update("disk db", "high", "76 %")  # same state seen by the other machine
    await b.update("disk db", None)
    await a.update("disk db", None)  # already recovered by b
    assert mails.subjects == [
        "[Trubbo ALERT] disk db: high",
        "[Trubbo OK] disk db recovered",
    ]


async def test_worker_ping_on_one_machine_is_seen_by_the_other(
    db_sessionmaker, monkeypatch
):
    mails = _Mails()
    book = AlertBook("t", sender=mails)
    pinged = pw.PackWatch(now=0)
    pinged.heartbeats = HeartbeatStore(db_sessionmaker)
    await pinged.record_ping()

    checker = pw.PackWatch(now=0)  # the other machine never got the ping itself
    checker.heartbeats = HeartbeatStore(db_sessionmaker)
    monkeypatch.setattr(pw, "pack_watch", checker)
    await pw.check_worker(book, now=time.monotonic() + 10_000)  # long past boot grace
    assert mails.subjects == []


def _legacy_files(tmp_path, session_json: str) -> None:
    con = sqlite3.connect(tmp_path / "ratings.db")
    con.execute(
        "CREATE TABLE quiz_sessions (session_id TEXT PRIMARY KEY, data_json TEXT,"
        " is_active BOOLEAN, created_at DATETIME, updated_at DATETIME)"
    )
    con.execute(
        "CREATE TABLE question_ratings (id TEXT PRIMARY KEY, question_id TEXT,"
        " session_id TEXT, user_id TEXT, rating INTEGER, feedback TEXT,"
        " was_correct BOOLEAN, user_answer TEXT, difficulty_at_time TEXT,"
        " created_at DATETIME)"
    )
    con.execute(
        "INSERT INTO quiz_sessions VALUES ('sess_live', ?, 1, '2026-10-16', '2026-10-16')",
        (session_json,),
    )
    expired = json.loads(session_json)
    expired["session_id"] = "sess_old"
    expired["expires_at"] = "2020-01-01T00:00:00+00:00"
    con.execute(
        "INSERT INTO quiz_sessions VALUES ('sess_old', ?, 1, '2020-01-01', '2020-01-01')",
        (json.dumps(expired),),
    )
    con.execute(
        "INSERT INTO question_ratings VALUES ('r1','q1','sess_live','u1',5,NULL,NULL,"
        "NULL,NULL,'2026-10-16 10:00:00')"
    )
    con.commit()
    con.close()
    con = sqlite3.connect(tmp_path / "translations.db")
    con.execute(
        "CREATE TABLE translations (kind TEXT, source_text TEXT, target_language TEXT,"
        " version TEXT, translated_text TEXT,"
        " PRIMARY KEY (kind, source_text, target_language, version))"
    )
    con.execute(
        "INSERT INTO translations VALUES ('question','Hi?','sk',?, 'Ahoj?')",
        (TRANSLATION_PROMPT_VERSION,),
    )
    con.commit()
    con.close()


async def test_cutover_import_copies_live_state_once(db_sessionmaker, tmp_path):
    manager = SessionManager(store=PostgresSessionStore(db_sessionmaker))
    template = await manager.create_session(user_id="u1")
    template.expires_at = datetime.now(timezone.utc) + timedelta(minutes=20)
    live = template.model_copy(update={"session_id": "sess_live"})
    _legacy_files(tmp_path, live.model_dump_json())

    first = await import_legacy_state(str(tmp_path), db_sessionmaker)
    assert first == {"sessions": 1, "ratings": 1, "translations": 1}
    # Personal data must not linger where a later account erasure can't reach.
    assert not (tmp_path / "ratings.db").exists()

    # The new release advances the session; a later boot must not revert it.
    moved = await manager.get_session("sess_live")
    moved.current_question_id = "q9"
    await manager.update_session(moved)
    again = await import_legacy_state(str(tmp_path), db_sessionmaker)
    assert again == {"sessions": 0, "ratings": 0, "translations": 0}
    assert (await manager.get_session("sess_live")).current_question_id == "q9"
    assert await manager.get_session("sess_old") is None

    cached = await PostgresTranslationStore(db_sessionmaker).get(
        "question", "Hi?", "sk", TRANSLATION_PROMPT_VERSION
    )
    assert cached == "Ahoj?"


async def test_cutover_import_without_volume_files_is_a_noop(db_sessionmaker, tmp_path):
    assert await import_legacy_state(str(tmp_path), db_sessionmaker) == {
        "sessions": 0,
        "ratings": 0,
        "translations": 0,
    }
