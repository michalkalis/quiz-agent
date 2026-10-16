"""E-mailed ops alerts (#207 — production readiness).

Why these matter: e-mail is the founder's only alert channel, so the book
must (1) never spam — one mail per problem and state, not one per check run,
and not again after a deploy (state file); (2) never lose an alert — a mail
that failed to send is retried on the next check instead of being marked
sent; (3) send nothing and crash nothing when unconfigured (dev, tests).
"""

from __future__ import annotations

import asyncio

from quiz_shared import ops_alerts
from quiz_shared.ops_alerts import AlertBook


class _Mails:
    def __init__(self, ok: bool = True) -> None:
        self.ok = ok
        self.subjects: list[str] = []

    async def __call__(self, subject: str, body: str) -> bool:
        self.subjects.append(subject)
        return self.ok


def _run(coro):
    return asyncio.run(coro)


def test_state_survives_a_restart_so_ongoing_problems_are_not_resent(tmp_path):
    path = tmp_path / "alerts.json"
    first = _Mails()
    _run(AlertBook("a", path, sender=first).update("disk db", "high", "75 %"))
    after_deploy = _Mails()
    book = AlertBook("a", path, sender=after_deploy)
    _run(book.update("disk db", "high", "76 %"))
    assert first.subjects == ["[Trubbo ALERT] disk db: high"]
    assert after_deploy.subjects == []
    _run(book.update("disk db", None))
    assert after_deploy.subjects == ["[Trubbo OK] disk db recovered"]


def test_failed_send_is_retried_next_time(tmp_path, monkeypatch):
    monkeypatch.setenv("ALERT_SMTP_PASSWORD", "x")
    monkeypatch.setenv("ALERT_EMAIL_TO", "a@b.c")
    failing = _Mails(ok=False)
    book = AlertBook("a", tmp_path / "s.json", sender=failing)
    _run(book.update("pack worker", "down", "no ping"))
    _run(book.update("pack worker", "down", "no ping"))
    assert len(failing.subjects) == 2  # not marked sent → tried again
    assert book.open_problems == {}


def test_recovery_can_be_silent(tmp_path):
    mails = _Mails()
    book = AlertBook("a", None, sender=mails)
    _run(book.update("order 1234", "refund-eligible", notify_recovery=False))
    _run(book.update("order 1234", None, notify_recovery=False))
    assert mails.subjects == ["[Trubbo ALERT] order 1234: refund-eligible"]


def test_unconfigured_mail_logs_and_returns_false(monkeypatch):
    monkeypatch.delenv("ALERT_SMTP_PASSWORD", raising=False)
    assert ops_alerts.send_email("s", "b") is False


def test_smtp_failure_never_raises(monkeypatch):
    monkeypatch.setenv("ALERT_SMTP_PASSWORD", "x")
    monkeypatch.setenv("ALERT_EMAIL_TO", "a@b.c")

    def boom(*a, **kw):
        raise OSError("network down")

    monkeypatch.setattr(ops_alerts.smtplib, "SMTP_SSL", boom)
    assert ops_alerts.send_email("s", "b") is False
