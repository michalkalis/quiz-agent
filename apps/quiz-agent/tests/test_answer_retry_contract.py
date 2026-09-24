"""#185: the "say it again" contract — opt-in, and invisible to shipped builds.

Founder decisions 2026-09-24: an MCQ answer the server cannot map to an option
is *unmatched*, not incorrect, and the new iOS build handles it exactly like an
empty answer (re-prompt + one automatic retry). The TestFlight build already in
the founder's hands must keep today's behaviour — it decodes an unknown verdict
as "Answer recorded" and would advance past a question the player never
answered.

So the new behaviour is keyed to ``X-Client-Capabilities: answer-codes``, sent
at session creation. These tests pin both sides through the real flow and real
routes:
- legacy session → an unmatched MCQ answer is graded "incorrect" (200), and the
  "say it again" 400s keep their plain-string detail;
- answer-codes session → 400 ``{"code": "mcq_unmatched" | "no_speech" |
  "no_answer", …}``, and NOTHING is graded, scored, recorded or charged, so the
  retry is a fresh first submission (or leaves an earlier verdict intact).

Plus the #185 G server fixes both builds get: a one-character "C" is an answer,
not an empty transcript and not a skip.
"""

from __future__ import annotations

import asyncio
import os
from typing import Any, Dict, List, Optional
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
from app.client_capabilities import parse_capabilities  # noqa: E402
from app.evaluation.evaluator import AnswerEvaluator  # noqa: E402
from app.quiz.flow import QuizFlowService  # noqa: E402
from app.rate_limit import limiter  # noqa: E402
from app.tts.spoken_text import spoken_question_text  # noqa: E402
from app.voice.transcriber import TranscriptionResult, VoiceTranscriber  # noqa: E402
from quiz_shared.models.participant import Participant  # noqa: E402
from quiz_shared.models.phase import SessionPhase  # noqa: E402
from quiz_shared.models.question import Question  # noqa: E402
from quiz_shared.models.session import QuizSession  # noqa: E402

pytestmark = pytest.mark.asyncio

_SID = "s_185"
_Q1 = "q_mcq"
_Q2 = "q_next"
_SUBJECT = "u_185"
_OPTIONS = {"a": "Mars", "b": "Venus", "c": "Jupiter", "d": "Saturn"}
_CODES = ["answer-codes"]


def _mcq(qid: str = _Q1) -> Question:
    return Question(
        id=qid,
        question="Which is the largest planet?",
        type="text_multichoice",
        possible_answers=dict(_OPTIONS),
        correct_answer="c",
        topic="Space",
        category="science",
        difficulty="easy",
    )


def _open(qid: str = _Q1) -> Question:
    return Question(
        id=qid,
        question="Which winter sport uses stones and brooms?",
        type="text",
        correct_answer="curling",
        topic="Sport",
        category="sport",
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


def _session(capabilities: Optional[List[str]] = None) -> QuizSession:
    return QuizSession(
        session_id=_SID,
        user_id=_SUBJECT,
        phase=SessionPhase.ASKING,
        current_question_id=_Q1,
        asked_question_ids=[_Q1],
        max_questions=10,
        participants=[Participant(participant_id="p1", display_name="Driver")],
        client_capabilities=capabilities or [],
    )


class _Transcriber:
    SUPPORTED_FORMATS = VoiceTranscriber.SUPPORTED_FORMATS

    def __init__(self, text: str):
        self.text = text

    def is_supported_format(self, filename) -> bool:
        return True

    async def transcribe_with_quiz_context(self, **kwargs):
        return TranscriptionResult(
            text=self.text,
            language="en",
            no_speech_prob=0.0,
            avg_logprob=-0.1,
            duration=1.0,
        )


class _Harness:
    def __init__(self, question: Question, capabilities=None, transcript: str = ""):
        self.manager = _Manager(_session(capabilities))
        questions = {_Q1: question, _Q2: _mcq(_Q2)}

        async def _parse(user_input: str, current_question: str, phase: Any):
            if user_input.strip() in ("", "hmm what"):
                return []  # speech, but no answer in it
            return [{"intent_type": "answer", "extracted_data": {"answer": user_input}}]

        self.parser = MagicMock()
        self.parser.parse = AsyncMock(side_effect=_parse)
        self.retriever = MagicMock()
        self.retriever.get = AsyncMock(side_effect=lambda qid: questions.get(qid))
        self.retriever.get_next_question = AsyncMock(return_value=questions[_Q2])
        self.retriever.pack_is_generating = AsyncMock(return_value=False)
        self.usage = MagicMock()
        self.usage.check_limit = AsyncMock(return_value=(True, 5, None))
        self.usage.record_question = AsyncMock()
        self.flow = QuizFlowService(
            session_manager=self.manager,
            input_parser=self.parser,
            question_retriever=self.retriever,
            answer_evaluator=AnswerEvaluator(),  # real: MCQ grading is deterministic
            tts_service=None,
            usage_tracker=self.usage,
            translation_service=None,
        )
        self.transcriber = _Transcriber(transcript)

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
        app.dependency_overrides[deps.get_question_retriever] = lambda: self.retriever
        app.dependency_overrides[deps.get_voice_transcriber] = lambda: self.transcriber
        self.app = app

    async def text(self, client, answer: str, question_id: str = _Q1):
        return await client.post(
            f"/api/v1/sessions/{_SID}/input",
            json={"input": answer, "question_id": question_id},
        )

    async def voice(self, client, transcript: str, question_id: str = _Q1):
        self.transcriber.text = transcript
        return await client.post(
            f"/api/v1/voice/submit/{_SID}?question_id={question_id}&include_audio=false",
            files={"audio": ("answer.wav", b"RIFF", "audio/wav")},
        )


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


def _assert_untouched(h: _Harness):
    """Nothing graded, scored, recorded, advanced or charged."""
    s = h.manager.stored
    assert s.current_question_id == _Q1
    assert s.asked_question_ids == [_Q1]
    assert s.last_evaluation is None
    assert s.participants[0].score == 0.0
    assert s.participants[0].answered_count == 0
    h.usage.record_question.assert_not_awaited()


SUBMITS = ["text", "voice"]


# ── Unmatched MCQ answers ────────────────────────────────────────────────────


@pytest.mark.parametrize("route", SUBMITS)
async def test_legacy_build_still_gets_incorrect_for_an_unmatched_mcq(
    client_for, route
):
    """Today's TestFlight build knows no "unmatched" verdict — it must keep
    receiving the graded "incorrect" it always got."""
    h = _Harness(_mcq())
    client = await client_for(h)

    resp = await getattr(h, route)(client, "xyz")

    assert resp.status_code == 200
    assert resp.json()["evaluation"]["result"] == "incorrect"
    assert h.manager.stored.current_question_id == _Q2


@pytest.mark.parametrize("route", SUBMITS)
async def test_answer_codes_build_is_asked_again_and_nothing_is_graded(
    client_for, route
):
    """Founder: unknown → unmatched, never incorrect. The client re-asks, so the
    server must leave the question open — no verdict, no point, no quota."""
    h = _Harness(_mcq(), capabilities=_CODES)
    client = await client_for(h)

    resp = await getattr(h, route)(client, "xyz")

    assert resp.status_code == 400
    detail = resp.json()["detail"]
    assert detail["code"] == "mcq_unmatched"
    assert detail["heard"] == "xyz"
    assert detail["message"]
    _assert_untouched(h)


async def test_the_retry_after_unmatched_grades_as_a_first_answer(client_for):
    h = _Harness(_mcq(), capabilities=_CODES)
    client = await client_for(h)

    assert (await h.voice(client, "xyz")).status_code == 400
    resp = await h.voice(client, "céčko")

    assert resp.status_code == 200
    assert resp.json()["evaluation"]["result"] == "correct"
    assert h.manager.stored.participants[0].score == 1.0
    h.usage.record_question.assert_awaited_once()


async def test_unmatched_re_record_keeps_the_verdict_already_given(client_for):
    """A re-record on the confirmation sheet re-grades the same question (#133).
    If the new take names no option, the answer the player already gave stands —
    it must not be replaced by nothing."""
    h = _Harness(_mcq(), capabilities=_CODES)
    client = await client_for(h)
    assert (await h.voice(client, "tretia")).json()["evaluation"]["result"] == "correct"
    graded = h.manager.stored.last_evaluation

    resp = await h.voice(client, "b alebo c", question_id=_Q1)

    assert resp.status_code == 400
    assert resp.json()["detail"]["code"] == "mcq_unmatched"
    assert h.manager.stored.last_evaluation == graded
    assert h.manager.stored.participants[0].score == 1.0


# ── One-character MCQ answers ────────────────────────────────────────────────


@pytest.mark.parametrize("capabilities", [None, _CODES], ids=["legacy", "codes"])
async def test_a_spoken_letter_is_an_answer_not_an_empty_transcript(
    client_for, capabilities
):
    """The car-test "C": rejected as empty (< 2 chars), and past that the parser
    would have turned it into a skip. Both builds get the server fix."""
    h = _Harness(_mcq(), capabilities=capabilities)
    client = await client_for(h)

    resp = await h.voice(client, "C")

    assert resp.status_code == 200
    assert resp.json()["evaluation"]["result"] == "correct"
    h.parser.parse.assert_not_awaited()  # deterministic: no LLM classifier


async def test_a_single_character_that_names_no_option_is_still_no_speech(client_for):
    h = _Harness(_mcq(), capabilities=_CODES)
    client = await client_for(h)

    resp = await h.voice(client, "x")

    assert resp.status_code == 400
    assert resp.json()["detail"]["code"] == "no_speech"
    _assert_untouched(h)


async def test_open_questions_keep_the_two_character_floor(client_for):
    h = _Harness(_open())
    client = await client_for(h)

    resp = await h.voice(client, "C")

    assert resp.status_code == 400
    assert resp.json()["detail"] == (
        "No clear speech detected. Please speak clearly and try again."
    )


# ── Coded "say it again" 400s ────────────────────────────────────────────────


@pytest.mark.parametrize("route", SUBMITS)
async def test_no_answer_is_coded_only_for_answer_codes_builds(client_for, route):
    legacy = _Harness(_open())
    coded = _Harness(_open(), capabilities=_CODES)

    legacy_resp = await getattr(legacy, route)(await client_for(legacy), "hmm what")
    coded_resp = await getattr(coded, route)(await client_for(coded), "hmm what")

    assert legacy_resp.status_code == coded_resp.status_code == 400
    assert isinstance(legacy_resp.json()["detail"], str)
    assert coded_resp.json()["detail"]["code"] == "no_answer"
    _assert_untouched(coded)


async def test_no_speech_is_coded_only_for_answer_codes_builds(client_for):
    legacy = _Harness(_mcq())
    coded = _Harness(_mcq(), capabilities=_CODES)

    legacy_resp = await legacy.voice(await client_for(legacy), "")
    coded_resp = await coded.voice(await client_for(coded), "")

    assert legacy_resp.json()["detail"] == (
        "No clear speech detected. Please speak clearly and try again."
    )
    assert coded_resp.json()["detail"] == {
        "code": "no_speech",
        "message": "No clear speech detected. Please speak clearly and try again.",
    }


# ── Declaring the capabilities ───────────────────────────────────────────────


def test_capabilities_header_is_whitelisted():
    """Only known tokens land on the session; garbage never widens behaviour."""
    assert parse_capabilities(None) == []
    assert parse_capabilities("") == []
    assert parse_capabilities(" Answer-Codes , option-labels,rm -rf") == [
        "answer-codes",
        "option-labels",
    ]


async def test_session_create_stores_the_declared_capabilities(monkeypatch):
    from app import rate_limit
    from app.api.deps import CreateSessionRequest
    from app.api.routes.sessions import create_session
    from app.session.manager import SessionManager

    monkeypatch.setattr(rate_limit.limiter, "enabled", False)

    async def _subject(request, user_id, token_service, sessionmaker):
        return AuthSubject(subject_id="anon", is_legacy=True, authenticated=False)

    monkeypatch.setattr("app.api.routes.sessions.resolve_session_subject", _subject)

    class _Req:
        class url:
            path = "/api/v1/sessions"

        def __init__(self, headers):
            self.headers = headers

    manager = SessionManager()

    async def _create(headers: Dict[str, str]) -> QuizSession:
        resp = await create_session(
            request=_Req(headers),
            body=CreateSessionRequest(),
            session_manager=manager,
            token_service=None,
            auth_sessionmaker=None,
        )
        return manager.get_session(resp.session_id)

    assert (await _create({})).client_capabilities == []
    declared = await _create({"X-Client-Capabilities": "answer-codes, option-labels"})
    assert declared.client_capabilities == ["answer-codes", "option-labels"]


# ── Spoken option labels ─────────────────────────────────────────────────────


def test_question_audio_keeps_the_keys_for_builds_before_option_labels():
    """Today's build shows the key letters, so its audio must keep saying them
    (and keep its TTS cache key)."""
    stem = "Which is the largest planet?"
    legacy = _session()

    assert spoken_question_text(stem, _OPTIONS, legacy) == (
        f"{stem} a: Mars. b: Venus. c: Jupiter. d: Saturn."
    )
    assert spoken_question_text(stem, _OPTIONS) == spoken_question_text(
        stem, _OPTIONS, legacy
    )


@pytest.mark.parametrize(
    "language,spoken",
    [
        ("sk", "Jedna: Mars. Dva: Venus. Tri: Jupiter. Štyri: Saturn."),
        ("cs", "Jedna: Mars. Dva: Venus. Tři: Jupiter. Čtyři: Saturn."),
        ("en", "One: Mars. Two: Venus. Three: Jupiter. Four: Saturn."),
    ],
)
def test_question_audio_reads_numbered_labels_in_the_counting_form(language, spoken):
    """Founder 2026-09-24: the new build shows 1–4 and its audio counts them
    out in the session language ("Jedna: Paríž. Dva: Londýn.") — digits would
    be normalised to "jeden" in Slovak, the wrong form for counting options."""
    stem = "Which is the largest planet?"
    session = _session(["option-labels"])
    session.language = language

    assert spoken_question_text(stem, _OPTIONS, session) == f"{stem} {spoken}"


@pytest.mark.parametrize("language", ["sk", "cs", "en"])
def test_letter_labels_stay_letters_when_the_options_are_numbers(language):
    stem = "When did Apollo 11 land?"
    session = _session(["option-labels"])
    session.language = language

    assert spoken_question_text(stem, {"a": "1969", "b": "1970"}, session) == (
        f"{stem} A: 1969. B: 1970."
    )
