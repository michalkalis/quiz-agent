"""Volume state moved to Postgres is shared by every machine (#207.20).

Why each matters:
- translation cache: a translation one machine paid Claude for must be reused
  by the other machine, not bought again;
- alert dedupe: two machines (or a new leader after a deploy) must not mail
  the founder twice for the same problem;
- worker ping: the pack worker pings whichever machine the proxy picks; the
  machine that checks must still see it, or it would report a live worker dead;
"""

from __future__ import annotations

import time
from unittest.mock import AsyncMock

import pytest
from app.monitoring import pack_watch as pw
from app.monitoring.shared_state import HeartbeatStore, PostgresAlertState
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
