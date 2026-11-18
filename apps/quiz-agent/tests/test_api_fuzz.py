"""#235.6: nonsense input against the player-facing API never 500s.

Why: the app is not the only thing that talks to the server — old builds,
half-sent requests, a corrupted retry, a curious user with curl. Every
endpoint a player's phone uses (quiz sessions, answers by text and voice, the
read-aloud, games together, shared quizzes, app config) must answer anything
with a clear 4xx the app can act on, and its documented answers must match
the OpenAPI schema the hand-written iOS models are built from. A 500 is what
the app treats as "server broken, retry" — on a malformed request that loop
never ends.

How: schemathesis generates requests from the real app's own OpenAPI schema
and sends them in-process (ASGI, no server) to ``app.main.app`` — its real
middleware and error handlers — with every provider replaced by a fake (no
network, no spend). Path ids are swapped for a live session / room / shared
quiz owned by the caller, so the generated bodies reach the handlers instead
of stopping at "404 not found". Hypothesis runs derandomized with a fixed
example budget, so a run is reproducible and bounded in time.
"""

from __future__ import annotations

import asyncio
import os

os.environ.setdefault("OPENAI_API_KEY", "sk-test")

import httpx  # noqa: E402
import pytest  # noqa: E402
import schemathesis  # noqa: E402
from hypothesis import HealthCheck, Phase, given, settings  # noqa: E402
from schemathesis.checks import (  # noqa: E402
    not_a_server_error,
    response_schema_conformance,
)
from schemathesis.core.failures import FailureGroup  # noqa: E402

from quiz_shared.models.phase import SessionPhase  # noqa: E402

from app import app_switches  # noqa: E402
from app.analytics.recorder import AnalyticsRecorder  # noqa: E402
from app.auth.tokens import TokenService  # noqa: E402
from app.daily_challenge.service import DailyChallengeService  # noqa: E402
from app.main import app as main_app  # noqa: E402
from app.monitoring import ops_watch  # noqa: E402
from app.quiz.flow import QuizFlowService  # noqa: E402
from app.rate_limit import limiter  # noqa: E402
from app.rooms.network import NetTickets  # noqa: E402
from app.rooms.play import RoomPlay  # noqa: E402
from app.rooms.service import RoomService  # noqa: E402
from app.rooms.store import MemoryRoomStore  # noqa: E402
from app.session.manager import SessionManager  # noqa: E402
from app.shared_quiz.service import SharedQuizService  # noqa: E402
from app.usage.caps import UsageCaps  # noqa: E402
from tests.test_answer_retry_contract import _Transcriber  # noqa: E402
from tests.test_room_play import Judge, Usage  # noqa: E402
from tests.test_shared_quiz import FakeRetriever, FakeStore  # noqa: E402

pytestmark = pytest.mark.asyncio

_SECRET = "f" * 64
_SUBJECT = "fuzz-player"
# Player-facing surface only: admin, auth bootstrap and webhooks have their
# own suites and are not reachable from a player's phone.
_PLAYER_PATHS = r"^/api/v1/(sessions|voice/submit|rooms|shared-quizzes|app-config)"
# Known schema mismatches, reported in #235.6 and left as they are because the
# fix changes the published contract: these routes answer a business 422 with
# ``{"code", "message"}`` while FastAPI documents every 422 as its validation
# error list. A 5xx is never excused here — only the body-shape check.
_KNOWN_422_SHAPE = {
    "POST /api/v1/shared-quizzes",
}
# Per operation: ~45 operations x 40 examples run in about 20 s locally;
# derandomize makes it the same examples every run.
_EXAMPLES = 40


class _Retriever(FakeRetriever):
    """The shared-quiz corpus fake, plus what the solo serve path asks for."""

    async def get_next_question(self, session, client_excluded_ids=None, **_):
        asked = set(session.asked_question_ids)
        return next((q for q in self.pool if q.id not in asked), None)

    async def pack_is_generating(self, pack_id):
        return False

    async def pack_status(self, pack_id):
        return None


class _Parser:
    """Every non-empty utterance is an answer (the LLM parser is mocked)."""

    async def parse(self, user_input, current_question=None, phase=None, **_):
        if not str(user_input).strip():
            return []
        return [{"intent_type": "answer", "extracted_data": {"answer": user_input}}]


class _TTS:
    async def synthesize(
        self, text, voice=None, use_cache=True, billing=None, language=None
    ):
        if not text.strip():
            raise ValueError("Text cannot be empty")
        return b"audio"

    async def synthesize_question(self, question_text, language=None):
        return b"audio"

    async def get_feedback_audio(self, result, variant=None):
        return b"audio"


class _Feedback:
    async def submit_rating(self, **_):
        return True, "Rating saved"

    async def flag_question(self, **_):
        return True, "Question flagged"


class _Usage(Usage):
    """The room fake, plus the read-aloud character budget."""

    async def tts_chars_today(self, subject_id):
        return 0

    async def add_tts_chars(self, subject_id, chars):
        return None


class _World:
    """``app.main.app`` with its state replaced by fakes on the test loop."""

    def __init__(self, db) -> None:
        self.db = db
        retriever = _Retriever()
        sessions = SessionManager()
        analytics = AnalyticsRecorder(None)
        daily = DailyChallengeService(db, retriever)
        FakeStore.packs = {}
        shared = SharedQuizService(FakeStore(db), sessions, retriever, daily, analytics)
        flow = QuizFlowService(
            session_manager=sessions,
            input_parser=_Parser(),
            question_retriever=retriever,
            answer_evaluator=Judge(),
            tts_service=None,
            usage_tracker=_Usage(limit=10**9),  # fuzzing is not a quota test
            translation_service=None,
            analytics=analytics,
            daily_challenge=daily,
            shared_quiz=shared,
        )
        rooms = RoomService(sessions, MemoryRoomStore(), NetTickets(_SECRET), analytics)
        rooms.play = RoomPlay(sessions, rooms.store, flow)
        self.sessions, self.rooms, self.retriever = sessions, rooms, retriever
        self.state = {
            "token_service": TokenService(
                secret=_SECRET,
                issuer="quiz-agent",
                audience="quiz-agent-clients",
                access_ttl_seconds=900,
            ),
            "session_manager": sessions,
            "question_retriever": retriever,
            "voice_transcriber": _Transcriber("Paris"),
            "feedback_service": _Feedback(),
            "tts_service": _TTS(),
            "translation_service": None,
            "usage_tracker": flow.usage_tracker,
            "usage_caps": UsageCaps(None),
            "auth_sessionmaker": db,
            "analytics": analytics,
            "daily_challenge": daily,
            "shared_quiz": shared,
            "rooms": rooms,
            "quiz_flow": flow,
        }
        token = self.state["token_service"].create_access_token(_SUBJECT)
        self.headers = {"Authorization": f"Bearer {token}"}
        self.client = httpx.AsyncClient(
            transport=httpx.ASGITransport(app=main_app, raise_app_exceptions=False),
            base_url="http://t",
        )
        self.share_token = None

    async def live_ids(self, label: str) -> dict[str, str]:
        """A fresh quiz in progress (an idle one for /start), a game together
        whose first question is being answered, and the share."""
        playing = await self.sessions.create_session(user_id=_SUBJECT)
        if not label.endswith("/start"):
            playing.transition(to=SessionPhase.ASKING, caller="fuzz")
            first = self.retriever.pool[0].id
            playing.current_question_id = first
            playing.asked_question_ids = [first]
            await self.sessions.update_session(playing)

        ids = {"session_id": playing.session_id, "token": self.share_token}
        if "{room_id}" in label:
            lobby = await self.sessions.create_session(user_id=_SUBJECT)
            room, _ = await self.rooms.create(lobby.session_id, _SUBJECT, "Fuzz", {})
            started = await self.client.post(
                f"/api/v1/sessions/{lobby.session_id}/start",
                json={},
                headers=self.headers,
            )
            assert started.status_code == 200, started.text
            ids["room_id"] = room.room_id
        return ids

    async def share(self) -> None:
        finished = await self.sessions.create_session(user_id="fuzz-friend")
        finished.asked_question_ids = [q.id for q in self.retriever.pool[:3]]
        finished.phase = SessionPhase.FINISHED
        await self.sessions.update_session(finished)
        token_service = self.state["token_service"]
        resp = await self.client.post(
            "/api/v1/shared-quizzes",
            json={"session_id": finished.session_id},
            headers={
                "Authorization": f"Bearer {token_service.create_access_token('fuzz-friend')}"
            },
        )
        assert resp.status_code == 200, resp.text
        self.share_token = resp.json()["token"]


@pytest.fixture
def _main_app_state(monkeypatch):
    """Borrow ``app.main.app`` for this test only: no lifespan ran, so its
    state is set here and restored after."""
    saved = dict(main_app.state._state)
    monkeypatch.setenv("LEGACY_USER_ID_GRACE", "off")
    monkeypatch.setattr(limiter, "enabled", False)
    # The real LatencyMiddleware records into a process-wide window the ops
    # watch reads; fuzz traffic must not leak into those tests.
    monkeypatch.setattr(ops_watch, "latency", ops_watch.LatencyWindow())
    yield main_app.state
    main_app.state._state.clear()
    main_app.state._state.update(saved)
    app_switches.reset_cache()


def _as_bytes(value) -> bytes:
    return value if isinstance(value, bytes) else str(value).encode()


def _httpx_kwargs(case, headers) -> dict:
    """schemathesis' requests-style kwargs, as httpx wants them."""
    kwargs = case.as_transport_kwargs(base_url="http://t", headers=headers)
    out = {
        "method": kwargs["method"],
        "url": kwargs["url"],
        "headers": kwargs.get("headers"),
        "params": kwargs.get("params"),
        "cookies": kwargs.get("cookies"),
    }
    if "json" in kwargs:
        out["json"] = kwargs["json"]
    if kwargs.get("files") is not None:
        # Generated part bodies may be str or int; httpx sends bytes.
        out["files"] = [
            (name, (part[0], _as_bytes(part[1]), *part[2:]))
            for name, part in kwargs["files"]
        ]
        if isinstance(kwargs.get("data"), dict):
            out["data"] = kwargs["data"]
    elif kwargs.get("data") is not None:
        data = kwargs["data"]
        if isinstance(data, dict):
            out["data"] = data
        else:
            out["content"] = data if isinstance(data, bytes) else str(data).encode()
    return out


async def test_player_endpoints_answer_any_input_without_a_server_error(
    db_sessionmaker, _main_app_state
):
    world = _World(db_sessionmaker)
    for key, value in world.state.items():
        setattr(_main_app_state, key, value)
    app_switches.reset_cache()
    await app_switches.write(db_sessionmaker, {"shared_quiz_enabled": True}, [])
    await world.share()

    schema = schemathesis.openapi.from_dict(main_app.openapi()).include(
        path_regex=_PLAYER_PATHS
    )
    operations = [result.ok() for result in schema.get_all_operations()]
    assert len(operations) > 30  # the filter must not silently match nothing

    loop = asyncio.get_running_loop()
    failures: list[str] = []

    def _run(coro):
        return asyncio.run_coroutine_threadsafe(coro, loop).result(timeout=30)

    def fuzz(operation) -> None:
        @given(case=operation.as_strategy())
        @settings(
            max_examples=_EXAMPLES,
            derandomize=True,
            database=None,
            deadline=None,
            phases=[Phase.explicit, Phase.generate],
            suppress_health_check=list(HealthCheck),
        )
        def one(case) -> None:
            ids = _run(world.live_ids(operation.label))
            for name in ("session_id", "room_id", "token"):
                if case.path_parameters and name in case.path_parameters:
                    case.path_parameters[name] = ids[name]
            response = _run(world.client.request(**_httpx_kwargs(case, world.headers)))
            response.request.read()  # multipart bodies stream; checks read them
            try:
                case.validate_response(
                    response,
                    checks=[not_a_server_error, response_schema_conformance],
                )
            except FailureGroup as e:  # collect all, report once
                if (
                    response.status_code == 422
                    and operation.label in _KNOWN_422_SHAPE
                    and all(type(x).__name__ == "JsonSchemaError" for x in e.exceptions)
                ):
                    return
                kinds = ", ".join(sorted({type(x).__name__ for x in e.exceptions}))
                failures.append(
                    f"{operation.label} -> {response.status_code} ({kinds}): "
                    f"{response.request.method} {response.request.url} "
                    f"{response.text[:200]!r}"
                )

        one()

    try:
        for operation in operations:
            await asyncio.to_thread(fuzz, operation)
    finally:
        await world.client.aclose()

    assert not failures, "\n".join(sorted(set(failures)))
