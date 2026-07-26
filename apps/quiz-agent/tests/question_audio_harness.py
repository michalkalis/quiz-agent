"""Drive the real question-audio pair: POST /sessions/{id}/start → GET .../question/audio.

Shared by every test that pins what a driver actually hears. They go through
both real call sites on purpose: the spoken string is assembled once where the
question is chosen and cached on the session, so a test that hand-writes the
session state would pin a shape production never builds — and would keep
passing while the two sites drifted apart.
"""

import asyncio
from typing import ClassVar
from unittest.mock import MagicMock

from app.api.deps import StartQuizRequest
from app.api.routes.quiz import start_quiz
from app.api.routes.tts import get_question_audio
from app.session.manager import SessionManager
from quiz_shared.models.question import Question


class _Url:
    path = "/api/v1/sessions/x/question/audio"


class Req:
    """Minimal stand-in for the Request the rate limiter inspects."""

    url = _Url()
    headers: ClassVar[dict] = {}


class RecordingTTS:
    """Captures the texts handed to synthesis, in call order."""

    def __init__(self) -> None:
        self.texts: list[str] = []
        self.called = asyncio.Event()

    async def synthesize_question(self, question_text: str) -> bytes:
        self.texts.append(question_text)
        self.called.set()
        return b"audio"


def retriever_for(question: Question) -> MagicMock:
    """Question store that serves ``question`` to both read paths."""
    retriever = MagicMock()
    retriever.get_next_question.return_value = question
    retriever.get.return_value = question
    return retriever


async def start_quiz_for(
    question: Question,
    language: str = "en",
    *,
    tts_service: RecordingTTS | None = None,
    audio: bool = False,
) -> tuple[SessionManager, str, MagicMock]:
    """Run the real /start — the site that assembles and caches the spoken text."""
    manager = SessionManager()
    session = manager.create_session()
    session.language = language
    manager.update_session(session)

    retriever = retriever_for(question)
    await start_quiz(
        request=Req(),
        session_id=session.session_id,
        body=StartQuizRequest(),
        session_manager=manager,
        question_retriever=retriever,
        usage_tracker=None,
        translation_service=None,
        tts_service=tts_service,
        audio=audio,
    )
    return manager, session.session_id, retriever


async def question_audio(
    manager: SessionManager,
    session_id: str,
    retriever: MagicMock,
    tts: RecordingTTS,
) -> str:
    """Run the real /question/audio, return the text it sent to synthesis."""
    await get_question_audio(
        request=Req(),
        session_id=session_id,
        session_manager=manager,
        tts_service=tts,
        question_retriever=retriever,
        translation_service=None,
        _auth=None,
    )

    assert tts.texts, "the route must synthesize question audio"
    return tts.texts[-1]
