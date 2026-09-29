"""#189: a submit that arrives after the set ended (TF feedback 2026-09-29).

The answer that ends a set is graded before the player confirms it. On the
founder's drive the last answer finished the session, then "again" on the
confirmation re-recorded — and every re-upload hit the phase guard's plain 400
"Not waiting for input". iOS reads a plain 400 as "didn't catch that", so the
driver was looped through retry prompts; the Skip on the empty sheet then got
the same 400 and landed on the "couldn't submit your answer" error screen.

The contract pinned here, through the real routes and the real flow:
- re-answering the LAST graded question of a finished session is re-graded
  exactly like a re-answer on a live session (#133 1a) — the player's second
  take counts and nothing is charged twice;
- anything else on a finished session (a skip, a submit without or with another
  ``question_id``) is refused with the coded ``session_finished``, which tells
  the client to end the set into its results instead of asking again, and the
  refusal is logged so the next field report shows it;
- a session without ``answer-codes`` (older builds) keeps the plain 400.
"""

from __future__ import annotations

import asyncio
import logging
import os
from typing import Any, List, Optional
from unittest.mock import AsyncMock, MagicMock

os.environ.setdefault("OPENAI_API_KEY", "sk-test")

import pytest  # noqa: E402
import pytest_asyncio  # noqa: E402
from fastapi import FastAPI  # noqa: E402
from httpx import ASGITransport, AsyncClient  # noqa: E402
from slowapi import _rate_limit_exceeded_handler  # noqa: E402
from slowapi.errors import RateLimitExceeded  # noqa: E402

from app.api import deps  # noqa: E402
from app.api.routes import quiz as quiz_routes  # noqa: E402
from app.api.routes import voice as voice_routes  # noqa: E402
from app.auth.identity import AuthSubject  # noqa: E402
from app.evaluation.evaluator import AnswerEvaluator  # noqa: E402
from app.quiz.flow import QuizFlowService  # noqa: E402
from app.rate_limit import limiter  # noqa: E402
from app.voice.transcriber import TranscriptionResult, VoiceTranscriber  # noqa: E402
from quiz_shared.models.participant import Participant  # noqa: E402
from quiz_shared.models.phase import SessionPhase  # noqa: E402
from quiz_shared.models.question import Question  # noqa: E402
from quiz_shared.models.session import QuizSession  # noqa: E402

pytestmark = pytest.mark.asyncio

_SID = "s_189"
_LAST = "q_last"
_SUBJECT = "u_189"
_CODES = ["answer-codes"]


def _last_question() -> Question:
    # MCQ so the real evaluator grades deterministically (no LLM call).
    return Question(
        id=_LAST,
        question="Which planet is the farthest from the Sun?",
        type="text_multichoice",
        possible_answers={"a": "Mars", "b": "Venus", "c": "Neptune", "d": "Saturn"},
        correct_answer="c",
        topic="Space",
        category="science",
        difficulty="easy",
    )


class _Manager:
    """JSON round-trips like the real write-through manager; records writes."""

    def __init__(self, session: QuizSession):
        self.stored = QuizSession.model_validate_json(session.model_dump_json())
        self.writes = 0
        self._lock = asyncio.Lock()

    def get_session(self, session_id: str) -> QuizSession:
        return QuizSession.model_validate_json(self.stored.model_dump_json())

    def update_session(self, session: QuizSession) -> bool:
        self.stored = QuizSession.model_validate_json(session.model_dump_json())
        self.writes += 1
        return True

    def session_lock(self, session_id: str) -> asyncio.Lock:
        return self._lock


class _Transcriber:
    SUPPORTED_FORMATS = VoiceTranscriber.SUPPORTED_FORMATS

    def __init__(self):
        self.text = ""
        self.calls = 0

    def is_supported_format(self, filename) -> bool:
        return True

    async def transcribe_with_quiz_context(self, **kwargs):
        self.calls += 1
        return TranscriptionResult(
            text=self.text,
            language="sk",
            no_speech_prob=0.0,
            avg_logprob=-0.1,
            duration=1.0,
        )


class _Harness:
    """A one-question set on its last question: the first graded answer ends it
    through the real ``max_questions`` path, as on the founder's drive."""

    def __init__(self, capabilities: Optional[List[str]] = None):
        self.manager = _Manager(
            QuizSession(
                session_id=_SID,
                user_id=_SUBJECT,
                phase=SessionPhase.ASKING,
                current_question_id=_LAST,
                asked_question_ids=[_LAST],
                max_questions=1,
                participants=[Participant(participant_id="p1", display_name="Driver")],
                client_capabilities=capabilities or [],
            )
        )

        async def _parse(user_input: str, current_question: str, phase: Any):
            return [{"intent_type": "answer", "extracted_data": {"answer": user_input}}]

        parser = MagicMock()
        parser.parse = AsyncMock(side_effect=_parse)
        retriever = MagicMock()
        retriever.get = AsyncMock(
            side_effect=lambda qid: _last_question() if qid == _LAST else None
        )
        retriever.get_next_question = AsyncMock(return_value=None)
        retriever.pack_is_generating = AsyncMock(return_value=False)
        self.usage = MagicMock()
        self.usage.check_limit = AsyncMock(return_value=(True, 5, None))
        self.usage.record_question = AsyncMock()
        self.flow = QuizFlowService(
            session_manager=self.manager,
            input_parser=parser,
            question_retriever=retriever,
            answer_evaluator=AnswerEvaluator(),
            tts_service=None,
            usage_tracker=self.usage,
            translation_service=None,
        )
        self.transcriber = _Transcriber()

        app = FastAPI()
        app.state.limiter = limiter
        app.add_exception_handler(RateLimitExceeded, _rate_limit_exceeded_handler)
        app.include_router(quiz_routes.router, prefix="/api/v1")
        app.include_router(voice_routes.router, prefix="/api/v1")
        app.dependency_overrides[deps.require_auth_or_grace] = lambda: AuthSubject(
            subject_id=_SUBJECT, is_legacy=False, authenticated=True
        )
        app.dependency_overrides[deps.get_session_manager] = lambda: self.manager
        app.dependency_overrides[deps.get_quiz_flow] = lambda: self.flow
        app.dependency_overrides[deps.get_question_retriever] = lambda: retriever
        app.dependency_overrides[deps.get_voice_transcriber] = lambda: self.transcriber
        self.app = app

    async def text(self, client, answer: str, question_id: Optional[str] = _LAST):
        body = {"input": answer}
        if question_id is not None:
            body["question_id"] = question_id
        return await client.post(f"/api/v1/sessions/{_SID}/input", json=body)

    async def voice(self, client, transcript: str, question_id: Optional[str] = _LAST):
        self.transcriber.text = transcript
        query = "include_audio=false"
        if question_id is not None:
            query += f"&question_id={question_id}"
        return await client.post(
            f"/api/v1/voice/submit/{_SID}?{query}",
            files={"audio": ("answer.wav", b"RIFF", "audio/wav")},
        )

    async def finish_with(self, client, route: str, answer: str):
        """Grade the last question — the set ends on this answer."""
        resp = await getattr(self, route)(client, answer)
        assert resp.status_code == 200
        assert resp.json()["session"]["phase"] == "finished"
        assert resp.json()["current_question"] is None
        return resp


@pytest_asyncio.fixture
async def client_for():
    limiter.reset()
    clients: list[AsyncClient] = []

    async def _make(h: _Harness) -> AsyncClient:
        c = AsyncClient(transport=ASGITransport(app=h.app), base_url="http://test")
        clients.append(c)
        return c

    yield _make
    for c in clients:
        await c.aclose()


SUBMITS = ["voice", "text"]


# ── The re-answer is re-graded ───────────────────────────────────────────────


@pytest.mark.parametrize("route", SUBMITS)
async def test_reanswering_the_last_question_of_a_finished_set_regrades_it(
    client_for, route
):
    """The founder's case: "Neptún" ended the set, "again" re-answered it.

    The second take must be graded against that same question with the first
    verdict's point reversed — the #133 re-grade semantics a live session has —
    and the response must still say the set is over (no next question), so the
    client lands on the results after the confirmation, not on a phantom Q9.
    """
    h = _Harness(capabilities=_CODES)
    client = await client_for(h)
    await h.finish_with(client, route, "Mars")  # wrong first take
    assert h.manager.stored.participants[0].score == 0.0

    resp = await getattr(h, route)(client, "Neptune")

    assert resp.status_code == 200
    body = resp.json()
    assert body["evaluation"]["result"] == "correct"
    assert body["evaluation"]["question_id"] == _LAST
    assert body["session"]["phase"] == "finished"
    assert body["current_question"] is None
    stored = h.manager.stored
    assert stored.phase == SessionPhase.FINISHED
    assert stored.participants[0].score == 1.0
    assert stored.participants[0].answered_count == 1  # replaced, not added
    assert stored.last_evaluation.submitted_text == "Neptune"
    assert stored.last_evaluation.regrade_count == 1
    assert stored.asked_question_ids == [_LAST]  # nothing advanced


async def test_an_identical_retry_on_a_finished_set_replays_the_verdict(client_for):
    """A lost final response retried as-is must replay, not re-evaluate —
    the same free replay a live session gives."""
    h = _Harness(capabilities=_CODES)
    client = await client_for(h)
    first = await h.finish_with(client, "text", "Neptune")
    writes = h.manager.writes

    replay = await h.text(client, "Neptune")

    assert replay.status_code == 200
    assert replay.json()["evaluation"] == first.json()["evaluation"]
    assert replay.json()["message"] == "Answer already processed"
    assert h.manager.writes == writes


# ── Everything else is `session_finished` ────────────────────────────────────


@pytest.mark.parametrize(
    "route,answer,question_id",
    [
        ("text", "skip", _LAST),  # the Skip on the empty no-answer sheet
        ("text", "Neptune", None),  # legacy submit without a question id
        ("text", "Neptune", "q_other"),
        ("voice", "Neptune", None),
        ("voice", "Neptune", "q_other"),
    ],
)
async def test_other_submits_to_a_finished_set_are_session_finished(
    client_for, caplog, route, answer, question_id
):
    """Nothing is left to answer or skip: the client must be told the set is
    over (it ends into the results), nothing may change server-side, no
    transcription may be paid for, and the refusal must show in the logs —
    the field report had only a bare status code to go on."""
    h = _Harness(capabilities=_CODES)
    client = await client_for(h)
    await h.finish_with(client, "text", "Neptune")
    graded = h.manager.stored.last_evaluation
    writes = h.manager.writes

    with caplog.at_level(logging.WARNING, logger="app.api.submit_errors"):
        resp = await getattr(h, route)(client, answer, question_id=question_id)

    assert resp.status_code == 400
    assert resp.json()["detail"]["code"] == "session_finished"
    assert h.manager.writes == writes
    assert h.manager.stored.last_evaluation == graded
    assert h.manager.stored.participants[0].score == 1.0
    assert h.transcriber.calls == 0
    assert _SID in caplog.text and "phase=finished" in caplog.text


async def test_older_builds_keep_the_plain_400(client_for):
    """A session created without `answer-codes` must see exactly today's
    response — a coded detail would be an unknown shape to that build."""
    h = _Harness()
    client = await client_for(h)
    await h.finish_with(client, "text", "Neptune")

    resp = await h.text(client, "skip")

    assert resp.status_code == 400
    assert resp.json()["detail"] == "Not waiting for input"


async def test_a_quiz_that_never_started_is_not_session_finished(client_for):
    """`session_finished` sends the client to the results screen, so it may
    only ever mean "finished" — an idle session keeps the plain refusal."""
    h = _Harness(capabilities=_CODES)
    h.manager.stored.phase = SessionPhase.IDLE
    client = await client_for(h)

    resp = await h.text(client, "Neptune")

    assert resp.status_code == 400
    assert resp.json()["detail"] == "Not waiting for input"
