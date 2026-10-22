"""Question stock early warning (#199).

The founder must hear that a (language × category) or the fresh entertainment
stock is running low BEFORE players hit it, so generation can start in time.
These tests pin what makes that alert trustworthy:

- counts come from the real serve predicate (`QuestionRetriever.count_available`
  over the retriever's own filters), never a hand-rolled copy;
- thresholds fire on the right side of the line, per language;
- "fresh" excludes permanent boosts (they never run out) and boosts that end
  before the horizon;
- one Sentry issue per problem, with a fingerprint that does not move with the
  count, so a cell that stays low for a week is one email, not seven;
- the endpoint is admin-only.

The DB-backed proof of the predicate itself lives in
`tests/db/test_question_stock_counts.py`.
"""

from __future__ import annotations

import asyncio
from datetime import UTC, datetime, timedelta
from unittest.mock import AsyncMock, MagicMock

import pytest
import pytest_asyncio
from app.api import deps
from app.api.admin import CATEGORY_TAXONOMY
from app.api.routes import question_stock as route
from app.config import Settings
from app.monitoring import question_stock as qs
from app.retrieval.question_retriever import QuestionRetriever
from fastapi import FastAPI
from httpx import ASGITransport, AsyncClient

pytestmark = pytest.mark.asyncio

NOW = datetime(2026, 10, 10, 12, 0, tzinfo=UTC)
_SETTINGS = Settings()  # defaults: 50 per cell, 15 fresh, 14-day horizon


class _FakeStore:
    """Answers `count` from a table keyed by what the retriever's filters say.

    The cell is read back out of the real filter dict the retriever builds, so
    the probe session (language, category) is what is under test, and every
    call is recorded for the predicate assertions.
    """

    def __init__(self, cells=None, fresh=None, default=100, default_fresh=100):
        self.cells = cells or {}  # (language, category) -> count
        self.fresh = fresh or {}  # language -> count
        self.default = default
        self.default_fresh = default_fresh
        self.calls: list[dict] = []

    async def count(self, filters=None, excluded_ids=None, servable_only=False):
        self.calls.append(
            {
                "filters": filters,
                "excluded_ids": excluded_ids,
                "servable_only": servable_only,
            }
        )
        # Non-English sessions gate on a `$or` of English rows / own-language rows.
        language = filters["$or"][1]["language"] if "$or" in filters else "en"
        (category,) = filters["category"]["$in"]
        if "boost_until" in filters:
            return self.fresh.get(language, self.default_fresh)
        return self.cells.get((language, category), self.default)

    async def structure_fix_pending_ids(self, language):
        return []


def _retriever(store: _FakeStore) -> QuestionRetriever:
    return QuestionRetriever(question_store=store)


def _by_key(report: qs.StockReport) -> dict[tuple, qs.StockAlert]:
    return {(a.kind, a.language, a.category): a for a in report.alerts}


# --- evaluation -----------------------------------------------------------


async def test_healthy_stock_raises_no_alerts():
    report = await qs.fetch_question_stock(_retriever(_FakeStore()), _SETTINGS, now=NOW)

    assert report.alerts == []
    # Every servable language × every taxonomy category is covered, so a
    # category nobody remembered to watch cannot run dry silently.
    assert [lang.language for lang in report.languages] == ["en", "sk", "cs"]
    for lang in report.languages:
        assert list(lang.categories) == list(CATEGORY_TAXONOMY)


@pytest.mark.parametrize("count, alerted", [(49, True), (50, False)])
async def test_cell_alert_threshold_is_strictly_below_the_minimum(count, alerted):
    """Exactly 50 is still enough stock; 49 is the first count that alerts."""
    store = _FakeStore(cells={("sk", "history"): count})

    report = await qs.fetch_question_stock(_retriever(store), _SETTINGS, now=NOW)

    assert (("cell", "sk", "history") in _by_key(report)) is alerted


@pytest.mark.parametrize("count, alerted", [(14, True), (15, False)])
async def test_fresh_alert_threshold_is_strictly_below_the_minimum(count, alerted):
    store = _FakeStore(fresh={"cs": count})

    report = await qs.fetch_question_stock(_retriever(store), _SETTINGS, now=NOW)

    assert (("fresh", "cs", "entertainment") in _by_key(report)) is alerted


async def test_alerts_are_per_language_so_one_dry_language_names_itself():
    """A low Slovak cell must not alert English or Czech, and the message must
    say which one and how many — the founder generates per language."""
    store = _FakeStore(cells={("sk", "sports"): 12}, fresh={"sk": 3})

    report = await qs.fetch_question_stock(_retriever(store), _SETTINGS, now=NOW)

    assert set(_by_key(report)) == {
        ("cell", "sk", "sports"),
        ("fresh", "sk", "entertainment"),
    }
    cell = _by_key(report)[("cell", "sk", "sports")]
    assert "sk/sports" in cell.message and "12" in cell.message
    fresh = _by_key(report)[("fresh", "sk", "entertainment")]
    assert "sk" in fresh.message and "3" in fresh.message and "14 days" in fresh.message


async def test_thresholds_come_from_settings():
    """The founder tunes the minimums by env, not code."""
    settings = Settings(question_stock_min_per_cell=200, question_stock_min_fresh=1)
    store = _FakeStore(default=150, default_fresh=5)

    report = await qs.fetch_question_stock(_retriever(store), settings, now=NOW)

    kinds = {a.kind for a in report.alerts}
    assert kinds == {"cell"}  # 150 < 200 everywhere, fresh 5 >= 1
    assert report.thresholds.min_per_cell == 200


async def test_languages_follow_the_servable_set(monkeypatch):
    """A language switched off in the app must stop being monitored: its empty
    corpus would otherwise alert forever."""
    monkeypatch.setenv("SERVABLE_QUIZ_LANGUAGES", "en,sk")

    report = await qs.fetch_question_stock(_retriever(_FakeStore()), _SETTINGS, now=NOW)

    assert [lang.language for lang in report.languages] == ["en", "sk"]


# --- the predicate --------------------------------------------------------


async def test_counts_use_the_app_store_serve_predicate():
    """The alert is only true if it counts what an App Store session would be
    served: approved only, nothing excluded, servable rows only."""
    store = _FakeStore()

    await qs.fetch_question_stock(_retriever(store), _SETTINGS, now=NOW)

    assert store.calls  # something was counted
    for call in store.calls:
        assert call["filters"]["review_status"] == "approved"
        assert call["filters"]["pack_id"] is None
        assert call["servable_only"] is True
        assert call["excluded_ids"] == []
    # sk/cs sessions also see translated English rows (language_dependent False).
    sk = [c for c in store.calls if "$or" in c["filters"]]
    assert sk
    assert all(c["filters"]["$or"][0].get("language_dependent") is False for c in sk)
    # #206: the smaller "skip local questions" pool runs dry first, so that is
    # the one the warning has to cover.
    assert all(c["filters"]["local_scope"] is None for c in store.calls)


async def test_fresh_window_excludes_permanent_boosts_and_short_boosts():
    """Fresh = boosted for at least 14 more days, but not "forever" (9999-01-01).
    Permanent boosts never expire, so counting them would hide a real shortage;
    boosts ending sooner than the horizon will be gone before generation lands."""
    store = _FakeStore()

    await qs.fetch_question_stock(_retriever(store), _SETTINGS, now=NOW)

    fresh_calls = [c for c in store.calls if "boost_until" in c["filters"]]
    assert len(fresh_calls) == 3  # one per language
    for call in fresh_calls:
        window = call["filters"]["boost_until"]
        assert window["$gt"] == NOW + timedelta(days=14)
        assert window["$lt"] < datetime(9999, 1, 1, tzinfo=UTC)
        assert window["$lt"].year == 9000
        assert call["filters"]["category"] == {"$in": ["entertainment"]}
    # The ordinary cell counts never carry the boost window.
    assert sum("boost_until" in c["filters"] for c in store.calls) == 3


async def test_horizon_is_configurable():
    store = _FakeStore()

    await qs.fetch_question_stock(
        _retriever(store), Settings(question_stock_fresh_horizon_days=30), now=NOW
    )

    window = next(c for c in store.calls if "boost_until" in c["filters"])["filters"][
        "boost_until"
    ]
    assert window["$gt"] == NOW + timedelta(days=30)


async def test_extra_filters_cannot_override_a_serve_constraint():
    """A count that silently drops `review_status` would count unreviewed
    questions as playable stock."""
    retriever = _retriever(_FakeStore())
    probe = qs._probe("en", "history")

    with pytest.raises(ValueError, match="review_status"):
        await retriever.count_available(
            probe, extra_filters={"review_status": "pending_review"}
        )


# --- Sentry ---------------------------------------------------------------


def _alert(kind, language, category, count) -> qs.StockAlert:
    return qs.StockAlert(
        kind=kind,
        language=language,
        category=category,
        count=count,
        threshold=50,
        message=f"low {language}/{category} {count}",
    )


async def test_fingerprint_is_stable_across_counts_and_distinct_per_problem():
    """Same problem on another day (count changed) groups into one Sentry
    issue; different problems never merge, including the entertainment cell
    versus the fresh-entertainment stock of the same language."""
    assert (
        _alert("cell", "sk", "history", 40).fingerprint()
        == _alert("cell", "sk", "history", 12).fingerprint()
    )
    assert (
        _alert("fresh", "sk", "entertainment", 9).fingerprint()
        == _alert("fresh", "sk", "entertainment", 2).fingerprint()
    )
    prints = {
        tuple(a.fingerprint())
        for a in [
            _alert("cell", "sk", "history", 1),
            _alert("cell", "cs", "history", 1),
            _alert("cell", "sk", "sports", 1),
            _alert("cell", "sk", "entertainment", 1),
            _alert("fresh", "sk", "entertainment", 1),
        ]
    }
    assert len(prints) == 5


async def test_sentry_gets_one_issue_per_problem_and_none_when_healthy(monkeypatch):
    captured: list[dict] = []

    def fake_capture(message, level=None, **scope):
        captured.append({"message": message, "level": level, **scope})

    monkeypatch.setattr(qs.sentry_sdk, "capture_message", fake_capture)

    qs.report_to_sentry(
        await qs.fetch_question_stock(_retriever(_FakeStore()), _SETTINGS, now=NOW)
    )
    assert captured == []

    store = _FakeStore(
        cells={("en", "sports"): 0, ("cs", "history"): 30}, fresh={"en": 4}
    )
    qs.report_to_sentry(
        await qs.fetch_question_stock(_retriever(store), _SETTINGS, now=NOW)
    )

    assert [(c["fingerprint"], c["level"]) for c in captured] == [
        (["question-stock", "cell", "en", "sports"], "error"),  # empty: quiz ends
        (["question-stock", "fresh", "en"], "warning"),
        (["question-stock", "cell", "cs", "history"], "warning"),
    ]
    assert "0" in captured[0]["message"] and "en/sports" in captured[0]["message"]


# --- config + loop --------------------------------------------------------


async def test_check_is_opt_in_with_the_locked_thresholds():
    """Tests and local dev make no background DB calls by default; the
    founder-locked numbers are the defaults."""
    s = Settings()
    assert s.question_stock_check_enabled is False
    assert (
        s.question_stock_min_per_cell,
        s.question_stock_min_fresh,
        s.question_stock_fresh_horizon_days,
    ) == (50, 15, 14)


async def test_a_crashed_check_does_not_stop_the_daily_loop(monkeypatch):
    """One DB blip must not end monitoring until the next deploy."""
    sleeps: list[float] = []

    async def fake_sleep(seconds):
        sleeps.append(seconds)
        if len(sleeps) == 3:
            raise asyncio.CancelledError

    fetch = AsyncMock(side_effect=RuntimeError("db down"))
    monkeypatch.setattr(qs.asyncio, "sleep", fake_sleep)
    monkeypatch.setattr(qs, "fetch_question_stock", fetch)

    with pytest.raises(asyncio.CancelledError):
        await qs.run_daily_stock_check(_SETTINGS, MagicMock())

    assert fetch.await_count == 2
    assert sleeps[0] == _SETTINGS.question_stock_initial_delay_s
    assert sleeps[1] >= 24 * 3600


# --- endpoint -------------------------------------------------------------


@pytest_asyncio.fixture
async def api(monkeypatch):
    monkeypatch.setenv("ADMIN_API_KEY", "admin-secret")
    app = FastAPI()
    app.include_router(route.router, prefix="/api/v1")
    app.dependency_overrides[deps.get_question_retriever] = lambda: _retriever(
        _FakeStore(cells={("sk", "history"): 7}, fresh={"cs": 2})
    )
    async with AsyncClient(
        transport=ASGITransport(app=app), base_url="http://test"
    ) as client:
        yield client


@pytest.mark.parametrize("headers", [{}, {"X-Admin-Key": "wrong"}])
async def test_endpoint_rejects_without_valid_admin_key(api, headers):
    """Stock levels are business-sensitive inventory; never public."""
    r = await api.get("/api/v1/admin/question-stock", headers=headers)

    assert r.status_code in (401, 422)
    assert "history" not in r.text


async def test_endpoint_returns_the_whole_table_with_admin_key(api):
    r = await api.get(
        "/api/v1/admin/question-stock", headers={"X-Admin-Key": "admin-secret"}
    )

    assert r.status_code == 200
    body = r.json()
    assert body["thresholds"] == {
        "min_per_cell": 50,
        "min_fresh": 15,
        "fresh_horizon_days": 14,
    }
    by_lang = {lang["language"]: lang for lang in body["languages"]}
    assert by_lang["sk"]["categories"]["history"] == 7
    assert by_lang["cs"]["fresh_entertainment"] == 2
    assert {(a["kind"], a["language"]) for a in body["alerts"]} == {
        ("cell", "sk"),
        ("fresh", "cs"),
    }
