"""#236 — a family round („S deťmi“) picked in full at /start, in real SQL.

The round is drawn from the shared library by band + topic + language + the
build's review statuses, then played as a fixed list. These tests pin what
the pool may hold (``band_pool_ids``), that the topic list counts the very
same pool (``band_topic_counts``), and that the whole start → play path
serves only native questions of that band and topic, never translated (the
child checks ran on the text in the language it was written in). The
ordinary-quiz side of the isolation is in ``test_age_band_isolation.py``.
"""

from __future__ import annotations

import uuid
from datetime import timedelta
from types import SimpleNamespace
from unittest.mock import MagicMock

import pytest
from app import app_switches
from app.api.deps import StartQuizRequest
from app.api.routes.family import family_topics
from app.api.routes.quiz import start_quiz
from app.auth.identity import AuthSubject
from app.family import rounds
from app.retrieval.question_retriever import QuestionRetriever
from app.session.manager import SessionManager
from quiz_shared.database.pgvector_client import EMBEDDING_DIM
from quiz_shared.models.session import QuizSession

from tests.db.test_question_stock_counts import NOW, _question, store  # noqa: F401

pytestmark = pytest.mark.asyncio

BAND, TOPIC = "kids_4_6", "family-dinosaurs"


def _stub_embedder(_text: str) -> list[float]:
    return [1.0] + [0.0] * (EMBEDDING_DIM - 1)


def _band_row(**overrides):
    fields = {"age_band": BAND, "language": "sk", "category": TOPIC}
    fields.update(overrides)
    return _question(**fields)


async def _library(store):  # noqa: F811
    """Six playable target rows, and one near miss per filter the pool keeps."""
    target = [_band_row() for _ in range(6)]
    misses = {
        "other_topic": _band_row(category="family-your-body"),
        "other_band": _band_row(age_band="kids_7_9"),
        "english": _band_row(language="en"),
        "legacy_language": _band_row(language=None),
        "ordinary_same_category": _question(category=TOPIC, language="sk"),
        "pending": _band_row(review_status="pending_review"),
        "pack": _band_row(pack_id=str(uuid.uuid4())),
        "image": _band_row(type="image"),
        "expired": _band_row(expires_at=NOW - timedelta(days=1)),
    }
    for q in [*target, *misses.values()]:
        assert await store.upsert(q) is True
    return {q.id for q in target}, {name: q.id for name, q in misses.items()}


def _session(**overrides) -> QuizSession:
    fields = {
        "session_id": "s",
        "language": "sk",
        "age_band": BAND,
        "preferred_categories": [TOPIC],
        "current_difficulty": "random",
    }
    fields.update(overrides)
    return QuizSession(**fields)


async def test_the_pool_is_exactly_band_topic_language_and_channel(store):  # noqa: F811
    target, misses = await _library(store)
    retriever = QuestionRetriever(question_store=store)

    app_store = set(await retriever.band_pool_ids(_session()))
    testflight = set(
        await retriever.band_pool_ids(_session(build_channel="testflight"))
    )

    assert app_store == target
    # TestFlight also field-tests pending_review rows, nothing else widens.
    assert testflight == target | {misses["pending"]}


async def test_the_topic_list_counts_the_same_pool(store):  # noqa: F811
    target, _ = await _library(store)
    retriever = QuestionRetriever(question_store=store)

    counts = await retriever.band_topic_counts("sk", None)

    assert counts[(BAND, TOPIC)] == len(target)
    assert counts[("kids_7_9", TOPIC)] == 1
    assert counts[(BAND, "family-your-body")] == 1
    # Ordinary rows are never a family topic, whatever their category says.
    assert all(band is not None for band, _ in counts)


async def test_topics_show_only_a_topic_with_a_whole_round(store, monkeypatch):  # noqa: F811
    await _library(store)
    rounds.reset_cache()
    app_switches.reset_cache()

    async def _on(_sessionmaker):
        return {"family_mode_enabled": "true", "family_mode_enabled_app_store": "true"}

    monkeypatch.setattr(app_switches, "cached_overrides", _on)
    request = SimpleNamespace(headers={})
    retriever = QuestionRetriever(question_store=store)

    sk = await family_topics(request, "sk", retriever, None)
    en = await family_topics(request, "en", retriever, None)
    rounds.reset_cache()

    shown = {b.band: [t.key for t in b.topics] for b in sk.bands}
    # Six dinosaur rows = one 4-6 round; one 7-9 row is no 10-question round.
    assert shown == {BAND: [TOPIC], "kids_7_9": [], "kids_10_12": []}
    assert sk.bands[0].topics[0].name == "Dinosaury"
    assert sk.bands[0].topics[0].round_size == 6
    assert all(not b.topics for b in en.bands)  # one English row only


async def test_an_ordinary_session_asking_for_a_family_topic_gets_no_band_row(
    store,  # noqa: F811
):
    """An old or tampered build sending a family key as a plain category stays
    an ordinary quiz: only the unbanded row of that category reaches it."""
    _, misses = await _library(store)
    retriever = QuestionRetriever(question_store=store.with_embedder(_stub_embedder))
    session = _session(age_band=None)

    first = await retriever.get_next_question(session)
    session.asked_question_ids.append(first.id)

    assert first.id == misses["ordinary_same_category"]
    assert await retriever.get_next_question(session) is None


async def test_a_started_round_plays_only_its_native_band_questions(
    store,  # noqa: F811
    monkeypatch,
):
    target, misses = await _library(store)

    async def _never(*_args, **_kwargs):
        raise AssertionError("a band question must never be translated")

    monkeypatch.setattr("app.serializers.build_question_translation", _never)
    monkeypatch.setattr("app.serializers.stored_translation_record", _never)
    monkeypatch.setattr("app.rate_limit.limiter.enabled", False)
    retriever = QuestionRetriever(question_store=store.with_embedder(_stub_embedder))
    manager = SessionManager()
    session = await manager.create_session(user_id="u1", max_questions=6)
    for key, value in _session(session_id=session.session_id).model_dump().items():
        if key in ("language", "age_band", "preferred_categories", "category"):
            setattr(session, key, value)
    await manager.update_session(session)

    started = await start_quiz(
        request=SimpleNamespace(headers={}, url=SimpleNamespace(path="/start")),
        session_id=session.session_id,
        body=StartQuizRequest(excluded_question_ids=[]),
        session_manager=manager,
        question_retriever=retriever,
        usage_tracker=None,
        translation_service=MagicMock(),
        tts_service=MagicMock(),
        audio=False,
        subject=AuthSubject(subject_id="u1", is_legacy=False, authenticated=True),
    )
    stored = await manager.get_session(session.session_id)
    served = [started.current_question.id]
    while (q := await retriever.get_next_question(_played(stored, served))) is not None:
        served.append(q.id)

    assert started.repeats is False
    assert set(served) == target and len(served) == 6
    assert stored.current_question_translation is None
    assert misses["english"] not in served


def _played(session: QuizSession, served: list[str]) -> QuizSession:
    session.asked_question_ids = list(served)
    return session
