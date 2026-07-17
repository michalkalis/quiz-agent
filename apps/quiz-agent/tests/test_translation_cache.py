"""Tests for the process-lifetime translation cache (#69).

A fresh gpt-4o-mini call per question/feedback made SK sessions ~3.5× the cost of EN
(#49). TranslationService is a process-wide singleton, so caching validated translations
for the process lifetime removes almost all of the repeat cost. These tests encode WHY the
cache matters: a repeat is one LLM call (cost), the cache lives on the singleton (persistence),
the `kind` discriminator stops cross-method collisions, fallbacks/short-circuits are never
cached (correctness), and memory stays bounded at the cap (safety).
"""

import asyncio
import os
import sys
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

# Add shared package to path
sys.path.insert(
    0, os.path.join(os.path.dirname(__file__), "../../../..", "packages/shared")
)

from app.translation import translator as translator_module
from app.translation.store import TranslationStore
from app.translation.translator import TRANSLATION_PROMPT_VERSION, TranslationService


def make_service(store_url: str) -> TranslationService:
    """Create a TranslationService with a dummy API key and an explicit store URL."""
    with patch.dict(os.environ, {"OPENAI_API_KEY": "sk-test-dummy"}):
        return TranslationService(store_url=store_url)


@pytest.fixture
def store_url(tmp_path):
    """Per-test on-disk store URL — tests must never touch ./data."""
    return f"sqlite:///{tmp_path}/translations.db"


@pytest.fixture
def service(store_url):
    """Create a TranslationService isolated on a tmp_path store."""
    return make_service(store_url)


def mock_response(content: str):
    """Build a mock OpenAI chat completion response carrying `content`."""
    mock_message = MagicMock()
    mock_message.content = content
    mock_choice = MagicMock()
    mock_choice.message = mock_message
    mock_response = MagicMock()
    mock_response.choices = [mock_choice]
    return mock_response


# A question + its valid Slovak translation that passes _validate_translation
# (>= 15 chars, length ratio >= 0.3).
QUESTION = "What is the capital city of France?"
QUESTION_SK = "Aké je hlavné mesto Francúzska dnes?"


def test_repeat_question_one_llm_call(service):
    """Repeat = one LLM call, and it persists on the singleton (no new instance built).

    The second identical call must be a cache hit — that is the entire cost win.
    """
    service.client.chat.completions.create = AsyncMock(
        return_value=mock_response(QUESTION_SK)
    )

    first = asyncio.run(service.translate_question(QUESTION, "sk"))
    second = asyncio.run(service.translate_question(QUESTION, "sk"))

    assert service.client.chat.completions.create.call_count == 1
    assert first == second == QUESTION_SK


def test_repeat_feedback_one_llm_call(service):
    """Repeat feedback = one LLM call on the same singleton instance."""
    feedback = "Correct! Well done."
    feedback_sk = "Správne! Výborne."
    service.client.chat.completions.create = AsyncMock(
        return_value=mock_response(feedback_sk)
    )

    first = asyncio.run(service.translate_feedback(feedback, "sk"))
    second = asyncio.run(service.translate_feedback(feedback, "sk"))

    assert service.client.chat.completions.create.call_count == 1
    assert first == second == feedback_sk


def test_both_methods_cached_kind_isolates(service):
    """Same text through both methods stays independent — `kind` prevents collision.

    The two methods use different prompts, so identical text must NOT share a cache entry.
    """
    service.client.chat.completions.create = AsyncMock(
        return_value=mock_response(QUESTION_SK)
    )

    # Same text T to both methods → two independent misses (kind discriminator).
    asyncio.run(service.translate_question(QUESTION, "sk"))
    asyncio.run(service.translate_feedback(QUESTION, "sk"))
    assert service.client.chat.completions.create.call_count == 2

    # Repeating both → both now hits, no further LLM calls.
    asyncio.run(service.translate_question(QUESTION, "sk"))
    asyncio.run(service.translate_feedback(QUESTION, "sk"))
    assert service.client.chat.completions.create.call_count == 2


def test_error_retries_within_call(service):
    """A transient error must retry in-call — the user never sees English mid-session
    for a one-off API hiccup (founder bug 2026-07-11)."""
    service.client.chat.completions.create = AsyncMock(
        side_effect=[Exception("rate limit"), mock_response(QUESTION_SK)]
    )

    first = asyncio.run(service.translate_question(QUESTION, "sk"))

    assert first == QUESTION_SK  # retry recovered within the same call
    assert service.client.chat.completions.create.call_count == 2


def test_exhausted_retries_fall_back_uncached(service):
    """When every attempt (now TRANSLATION_MAX_ATTEMPTS=3, #107) fails, fall back to
    English but do NOT cache it — a later call must recompute and can still succeed."""
    service.client.chat.completions.create = AsyncMock(
        side_effect=[
            Exception("rate limit"),
            Exception("rate limit"),
            Exception("rate limit"),
            mock_response(QUESTION_SK),
        ]
    )

    first = asyncio.run(service.translate_question(QUESTION, "sk"))
    second = asyncio.run(service.translate_question(QUESTION, "sk"))

    assert first == QUESTION  # all 3 attempts failed → original (not cached)
    assert second == QUESTION_SK  # later success recomputed
    assert service.client.chat.completions.create.call_count == 4


def test_validation_fail_retries_within_call(service):
    """A validation-rejected completion must retry in-call, not leak English."""
    service.client.chat.completions.create = AsyncMock(
        side_effect=[mock_response("suchy bodliak"), mock_response(QUESTION_SK)]
    )

    first = asyncio.run(service.translate_question(QUESTION, "sk"))

    assert first == QUESTION_SK  # garbage rejected, retry succeeded
    assert service.client.chat.completions.create.call_count == 2


def test_feedback_error_then_success_recomputes(service):
    """translate_feedback's only non-success path (except → original) is likewise never cached."""
    feedback = "Correct! Well done."
    feedback_sk = "Správne! Výborne."
    service.client.chat.completions.create = AsyncMock(
        side_effect=[Exception("boom"), mock_response(feedback_sk)]
    )

    first = asyncio.run(service.translate_feedback(feedback, "sk"))
    second = asyncio.run(service.translate_feedback(feedback, "sk"))

    assert first == feedback  # error fell back to original (not cached)
    assert second == feedback_sk
    assert service.client.chat.completions.create.call_count == 2


def test_noop_shortcircuit_untouched(service):
    """No-op passthroughs (source==target / target=='en') never hit the LLM or the cache."""
    service.client.chat.completions.create = AsyncMock(
        return_value=mock_response(QUESTION_SK)
    )

    q = asyncio.run(service.translate_question(QUESTION, "en", "en"))
    f = asyncio.run(service.translate_feedback("Correct!", "en"))

    assert q == QUESTION
    assert f == "Correct!"
    assert service.client.chat.completions.create.call_count == 0
    assert service._cache == {}


def test_cache_bounded_at_cap(service, monkeypatch):
    """Memory is bounded: once the cap is reached, new keys stop being inserted.

    Patch the module-global cap to a small N AFTER the service is built (proving the guard
    reads it at call-time), then translate more than N distinct texts with valid responses.
    The guard must stop storing at the cap while still translating every miss.
    """
    N = 3
    monkeypatch.setattr(translator_module, "CACHE_MAX_ENTRIES", N)

    # A translation long enough that every distinct original validates (ratio >= 0.3).
    valid_sk = "Toto je platný preložený text otázky pre účely tohto testu."
    service.client.chat.completions.create = AsyncMock(
        return_value=mock_response(valid_sk)
    )

    distinct = N + 2
    for i in range(distinct):
        asyncio.run(
            service.translate_question(f"What is interesting fact number {i}?", "sk")
        )

    # Every miss was translated (guard limits storage, not translation)...
    assert service.client.chat.completions.create.call_count == distinct
    # ...but the cache is capped at N.
    assert len(service._cache) == N


# --- Durable store (#69 follow-up): survives restarts, version-stamp refresh lever ---


def disk_rows(tmp_path):
    """Read the on-disk table via stdlib sqlite3, independent of the store class."""
    import sqlite3

    with sqlite3.connect(tmp_path / "translations.db") as conn:
        return conn.execute(
            "SELECT kind, source_text, target_language, version, translated_text"
            " FROM translations"
        ).fetchall()


def test_durable_across_instances(service, store_url):
    """The core durability proof: a second instance at the same path serves from disk.

    This is exactly the restart/redeploy scenario — the cost win must survive the process.
    """
    service.client.chat.completions.create = AsyncMock(
        return_value=mock_response(QUESTION_SK)
    )
    asyncio.run(service.translate_question(QUESTION, "sk"))
    assert service.client.chat.completions.create.call_count == 1

    second = make_service(store_url)
    second.client.chat.completions.create = AsyncMock(
        return_value=mock_response("SHOULD NOT BE CALLED")
    )
    result = asyncio.run(second.translate_question(QUESTION, "sk"))

    assert second.client.chat.completions.create.call_count == 0
    assert result == QUESTION_SK


def test_warm_load_serves_from_disk(store_url):
    """Pre-seeded disk rows are warm-loaded into memory before any call."""
    TranslationStore(store_url).upsert(
        "question", QUESTION, "sk", TRANSLATION_PROMPT_VERSION, QUESTION_SK
    )

    service = make_service(store_url)
    service.client.chat.completions.create = AsyncMock(
        return_value=mock_response("SHOULD NOT BE CALLED")
    )

    assert service._cache  # warm-loaded before any call
    result = asyncio.run(service.translate_question(QUESTION, "sk"))
    assert result == QUESTION_SK
    assert service.client.chat.completions.create.call_count == 0


def test_version_bump_forces_retranslate(service, store_url, tmp_path, monkeypatch):
    """Bumping TRANSLATION_PROMPT_VERSION is the manual refresh lever: old rows are
    orphaned (never served), unchanged text lazily re-translates under the new version."""
    service.client.chat.completions.create = AsyncMock(
        return_value=mock_response(QUESTION_SK)
    )
    asyncio.run(service.translate_question(QUESTION, "sk"))

    monkeypatch.setattr(translator_module, "TRANSLATION_PROMPT_VERSION", "2")
    fresh = make_service(store_url)
    fresh.client.chat.completions.create = AsyncMock(
        return_value=mock_response(QUESTION_SK)
    )

    assert ("question", QUESTION, "sk") not in fresh._cache
    asyncio.run(fresh.translate_question(QUESTION, "sk"))
    assert fresh.client.chat.completions.create.call_count == 1

    versions = sorted(row[3] for row in disk_rows(tmp_path))
    assert versions == ["1", "2"]  # old row orphaned on disk, new row written


def test_question_fallbacks_not_persisted_to_disk(service, tmp_path):
    """Neither the except-fallback nor the validation-fail fallback may poison the disk.

    First call exhausts all 3 attempts (an exception, then a validation-rejected
    completion, then another exception) and must not write a row; the second call's
    fresh success is the only row on disk.
    """
    service.client.chat.completions.create = AsyncMock(
        side_effect=[
            Exception("rate limit"),
            mock_response("suchy bodliak"),
            Exception("rate limit"),
            mock_response(QUESTION_SK),
        ]
    )

    for _ in range(3):
        asyncio.run(service.translate_question(QUESTION, "sk"))

    rows = disk_rows(tmp_path)
    assert len(rows) == 1
    assert rows[0][4] == QUESTION_SK


def test_feedback_fallback_not_persisted_to_disk(service, tmp_path):
    """translate_feedback's except-fallback likewise never reaches disk."""
    feedback = "Correct! Well done."
    feedback_sk = "Správne! Výborne."
    service.client.chat.completions.create = AsyncMock(
        side_effect=[Exception("boom"), mock_response(feedback_sk)]
    )

    asyncio.run(service.translate_feedback(feedback, "sk"))
    asyncio.run(service.translate_feedback(feedback, "sk"))

    rows = disk_rows(tmp_path)
    assert len(rows) == 1
    assert rows[0][4] == feedback_sk


def test_noop_shortcircuit_no_disk_row(service, tmp_path):
    """No-op passthroughs touch neither memory nor disk (short-circuit precedes lookup)."""
    service.client.chat.completions.create = AsyncMock(
        return_value=mock_response(QUESTION_SK)
    )

    asyncio.run(service.translate_question(QUESTION, "en", "en"))
    asyncio.run(service.translate_feedback("Correct!", "en"))

    assert service.client.chat.completions.create.call_count == 0
    assert service._cache == {}
    assert disk_rows(tmp_path) == []


def test_fail_soft_init_degrades_to_empty_cache(tmp_path):
    """A corrupt DB file must degrade to an empty in-memory cache, never raise —
    TranslationService is built inside main.py's re-raising services block, so an escape
    would crash-loop the whole app on a bad /data/translations.db."""
    (tmp_path / "translations.db").write_bytes(b"this is not a sqlite database")

    service = make_service(f"sqlite:///{tmp_path}/translations.db")
    assert service._store is None
    assert service._cache == {}

    service.client.chat.completions.create = AsyncMock(
        return_value=mock_response(QUESTION_SK)
    )
    result = asyncio.run(service.translate_question(QUESTION, "sk"))
    assert result == QUESTION_SK  # still translates, just without durability


def test_runtime_write_failure_still_serves_translation(service, monkeypatch):
    """A disk-write hiccup must not downgrade a validated translation to English nor
    skip the in-memory cache (dict-insert-first + swallowing guard)."""

    def boom(*args, **kwargs):
        raise OSError("disk full")

    monkeypatch.setattr(service._store, "upsert", boom)
    service.client.chat.completions.create = AsyncMock(
        return_value=mock_response(QUESTION_SK)
    )

    first = asyncio.run(service.translate_question(QUESTION, "sk"))
    second = asyncio.run(service.translate_question(QUESTION, "sk"))

    assert first == second == QUESTION_SK
    assert service.client.chat.completions.create.call_count == 1  # in-memory hit held


def test_upsert_overwrites_existing_row(store_url, tmp_path):
    """The composite-PK upsert is idempotent — a plain INSERT would raise here."""
    store = TranslationStore(store_url)
    store.upsert("question", QUESTION, "sk", "1", "first")
    store.upsert("question", QUESTION, "sk", "1", "second")

    rows = disk_rows(tmp_path)
    assert len(rows) == 1
    assert rows[0][4] == "second"


def test_short_question_short_translation_validates(service):
    """A legitimately compact translation of a short question must NOT be rejected
    by the absolute length floor — that was silently leaking English questions
    into Slovak sessions (founder bug 2026-07-11)."""
    short_q = "Is ice cold?"  # < 30 chars
    short_sk = "Je ľad studený?"  # < 15 chars would trip old floor via similar cases
    service.client.chat.completions.create = AsyncMock(
        return_value=mock_response(short_sk)
    )

    result = asyncio.run(service.translate_question(short_q, "sk"))

    assert result == short_sk
