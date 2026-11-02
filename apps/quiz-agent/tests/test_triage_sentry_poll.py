"""Sentry → private triage repo (#218 — crash and feedback automation, 218.3).

Why these matter: every ``sentry_new`` starts a paid-for-by-subscription AI
analysis and opens an issue the founder reads, so
- one Sentry problem is one ``sentry_new``, not one per 5-minute poll;
- more events of a known problem only bump its counter, at most once an hour;
- a problem that comes back (regressed) is announced again;
- only production errors count: staging/development noise, warnings, outages
  (the alarm mail covers those) and in-app feedback (its own branch) never
  reach the triage;
- the kill switch and a missing token send nothing, and a GitHub outage loses
  nothing: what failed is sent on the next poll, and the loop never raises.
"""

from __future__ import annotations

import json
from datetime import datetime, timedelta, timezone

import httpx
import pytest
from app.triage import dispatch as dispatch_mod
from app.triage import sentry_poll as sp

pytestmark = pytest.mark.asyncio

T0 = datetime(2026, 11, 2, 12, 0, tzinfo=timezone.utc)


def _iso(t: datetime) -> str:
    return t.isoformat().replace("+00:00", "Z")


def _issue(id_="101", last_seen=T0, **kw) -> dict:
    return {
        "id": id_,
        "shortId": f"CARQUIZ-{id_}",
        "title": "EXC_BAD_ACCESS in QuizViewModel",
        "level": "fatal",
        "issueCategory": "error",
        "substatus": "new",
        "count": "3",
        "userCount": 2,
        "firstSeen": _iso(T0 - timedelta(minutes=1)),
        "lastSeen": _iso(last_seen),
        "permalink": f"https://missinghue.sentry.io/issues/{id_}/",
        "lastRelease": {"version": "1.2 (83)"},
        **kw,
    }


class MemoryStore:
    def __init__(self) -> None:
        self.state: dict = {}

    async def load(self) -> dict:
        return json.loads(json.dumps(self.state))

    async def save(self, state: dict) -> None:
        self.state = json.loads(json.dumps(state))


class Fake:
    """Sentry answers with ``issues``; GitHub records dispatches (or is down)."""

    def __init__(self) -> None:
        self.issues: list[dict] = []
        self.sentry_params: list[dict] = []
        self.sent: list[dict] = []
        self.github_down = False

    def handler(self, request: httpx.Request) -> httpx.Response:
        if request.url.host == "sentry.io":
            self.sentry_params.append(dict(request.url.params))
            return httpx.Response(200, json=self.issues)
        if self.github_down:
            raise httpx.ConnectError("github unreachable")
        self.sent.append(json.loads(request.content))
        return httpx.Response(204)

    def kinds(self) -> list[tuple[str, str]]:
        return [(d["event_type"], d["client_payload"]["id"]) for d in self.sent]


@pytest.fixture
def env(monkeypatch):
    monkeypatch.setenv(sp.TOKEN_ENV, "sntrys_x")
    monkeypatch.setenv(dispatch_mod.TOKEN_ENV, "github_pat_x")
    fake = Fake()
    store = MemoryStore()

    async def poll(now: datetime) -> None:
        async with httpx.AsyncClient(transport=httpx.MockTransport(fake.handler)) as c:
            await sp.poll(store, None, c, now=now)

    return fake, store, poll


async def test_first_poll_only_sets_the_cursor(env):
    fake, store, poll = env
    fake.issues = [_issue(last_seen=T0 - timedelta(days=2))]
    await poll(T0)
    # Turning the bridge on must not flood the triage with every old problem.
    assert fake.sent == [] and fake.sentry_params == []
    assert store.state["cursor"]


async def test_new_issue_is_sent_once_then_bumped_at_most_hourly(env):
    fake, store, poll = env
    await poll(T0)
    fake.issues = [_issue(last_seen=T0 + timedelta(minutes=4))]
    await poll(T0 + timedelta(minutes=5))
    assert fake.kinds() == [("sentry_new", "101")]
    payload = fake.sent[0]["client_payload"]
    assert payload["short_id"] == "CARQUIZ-101" and payload["release"] == "1.2 (83)"
    assert len(payload) <= 10  # GitHub's client_payload limit

    # Same problem on the next polls: no second sentry_new, and new events
    # inside the hour do not bump yet.
    await poll(T0 + timedelta(minutes=10))
    fake.issues = [_issue(last_seen=T0 + timedelta(minutes=30))]
    await poll(T0 + timedelta(minutes=35))
    assert fake.kinds() == [("sentry_new", "101")]

    # An hour after the last send the pending events are reported, once.
    await poll(T0 + timedelta(minutes=66))
    await poll(T0 + timedelta(minutes=71))
    assert fake.kinds() == [("sentry_new", "101"), ("sentry_bump", "101")]

    # No new events → no bump, however much time passes.
    await poll(T0 + timedelta(hours=3))
    assert len(fake.sent) == 2


async def test_regressed_issue_is_announced_again(env):
    fake, store, poll = env
    await poll(T0)
    fake.issues = [_issue(last_seen=T0 + timedelta(minutes=4), substatus="ongoing")]
    await poll(T0 + timedelta(minutes=5))
    fake.issues = [_issue(last_seen=T0 + timedelta(minutes=9), substatus="regressed")]
    await poll(T0 + timedelta(minutes=10))
    await poll(T0 + timedelta(minutes=15))
    assert fake.kinds() == [("sentry_new", "101"), ("sentry_new", "101")]


async def test_only_production_errors_reach_the_triage(env):
    fake, store, poll = env
    await poll(T0)
    t = T0 + timedelta(minutes=4)
    fake.issues = [
        _issue("1", t, level="warning"),
        _issue("2", t, issueCategory="outage"),
        _issue("3", t, level="error", title="feedback.received id=x chars=12"),
        _issue("4", t, level="error"),
    ]
    await poll(T0 + timedelta(minutes=5))
    assert fake.kinds() == [("sentry_new", "4")]
    params = fake.sentry_params[0]
    assert params["environment"] == "production"
    assert "level:[error,fatal]" in params["query"]


async def test_github_down_loses_nothing_and_never_raises(env):
    fake, store, poll = env
    await poll(T0)
    fake.issues = [_issue(last_seen=T0 + timedelta(minutes=4))]
    fake.github_down = True
    await poll(T0 + timedelta(minutes=5))  # must not raise
    await poll(T0 + timedelta(minutes=30))
    assert fake.sent == []
    fake.github_down = False
    await poll(T0 + timedelta(minutes=35))
    assert fake.kinds() == [("sentry_new", "101")]


async def test_switch_off_sends_nothing(env, monkeypatch):
    fake, store, poll = env

    async def off(_sm):
        return {"triage_bridge_enabled": "false"}

    monkeypatch.setattr(dispatch_mod.app_switches, "cached_overrides", off)
    await poll(T0)
    fake.issues = [_issue(last_seen=T0 + timedelta(minutes=4))]
    await poll(T0 + timedelta(minutes=5))
    assert fake.sent == [] and fake.sentry_params == []


async def test_missing_sentry_token_is_a_quiet_no_op(env, monkeypatch):
    fake, store, poll = env
    monkeypatch.delenv(sp.TOKEN_ENV)
    await poll(T0)
    assert fake.sentry_params == [] and store.state == {}


async def test_missing_github_token_sends_nothing(monkeypatch):
    monkeypatch.delenv(dispatch_mod.TOKEN_ENV, raising=False)
    calls: list = []
    transport = httpx.MockTransport(lambda r: calls.append(r) or httpx.Response(204))
    async with httpx.AsyncClient(transport=transport) as c:
        assert (
            await dispatch_mod.dispatch("app_feedback", {"id": "x"}, None, c) is False
        )
    assert calls == []
