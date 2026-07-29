"""Serving-path guard for language-bound questions (#128).

"A murder of crows" is a real English collective noun; translated literally into
Slovak it becomes "vražda" (homicide) and the app confidently teaches a fabricated
fact while scoring the true real-world answer as wrong. Retrieval already drops
``language_dependent`` rows for non-English sessions, but a mistagged row — or any
row served through the custom-pack path, which drops that filter by design — still
reaches the player. These tests encode WHY the guard matters: such a serve must be
*visible* in Sentry (mirroring the #107 fail-loud pattern in this subsystem) while
the question is still served, because breaking a quiz mid-session is worse for the
player than a wrong answer nobody is watching for.
"""

import asyncio
from unittest.mock import AsyncMock, patch

import pytest
from app.serializers import question_to_dict_translated
from quiz_shared.models.question import Question


def make_question(*, language_dependent: bool, pack_id: str | None = None) -> Question:
    return Question(
        id="q_crows",
        question="What do you call a group of crows?",
        type="text",
        correct_answer="A murder",
        topic="Language",
        category="kids",
        difficulty="easy",
        language_dependent=language_dependent,
        pack_id=pack_id,
    )


@pytest.fixture
def translation_service():
    service = AsyncMock()
    service.translate_question_payload = AsyncMock(
        return_value={"question": "Ako sa nazýva skupina vrán?"}
    )
    return service


def test_language_dependent_in_slovak_session_reports_to_sentry(translation_service):
    """The whole point of #128: a language-bound row served into a Slovak session
    must raise a Sentry event carrying enough detail (question id, target language,
    category, pack_id) to find and retire the row."""
    question = make_question(language_dependent=True, pack_id="pack-42")

    with patch("app.serializers.sentry_sdk") as mock_sentry:
        result = asyncio.run(
            question_to_dict_translated(
                question, "sk", translation_service, session_id="sess-abc"
            )
        )

    mock_sentry.capture_message.assert_called_once()
    message = mock_sentry.capture_message.call_args[0][0]
    assert "#128" in message
    assert "q_crows" in message
    assert "'sk'" in message
    assert "kids" in message
    assert "pack-42" in message
    assert "sess-abc" in message
    # Pass-through, not refusal: the player still gets the (translated) question.
    assert result["question"] == "Ako sa nazýva skupina vrán?"


def test_flagged_question_is_still_translated_and_served(translation_service):
    """Deliberately NOT a hard refusal — the guard is observational. Translation is
    still attempted exactly as for any other question, so serving never breaks."""
    question = make_question(language_dependent=True)

    with patch("app.serializers.sentry_sdk"):
        result = asyncio.run(
            question_to_dict_translated(question, "sk", translation_service)
        )

    translation_service.translate_question_payload.assert_awaited_once()
    assert result["question"] == "Ako sa nazýva skupina vrán?"
    assert result["id"] == "q_crows"


def test_portable_question_never_reports(translation_service):
    """A guard that fires on ordinary questions would drown the signal — the
    overwhelming majority of served rows are portable."""
    question = make_question(language_dependent=False)

    with patch("app.serializers.sentry_sdk") as mock_sentry:
        asyncio.run(question_to_dict_translated(question, "sk", translation_service))

    mock_sentry.capture_message.assert_not_called()


def test_english_session_never_reports(translation_service):
    """English sessions are exactly where a language_dependent question belongs;
    flagging them would make the signal meaningless."""
    question = make_question(language_dependent=True)

    with patch("app.serializers.sentry_sdk") as mock_sentry:
        result = asyncio.run(
            question_to_dict_translated(question, "en", translation_service)
        )

    mock_sentry.capture_message.assert_not_called()
    translation_service.translate_question_payload.assert_not_awaited()
    assert result["question"] == "What do you call a group of crows?"


def test_reports_even_without_a_translation_service():
    """No translation service means the row is served as raw English into a Slovak
    session — a language-bound fact reaching a non-English player either way, so the
    guard must not hide behind the translation call."""
    question = make_question(language_dependent=True)

    with patch("app.serializers.sentry_sdk") as mock_sentry:
        result = asyncio.run(question_to_dict_translated(question, "sk", None))

    mock_sentry.capture_message.assert_called_once()
    assert result["question"] == "What do you call a group of crows?"
