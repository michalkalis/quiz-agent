"""RC-1 / #72 P3.1 — OpenTDB stops re-wrapping the trivia question.

Why these scenarios:

The legacy `_extract_fact` emits ``The answer to '<question>' is <answer>.`` —
the question verbatim — so downstream "transform, don't rephrase" generation has
nothing to transform (RC-1). P3.1 lets an injected cheap-model rewriter replace
that with a bare declarative fact, guarded so an *active* source can never emit a
fact that still embeds the original question.

- `test_dormant_*` locks the issue's dormancy mandate: with **no** rewriter the
  output is byte-identical to today, so nothing changes until Phase 6 wires one.
- `test_active_rewriter_emits_declarative` proves the happy path: a clean
  rewrite replaces the re-wrap and the guard passes (question not a substring).
- `test_active_rewriter_echoing_question_is_dropped` is the guard's reason to
  exist — a rewrite that still echoes the question is dropped, never emitted.
- `test_guard_*` pins the substring guard itself (incl. the trailing-`?` strip).
- `test_rewriter_*` pins the rewriter's fail-safe contract (unavailable → None;
  output stripped) without any network, mirroring `AnswerNormalizer`.

HTTP is mocked with respx `assert_all_mocked=True` so a real opentdb.com call
fails the test loudly (Phase-3 "no real network" gate).
"""

from __future__ import annotations

from types import SimpleNamespace
from unittest.mock import AsyncMock

import pytest
import respx
from httpx import Response

from app.sourcing.opentriviadb_source import (
    OpenTriviaDBSource,
    OpenTriviaFactRewriter,
    _fact_echoes_question,
)

# Mocks are matched by host+path (not full URL) so the ?amount=&category=&type=
# query the source appends still matches — assert_all_mocked then fails loudly
# if any real opentdb.com request escapes (Phase-3 "no real network").
_QUESTION = "What is the capital of France?"
_PAYLOAD = {
    "response_code": 0,
    "results": [
        {
            "category": "History",
            "type": "multiple",
            "difficulty": "easy",
            "question": _QUESTION,
            "correct_answer": "Paris",
            "incorrect_answers": ["Lyon", "Marseille", "Nice"],
        }
    ],
}


# --- guard ----------------------------------------------------------------

def test_guard_flags_the_legacy_rewrap() -> None:
    rewrap = f"The answer to '{_QUESTION}' is Paris."
    assert _fact_echoes_question(rewrap, _QUESTION) is True


def test_guard_strips_trailing_question_mark() -> None:
    # A "declarative" rewrite that merely drops the `?` is still the question.
    echo = "What is the capital of France. It is Paris."
    assert _fact_echoes_question(echo, _QUESTION) is True


def test_guard_passes_a_genuine_declarative() -> None:
    assert _fact_echoes_question("Paris is the capital of France.", _QUESTION) is False


# --- source integration (respx-mocked HTTP, no real network) --------------

@pytest.mark.asyncio
@respx.mock(assert_all_mocked=True, assert_all_called=False)
async def test_dormant_source_keeps_byte_identical_rewrap(respx_mock: respx.MockRouter) -> None:
    respx_mock.get(host="opentdb.com", path="/api.php").mock(return_value=Response(200, json=_PAYLOAD))

    facts = await OpenTriviaDBSource().get_facts(count=5, topics=["History"])

    assert len(facts) == 1
    # Dormant default must not change today's output one byte.
    assert facts[0].text == f"The answer to '{_QUESTION}' is Paris."


@pytest.mark.asyncio
@respx.mock(assert_all_mocked=True, assert_all_called=False)
async def test_active_rewriter_emits_declarative(respx_mock: respx.MockRouter) -> None:
    respx_mock.get(host="opentdb.com", path="/api.php").mock(return_value=Response(200, json=_PAYLOAD))
    rewriter = OpenTriviaFactRewriter()
    rewriter.rewrite = AsyncMock(return_value="Paris is the capital of France.")

    facts = await OpenTriviaDBSource(rewriter=rewriter).get_facts(count=5, topics=["History"])

    assert len(facts) == 1
    assert facts[0].text == "Paris is the capital of France."
    # The whole point of RC-1: the emitted fact no longer embeds the question.
    assert _fact_echoes_question(facts[0].text, _QUESTION) is False
    rewriter.rewrite.assert_awaited_once_with(_QUESTION, "Paris")


@pytest.mark.asyncio
@respx.mock(assert_all_mocked=True, assert_all_called=False)
async def test_active_rewriter_echoing_question_is_dropped(respx_mock: respx.MockRouter) -> None:
    respx_mock.get(host="opentdb.com", path="/api.php").mock(return_value=Response(200, json=_PAYLOAD))
    rewriter = OpenTriviaFactRewriter()
    # A bad rewrite that still parrots the question must never be emitted.
    rewriter.rewrite = AsyncMock(return_value=f"The answer to '{_QUESTION}' is Paris.")

    facts = await OpenTriviaDBSource(rewriter=rewriter).get_facts(count=5, topics=["History"])

    assert facts == []


@pytest.mark.asyncio
@respx.mock(assert_all_mocked=True, assert_all_called=False)
async def test_active_rewriter_unavailable_drops_seed(respx_mock: respx.MockRouter) -> None:
    respx_mock.get(host="opentdb.com", path="/api.php").mock(return_value=Response(200, json=_PAYLOAD))
    rewriter = OpenTriviaFactRewriter()
    rewriter.rewrite = AsyncMock(return_value=None)  # fail-safe: model unreachable

    facts = await OpenTriviaDBSource(rewriter=rewriter).get_facts(count=5, topics=["History"])

    assert facts == []


# --- rewriter fail-safe contract (no network) -----------------------------

@pytest.mark.asyncio
async def test_rewriter_unavailable_returns_none(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("OPENAI_API_KEY", raising=False)
    monkeypatch.delenv("LLM_GATEWAY", raising=False)  # default 'direct'
    rewriter = OpenTriviaFactRewriter()

    assert await rewriter.rewrite(_QUESTION, "Paris") is None


@pytest.mark.asyncio
async def test_rewriter_strips_wrapping_quotes(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("OPENAI_API_KEY", "test-key")
    resp = SimpleNamespace(
        choices=[SimpleNamespace(message=SimpleNamespace(content='  "Paris is the capital of France."  '))]
    )
    rewriter = OpenTriviaFactRewriter()
    rewriter._client = SimpleNamespace(
        chat=SimpleNamespace(
            completions=SimpleNamespace(create=AsyncMock(return_value=resp))
        )
    )

    assert await rewriter.rewrite(_QUESTION, "Paris") == "Paris is the capital of France."
