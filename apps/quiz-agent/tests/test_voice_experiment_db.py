"""#204.9: the voice-settings test as the app and the weekly job see it.

Why these tests matter:
- ``GET /app-config`` is public and runs at every launch of every build
  (1.0 included). The new block must be additive and fail open: no DB or a
  broken read gives ``null`` (the app keeps its manual switches), never a 500.
- The job's dry run is how the founder and the agent look at the numbers
  without consequences; if it wrote anything, a "look" would switch a setting
  on for every player.
- The allowlist decides what reaches the table: the evaluator can only score
  keys the taxonomy keeps, so the contract keys must survive exactly.
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

import pytest
from fastapi import FastAPI
from httpx import ASGITransport, AsyncClient
from sqlalchemy import select

from app.analytics.taxonomy import CLIENT_EVENTS, clean_properties
from app.api.routes import app_config as app_config_routes
from app.api.routes import voice_experiment as voice_experiment_routes
from app.db.models import AnalyticsEvent, VoiceExperimentArm
from app.voice_experiment import served

pytestmark = pytest.mark.asyncio

CONTRACT_ANSWER_CAPTURED = {
    "question_id", "is_retry", "auto_test",
    "src_neural_vad", "src_aec", "src_front_mic",
    "neural_vad", "aec", "front_mic",
    "exp_gen_neural_vad", "exp_gen_aec", "exp_gen_front_mic",
    "route_group", "output_route", "input_route",
    "stop_reason", "detector", "heard_speech",
    "speech_ms", "end_delay_ms", "duration_ms",
    "voice_processing", "ec_enabled", "aec_applicable", "front_mic_applicable",
    "mic_data_source", "mic_polar_pattern", "rejected_count",
}  # fmt: skip
START = datetime.now(timezone.utc) - timedelta(days=7)


@pytest.fixture(autouse=True)
def _fresh_cache():
    served.reset_cache()
    yield
    served.reset_cache()


async def _config(sessionmaker) -> dict:
    app = FastAPI()
    app.include_router(app_config_routes.router, prefix="/api/v1")
    app.state.auth_sessionmaker = sessionmaker
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://t") as c:
        resp = await c.get("/api/v1/app-config")
    assert resp.status_code == 200
    return resp.json()


# ── Taxonomy ─────────────────────────────────────────────────────────────────


async def test_taxonomy_keeps_exactly_the_contract_keys():
    assert CLIENT_EVENTS["answer_captured"] == CONTRACT_ANSWER_CAPTURED
    assert CLIENT_EVENTS["voice_experiment_guard"] == {
        "flag", "reason", "from_route", "to_route", "exp_gen",
    }  # fmt: skip
    props = {k: 1 for k in CONTRACT_ANSWER_CAPTURED} | {"transcript": "my words"}
    assert set(clean_properties(CLIENT_EVENTS["answer_captured"], props)) == (
        CONTRACT_ANSWER_CAPTURED
    )


# ── /app-config ──────────────────────────────────────────────────────────────


async def test_app_config_without_db_serves_null():
    assert (await _config(None))["voice_experiment"] is None


async def test_app_config_fails_open_when_the_read_breaks():
    def _broken():
        raise RuntimeError("db down")

    body = await _config(_broken)
    assert body["voice_experiment"] is None
    assert body["orders_enabled"] is True  # the rest of the config still served


async def _seed(sessionmaker, *rows: tuple[str, str, str, float]) -> None:
    async with sessionmaker() as s:
        for flag, route, status, p_on in rows:
            s.add(VoiceExperimentArm(flag=flag, route_group=route, status=status,
                                     p_on=p_on, generation=1, started_at=START))  # fmt: skip
        await s.commit()


async def test_app_config_serves_the_rows(db_sessionmaker):
    await _seed(
        db_sessionmaker,
        ("neural_vad", "bt_car", "running", 0.5),
        ("aec", "other", "off", 0.0),
    )
    body = await _config(db_sessionmaker)
    assert body["voice_experiment"] == {
        "neural_vad": {"bt_car": {"status": "running", "p_on": 0.5, "generation": 1}},
        "aec": {"other": {"status": "off", "p_on": 0.0, "generation": 1}},
    }


# ── Evaluate endpoint ────────────────────────────────────────────────────────


async def _seed_winner_events(sessionmaker) -> None:
    async with sessionmaker() as s:
        for i in range(100):
            on = i % 2 == 0
            # ON: 5 of 50 answers bad (10 %), OFF: 20 of 50 (40 %).
            bad = (i // 2) % 10 < (1 if on else 4)
            s.add(AnalyticsEvent(
                name="answer_captured", source="ios", session_id=f"s{i}",
                occurred_at=START + timedelta(hours=1, minutes=i),
                properties={"question_id": "q", "src_neural_vad": "auto",
                            "exp_gen_neural_vad": 1, "route_group": "bt_car",
                            "neural_vad": on, "heard_speech": True,
                            "stop_reason": "cap" if bad else "vad"},
            ))  # fmt: skip
        await s.commit()


async def _evaluate(sessionmaker, dry_run: bool, key="k"):
    app = FastAPI()
    app.include_router(voice_experiment_routes.router, prefix="/api/v1")
    app.state.auth_sessionmaker = sessionmaker
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://t") as c:
        return await c.post(
            "/api/v1/admin/voice-experiment/evaluate",
            params={"dry_run": str(dry_run).lower()},
            headers={"X-Admin-Key": key},
        )


async def _row(sessionmaker) -> VoiceExperimentArm:
    async with sessionmaker() as s:
        return (await s.execute(select(VoiceExperimentArm))).scalar_one()


async def test_evaluate_requires_the_admin_key(monkeypatch, db_sessionmaker):
    monkeypatch.setenv("ADMIN_API_KEY", "k")
    assert (await _evaluate(db_sessionmaker, True, key="wrong")).status_code == 401


async def test_dry_run_reports_but_writes_nothing(monkeypatch, db_sessionmaker):
    monkeypatch.setenv("ADMIN_API_KEY", "k")
    await _seed(db_sessionmaker, ("neural_vad", "bt_car", "running", 0.5))
    await _seed_winner_events(db_sessionmaker)

    body = (await _evaluate(db_sessionmaker, True)).json()

    assert body["decisions"] == [{"flag": "neural_vad", "route_group": "bt_car",
                                  "status": "winner_on", "p_on": 1.0, "reason": "winner"}]  # fmt: skip
    (arm,) = body["arms"]
    assert (arm["on"]["n"], arm["on"]["bad"], arm["off"]["n"], arm["off"]["bad"]) == (
        50,
        5,
        50,
        20,
    )
    # Public job log: aggregates only, no session or question ids.
    assert "s1" not in str(body) and "question_id" not in str(body)
    row = await _row(db_sessionmaker)
    assert (row.status, row.p_on, row.decided_at) == ("running", 0.5, None)


async def test_real_run_writes_the_decision(monkeypatch, db_sessionmaker):
    """The app reads p_on from this row, so the verdict must land in it."""
    monkeypatch.setenv("ADMIN_API_KEY", "k")
    await _seed(db_sessionmaker, ("neural_vad", "bt_car", "running", 0.5))
    await _seed_winner_events(db_sessionmaker)

    assert (await _evaluate(db_sessionmaker, False)).status_code == 200

    row = await _row(db_sessionmaker)
    assert (row.status, row.p_on, row.decision_reason) == ("winner_on", 1.0, "winner")
    assert row.decided_at is not None
    # A decided row is not evaluated again next week.
    assert (await _evaluate(db_sessionmaker, False)).json()["decisions"] == []
