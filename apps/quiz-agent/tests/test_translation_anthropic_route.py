"""Serve-time translation on the direct Anthropic API (#196 track 196.1).

Why: translation is the hot path of every non-English session and runs on a
Claude model. With ANTHROPIC_API_KEY set it must draw on the founder's Anthropic
API credit (no OpenRouter fee) — and switching transport must not change what
the player hears: same model, same prompts, no sampling params (Claude 5-class
400s on them), the same 30 s hot-path timeout, and the same validation. Without
the key, nothing may change (fail-safe).
"""

import asyncio
import json
import os
import sys
from types import SimpleNamespace
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

sys.path.insert(
    0, os.path.join(os.path.dirname(__file__), "../../../..", "packages/shared")
)

from app.translation.translator import TranslationService  # noqa: E402
from quiz_shared.llm import factory as llm_factory  # noqa: E402

STEM = "What is the capital city of France?"
SK_PAYLOAD = {
    "question": "Aké je hlavné mesto Francúzska?",
    "options": {"a": "Paríž", "b": "Londýn", "c": "Berlín"},
}
EN_PAYLOAD = {"question": STEM, "options": {"a": "Paris", "b": "London", "c": "Berlin"}}


def _anthropic_reply(text: str):
    """Shape of an Opus 5.5 reply: thinking is always on, so an (empty)
    thinking block precedes the text block."""
    return SimpleNamespace(
        content=[
            SimpleNamespace(type="thinking", thinking=""),
            SimpleNamespace(type="text", text=text),
        ]
    )


@pytest.fixture
def anthropic_env(monkeypatch, tmp_path):
    """Key set + a fake native client; returns (service, fake client, factory spy)."""
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-ant-test-placeholder")
    monkeypatch.setenv("LLM_GATEWAY", "openrouter")  # prod-like gateway
    fake = MagicMock()
    fake.messages.create = AsyncMock()
    spy = MagicMock(return_value=fake)
    monkeypatch.setattr(llm_factory, "anthropic_client", spy)
    service = TranslationService(
        model="anthropic/claude-opus-5.5", store_url=f"sqlite:///{tmp_path}/t.db"
    )
    return service, fake, spy


def test_claude_model_with_key_uses_anthropic_api_not_openai(anthropic_env):
    service, fake, spy = anthropic_env
    fake.messages.create.return_value = _anthropic_reply(
        "```json\n" + json.dumps(SK_PAYLOAD, ensure_ascii=False) + "\n```"
    )

    result = asyncio.run(service.translate_question_payload(dict(EN_PAYLOAD), "sk"))

    # A fenced JSON reply still parses — the Anthropic API has no json_object mode.
    assert result == SK_PAYLOAD
    assert service.client is None  # no OpenAI/OpenRouter client on this route
    # Hot-path bound kept (#139): same 30 s as openai_client's DEFAULT_TIMEOUT.
    spy.assert_called_once_with(timeout=llm_factory.DEFAULT_TIMEOUT.read)
    kwargs = fake.messages.create.call_args.kwargs
    # OpenRouter slug normalised to the real Anthropic id — same model.
    assert kwargs["model"] == "claude-opus-5-5"
    assert "temperature" not in kwargs and "top_p" not in kwargs
    assert kwargs["max_tokens"] == 2500
    assert "Slovak" in kwargs["system"]  # the unchanged system prompt
    assert json.loads(kwargs["messages"][0]["content"]) == EN_PAYLOAD


def test_stem_translation_reads_text_block_only(anthropic_env):
    """Thinking blocks must never leak into the translated question."""
    service, fake, _ = anthropic_env
    fake.messages.create.return_value = _anthropic_reply(
        "Aké je hlavné mesto Francúzska?"
    )

    translated = asyncio.run(service.translate_question(STEM, "sk"))

    assert translated == "Aké je hlavné mesto Francúzska?"


def test_without_key_translation_keeps_openai_compatible_route(monkeypatch, tmp_path):
    """Fail-safe: no ANTHROPIC_API_KEY → exactly today's gateway client."""
    monkeypatch.setenv("ANTHROPIC_API_KEY", "")
    monkeypatch.setenv("LLM_GATEWAY", "openrouter")
    monkeypatch.setenv("OPENROUTER_API_KEY", "sk-or-test")
    spy = MagicMock()
    monkeypatch.setattr(llm_factory, "anthropic_client", spy)

    with patch.dict(os.environ, {"OPENAI_API_KEY": "sk-test-dummy"}):
        service = TranslationService(store_url=f"sqlite:///{tmp_path}/t.db")

    spy.assert_not_called()
    assert service.client is not None
    assert service.model == "anthropic/claude-opus-5.5"  # OpenRouter slug, as before
