"""#196 track 196.4 — offline helper roles moved to Claude where they won.

Why these matter:
- **One secret rolls one role back.** Each helper role got its own
  ``LLM_ROLE_*`` override; the expiry classifier used to borrow CRITIQUE, so
  moving it would have dragged the critique pass along (and vice versa).
  Roles that stayed put (topic planner) must keep following CRITIQUE exactly
  as before.
- **Reachability follows the route, not the OpenAI key.** A Claude role with
  ``ANTHROPIC_API_KEY`` is available without an OpenAI key; a fail-safe call
  site that still checked only ``OPENAI_API_KEY`` would silently skip it.
- **Claude web-search sourcing keeps the integrity rule.** A fact ships only
  with a URL the search tool really returned — a model-written URL the search
  never surfaced is dropped, as on the OpenAI branch.
- **The vision check must actually see the image.** If the image block were
  lost on the Claude route, the validator would judge a blank prompt and wave
  text-laden images through.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from types import SimpleNamespace
from unittest.mock import AsyncMock

import pytest

from quiz_shared.llm import factory

ROLE_ENVS = {
    "SOURCING": "LLM_ROLE_SOURCING",
    "TOPIC_PLAN": "LLM_ROLE_TOPIC_PLAN",
    "EXPIRY": "LLM_ROLE_EXPIRY",
    "OTDB_REWRITE": "LLM_ROLE_OTDB_REWRITE",
    "HINT_QUESTION": "LLM_ROLE_HINT_QUESTION",
    "SILHOUETTE_QUESTION": "LLM_ROLE_SILHOUETTE_QUESTION",
    "HINT_VALIDATE": "LLM_ROLE_HINT_VALIDATE",
}


def _roles_with_env(env: dict[str, str]) -> dict[str, str]:
    """Role constants as a fresh process sees them (roles are read at import)."""
    clean = {k: v for k, v in os.environ.items() if not k.startswith("LLM_ROLE_")}
    names = ["CRITIQUE", *ROLE_ENVS]
    code = (
        "import json; from quiz_shared.llm import factory as f; "
        f"print(json.dumps({{n: getattr(f, n) for n in {names!r}}}))"
    )
    out = subprocess.run(
        [sys.executable, "-c", code],
        env={**clean, **env},
        capture_output=True,
        text=True,
        check=True,
    )
    return json.loads(out.stdout)


def test_each_helper_role_has_its_own_rollback_secret() -> None:
    overrides = {env: f"rollback-{role.lower()}" for role, env in ROLE_ENVS.items()}

    roles = _roles_with_env(overrides)

    for role, env in ROLE_ENVS.items():
        assert roles[role] == overrides[env], role


def test_expiry_no_longer_follows_critique_but_topic_planner_still_does() -> None:
    roles = _roles_with_env({"LLM_ROLE_CRITIQUE": "bedrock:deepseek.v3.2"})

    assert roles["CRITIQUE"] == "bedrock:deepseek.v3.2"
    assert roles["TOPIC_PLAN"] == "bedrock:deepseek.v3.2"  # kept role, unchanged
    assert roles["EXPIRY"] == "claude-sonnet-5-5"  # won the eval, own role now


def test_claude_role_is_available_on_the_anthropic_key_alone(monkeypatch) -> None:
    monkeypatch.setenv("LLM_GATEWAY", "direct")
    monkeypatch.delenv("OPENAI_API_KEY", raising=False)
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-ant-test")

    assert factory.chat_available("claude-haiku-5-5")
    assert not factory.chat_available("gpt-4o-mini")


def test_claude_role_without_any_route_is_unavailable(monkeypatch) -> None:
    monkeypatch.setenv("LLM_GATEWAY", "direct")
    monkeypatch.delenv("OPENAI_API_KEY", raising=False)
    monkeypatch.setenv("ANTHROPIC_API_KEY", "")

    assert not factory.chat_available("claude-haiku-5-5")
    assert factory.chat_available("bedrock:deepseek.v3.2")


# --- Claude web-search sourcing ------------------------------------------

SEARCHED = "https://en.wikipedia.org/wiki/Surtsey"
CITED = "https://whc.unesco.org/en/list/1267"


def _message(text: str, stop_reason: str = "end_turn", results=None, citations=()):
    content = [
        SimpleNamespace(
            type="web_search_tool_result",
            content=results if results is not None else [SimpleNamespace(url=SEARCHED)],
        ),
        SimpleNamespace(
            type="text",
            text=text,
            citations=[SimpleNamespace(url=u) for u in citations],
        ),
    ]
    return SimpleNamespace(stop_reason=stop_reason, content=content)


def _claude_source(monkeypatch, *responses):
    from app.sourcing.openai_web_search_source import OpenAIWebSearchSource

    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-ant-test")
    source = OpenAIWebSearchSource(model="claude-sonnet-5-5")
    source.client = SimpleNamespace(
        messages=SimpleNamespace(create=AsyncMock(side_effect=list(responses)))
    )
    return source


def _facts_json(*urls: str) -> str:
    return json.dumps(
        [
            {
                "fact": f"Surtsey rose from the sea off Iceland in an eruption (#{i}).",
                "excerpt": "Surtsey is a new island formed by volcanic eruptions.",
                "source_url": url,
            }
            for i, url in enumerate(urls)
        ]
    )


@pytest.mark.asyncio
async def test_claude_sourcing_keeps_only_urls_the_search_returned(monkeypatch) -> None:
    invented = "https://example.com/made-up-page"
    source = _claude_source(
        monkeypatch,
        _message(_facts_json(SEARCHED, CITED, invented), citations=[CITED]),
    )

    facts = await source.get_facts(count=5, topics=["volcanic islands"])

    assert [f.source_url for f in facts] == [SEARCHED, CITED]
    request = source.client.messages.create.await_args.kwargs
    assert request["model"] == "claude-sonnet-5-5"
    assert request["tools"][0]["name"] == "web_search"


@pytest.mark.asyncio
async def test_claude_sourcing_resumes_a_paused_turn(monkeypatch) -> None:
    source = _claude_source(
        monkeypatch,
        _message("", stop_reason="pause_turn"),
        _message(_facts_json(SEARCHED)),
    )

    facts = await source.get_facts(count=5, topics=["volcanic islands"])

    assert len(facts) == 1
    assert source.client.messages.create.await_count == 2


@pytest.mark.asyncio
async def test_claude_sourcing_takes_nothing_from_an_unfinished_turn(monkeypatch) -> None:
    # A refusal / max_tokens stop may carry a half-written array; nothing from
    # it is trusted. A search error object (not a list) adds no trusted URL.
    source = _claude_source(
        monkeypatch,
        _message(_facts_json(SEARCHED), stop_reason="max_tokens"),
        _message(_facts_json(SEARCHED), results=SimpleNamespace(error_code="unavailable")),
    )

    first = await source.get_facts(count=5, topics=["a"])
    second = await source.get_facts(count=5, topics=["b"])

    assert first == [] and second == []


# --- vision validation on the chat-model route ---------------------------

def test_hint_validation_sends_the_image_to_the_validate_role(monkeypatch) -> None:
    from app.image_generation import hint_images

    seen = {}

    class _FakeChat:
        def invoke(self, messages):
            seen["messages"] = messages
            return SimpleNamespace(
                content='{"has_text": true, "quality_score": 7, "too_obvious": false, '
                '"too_vague": false, "feedback": "caption"}'
            )

    def _fake_chat_model(model, **kwargs):
        seen["model"] = model
        return _FakeChat()

    monkeypatch.setattr(hint_images.llm_factory, "chat_model", _fake_chat_model)

    verdict = hint_images.validate_image(b"\x89PNG-bytes", "DNA")

    assert seen["model"] == hint_images.VALIDATION_MODEL
    parts = seen["messages"][0]["content"]
    image = next(p for p in parts if p["type"] == "image_url")
    assert image["image_url"]["url"].startswith("data:image/png;base64,")
    assert verdict["has_text"] is True
