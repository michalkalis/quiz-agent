"""#236 — family mode „S deťmi“, increment S1: switches, session creation, the
whole round picked at /start (plan docs/issues/issue-236-family-mode-build.md).

Why these tests matter:
- Every live build creates and starts sessions through the same two routes. A
  family request must not change one byte of what an ordinary session gets,
  and with the switches off (the default) the mode must not exist at all.
- The server, not the app, decides what a family round is (one topic of one
  band, 6 or 10 questions, no pack or room): a client value that slips
  through would play adult questions or a 50-question round to a child.
- A played topic must keep playing by repeating what the family heard
  longest ago; repeating by first play would loop on the same few questions.
"""

from __future__ import annotations

from types import SimpleNamespace
from unittest.mock import AsyncMock, MagicMock

import pytest
from fastapi import HTTPException
from pydantic import ValidationError

from app import app_switches
from app.api.deps import CreateSessionRequest, StartQuizRequest
from app.api.routes.quiz import start_quiz
from app.api.routes.sessions import create_session
from app.auth.identity import AuthSubject
from app.family import rounds
from app.family.topics import BAND_TOPICS, ROUND_SIZE
from app.session.manager import SessionManager
from quiz_shared.models.phase import SessionPhase
from quiz_shared.models.question import AGE_BANDS, Question

pytestmark = pytest.mark.asyncio

TOPIC = "family-dinosaurs"


class _Recorder:
    def __init__(self):
        self.events: list[tuple[str, dict]] = []

    def emit(self, name, *, subject_id=None, session_id=None, properties=None):
        self.events.append((name, properties or {}))


class _Req:
    url = SimpleNamespace(path="/api/v1/sessions")

    def __init__(self, headers=None):
        self.headers = headers or {}
        self.app = SimpleNamespace(state=SimpleNamespace(analytics=_Recorder()))


@pytest.fixture(autouse=True)
def _isolated(monkeypatch):
    from app import rate_limit

    monkeypatch.setattr(rate_limit.limiter, "enabled", False)

    async def _anon(request, user_id, token_service, sessionmaker):
        return AuthSubject(subject_id="u1", is_legacy=False, authenticated=True)

    monkeypatch.setattr("app.api.routes.sessions.resolve_session_subject", _anon)
    app_switches.reset_cache()
    rounds.reset_cache()
    yield
    app_switches.reset_cache()


def _switches(monkeypatch, **on):
    async def _overrides(_sessionmaker):
        return {key: "true" if value else "false" for key, value in on.items()}

    monkeypatch.setattr(app_switches, "cached_overrides", _overrides)


def _question(qid: str, language: str = "sk") -> Question:
    return Question(
        id=qid,
        question="Čo?",
        type="text",
        correct_answer="To",
        topic="t",
        category=TOPIC,
        difficulty="easy",
        language=language,
        age_band="kids_4_6",
    )


async def _next(session, **_):
    """The retriever's fixed-list path, in the session's own language."""
    qid = session.fixed_question_ids[0] if session.fixed_question_ids else "q"
    return _question(qid, session.language)


def _retriever(pool: list[str]) -> MagicMock:
    retriever = MagicMock()
    retriever.band_pool_ids = AsyncMock(return_value=pool)
    retriever.get_next_question = AsyncMock(side_effect=_next)
    retriever.pack_is_generating = AsyncMock(return_value=False)
    return retriever


async def _create(manager, request=None, **body):
    response = await create_session(
        request=request or _Req(),
        body=CreateSessionRequest(**body),
        session_manager=manager,
        token_service=None,
        auth_sessionmaker=None,
    )
    return response


async def _start(manager, session_id, retriever, history, request=None):
    translation = MagicMock()
    translation.translate = AsyncMock(side_effect=AssertionError("translated"))
    return await start_quiz(
        request=request or _Req(),
        session_id=session_id,
        body=StartQuizRequest(excluded_question_ids=history),
        session_manager=manager,
        question_retriever=retriever,
        usage_tracker=None,
        translation_service=translation,
        tts_service=MagicMock(),
        audio=False,
        subject=AuthSubject(subject_id="u1", is_legacy=False, authenticated=True),
    )


# ── Switches off: the API is today's API ─────────────────────────────────────


async def test_switches_off_ordinary_session_is_unchanged_and_family_is_closed():
    manager = SessionManager()
    request = _Req()
    created = await _create(manager, max_questions=7, categories=["science"])
    retriever = _retriever([])
    started = await _start(manager, created.session_id, retriever, ["a"], request)

    stored = await manager.get_session(created.session_id)
    assert created.max_questions == 7 and created.age_band is None
    assert stored.fixed_question_ids == [] and stored.age_band is None
    assert started.repeats is None
    retriever.band_pool_ids.assert_not_awaited()
    # The stored analytics row is exactly today's: None values are dropped.
    from app.analytics.taxonomy import SERVER_EVENTS, clean_properties

    name, props = request.app.state.analytics.events[0]
    stored_props = clean_properties(SERVER_EVENTS[name], props)
    assert "age_band" not in stored_props and "repeats" not in stored_props

    with pytest.raises(HTTPException) as exc:
        await _create(manager, age_band="kids_4_6", categories=[TOPIC])
    assert exc.value.status_code == 403
    assert exc.value.detail["code"] == "family_disabled"


async def test_app_store_build_needs_its_own_switch(monkeypatch):
    _switches(monkeypatch, family_mode_enabled=True)
    manager = SessionManager()
    body = {"age_band": "kids_4_6", "categories": [TOPIC]}

    with pytest.raises(HTTPException) as exc:
        await _create(manager, **body)
    assert exc.value.detail["code"] == "family_disabled"

    testflight = _Req({"X-Build-Channel": "testflight"})
    assert (await _create(manager, request=testflight, **body)).age_band == "kids_4_6"

    _switches(monkeypatch, family_mode_enabled=True, family_mode_enabled_app_store=True)
    assert (await _create(manager, **body)).age_band == "kids_4_6"


# ── Session creation ─────────────────────────────────────────────────────────


async def test_server_sets_round_size_difficulty_images_and_topic(monkeypatch):
    _switches(monkeypatch, family_mode_enabled=True, family_mode_enabled_app_store=True)
    manager = SessionManager()
    for band in AGE_BANDS:
        topic = BAND_TOPICS[band][0]
        created = await _create(
            manager,
            age_band=band,
            categories=[topic],
            max_questions=50,
            difficulty="hard",
            include_images=True,
        )
        stored = await manager.get_session(created.session_id)
        assert stored.max_questions == ROUND_SIZE[band]
        assert stored.current_difficulty == "random"
        assert stored.include_images is False
        assert stored.preferred_categories == [topic] and stored.category == topic
        assert created.age_band == band
    assert ROUND_SIZE == {"kids_4_6": 6, "kids_7_9": 10, "kids_10_12": 10}


@pytest.mark.parametrize(
    "body, code",
    [
        ({"categories": ["family-harry-potter"]}, "family_topic_invalid"),
        ({"categories": [TOPIC, "family-your-body"]}, "family_topic_invalid"),
        ({"categories": ["science"]}, "family_topic_invalid"),
        ({}, "family_topic_invalid"),
        ({"categories": [TOPIC], "mode": "multiplayer"}, "family_mode_conflict"),
        ({"categories": [TOPIC], "pack_id": "p"}, "family_mode_conflict"),
    ],
)
async def test_a_family_request_outside_its_band_is_refused(monkeypatch, body, code):
    _switches(monkeypatch, family_mode_enabled=True, family_mode_enabled_app_store=True)
    with pytest.raises(HTTPException) as exc:
        await _create(SessionManager(), age_band="kids_4_6", **body)
    assert exc.value.status_code == 400
    assert exc.value.detail["code"] == code


def test_an_unknown_band_is_rejected_by_the_request_model():
    with pytest.raises(ValidationError):
        CreateSessionRequest(age_band="kids_13_15", categories=[TOPIC])


# ── The round picked at /start ───────────────────────────────────────────────


async def test_start_plays_the_picked_round_and_signals_repeats(monkeypatch):
    _switches(monkeypatch, family_mode_enabled=True, family_mode_enabled_app_store=True)
    manager = SessionManager()
    created = await _create(manager, age_band="kids_4_6", categories=[TOPIC])
    request = _Req()

    started = await _start(
        manager, created.session_id, _retriever(["a", "b", "c"]), ["b"], request
    )

    stored = await manager.get_session(created.session_id)
    assert started.repeats is True
    assert stored.fixed_question_ids[-1] == "b" and len(stored.fixed_question_ids) == 3
    assert stored.max_questions == 3  # thinner pool → a shorter round
    assert started.current_question.id == stored.fixed_question_ids[0]
    _, props = request.app.state.analytics.events[0]
    assert props["age_band"] == "kids_4_6" and props["repeats"] is True


async def test_an_empty_pool_is_a_coded_409_and_the_session_stays_startable(
    monkeypatch,
):
    _switches(monkeypatch, family_mode_enabled=True, family_mode_enabled_app_store=True)
    manager = SessionManager()
    created = await _create(manager, age_band="kids_4_6", categories=[TOPIC])
    retriever = _retriever([])

    with pytest.raises(HTTPException) as exc:
        await _start(manager, created.session_id, retriever, [])

    assert exc.value.status_code == 409
    assert exc.value.detail["code"] == "family_topic_empty"
    retriever.get_next_question.assert_not_awaited()
    assert (await manager.get_session(created.session_id)).phase == SessionPhase.IDLE
