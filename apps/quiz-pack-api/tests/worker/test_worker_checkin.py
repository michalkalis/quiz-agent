"""Worker liveness check-ins (#207 — production readiness, 207.8).

Why these matter: the Sentry Cron monitor is how the founder learns, within
minutes, that no worker is taking paid orders. It is only truthful if
- the worker serving ORDER_QUEUE_NAME is the one checking in — a standby on
  another queue checking in would hide a dead primary;
- a Sentry hiccup never breaks the worker that carries paying customers' packs.
"""

from __future__ import annotations

import pytest
from app.config import get_settings
from app.worker import checkin


@pytest.fixture(autouse=True)
def _fresh_settings(monkeypatch: pytest.MonkeyPatch):
    get_settings.cache_clear()
    yield
    get_settings.cache_clear()


@pytest.fixture
def captured(monkeypatch: pytest.MonkeyPatch) -> list[dict]:
    calls: list[dict] = []
    monkeypatch.setattr(checkin, "capture_checkin", lambda **kw: calls.append(kw))

    class _Client:
        dsn = "https://key@o0.ingest.sentry.io/0"

    monkeypatch.setattr(checkin.sentry_sdk, "get_client", lambda: _Client())
    return calls


def test_fly_worker_on_the_order_queue_checks_in(monkeypatch, captured):
    monkeypatch.delenv("ORDER_QUEUE_NAME", raising=False)
    monkeypatch.delenv("WORKER_QUEUE_NAME", raising=False)
    monkeypatch.setenv("LLM_GATEWAY", "direct")
    assert checkin.check_in() is True
    assert captured[0]["monitor_slug"] == "pack-worker"
    # The monitor config travels with the check-in, so the schedule is code.
    assert captured[0]["monitor_config"]["failure_issue_threshold"] >= 2


def test_standby_worker_on_another_queue_stays_silent(monkeypatch, captured):
    """Orders go to the session queue; the Fly worker on the default queue is
    idle — if it checked in, a dead session worker would never alert."""
    monkeypatch.setenv("ORDER_QUEUE_NAME", "arq:session")
    monkeypatch.delenv("WORKER_QUEUE_NAME", raising=False)
    assert checkin.check_in() is False
    assert captured == []


def test_session_fallback_worker_never_checks_in(monkeypatch, captured):
    """The mba session worker sets both queue names to its own queue; were it
    to check in, it would hide a dead Fly worker (the primary since #207)."""
    monkeypatch.setenv("ORDER_QUEUE_NAME", "quiz-pack:session")
    monkeypatch.setenv("WORKER_QUEUE_NAME", "quiz-pack:session")
    monkeypatch.setenv("LLM_GATEWAY", "session")
    assert checkin.check_in() is False
    assert captured == []


def test_sentry_failure_never_raises(monkeypatch, captured):
    monkeypatch.setenv("LLM_GATEWAY", "direct")

    def boom(**kw):
        raise RuntimeError("sentry down")

    monkeypatch.setattr(checkin, "capture_checkin", boom)
    assert checkin.check_in() is False


def test_no_dsn_is_a_noop(monkeypatch):
    """Local dev and tests have no DSN: nothing is sent."""

    class _NoDsn:
        dsn = None

    monkeypatch.setattr(checkin.sentry_sdk, "get_client", lambda: _NoDsn())
    monkeypatch.setattr(
        checkin, "capture_checkin", lambda **kw: pytest.fail("must not send")
    )
    assert checkin.check_in() is False
