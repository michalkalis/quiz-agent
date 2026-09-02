"""Unit tests for the Claude Code subscription transport (#169).

``ChatClaudeSession`` runs ``claude -p`` as a subprocess so dev-pipeline LLM
calls land on the Claude Code subscription instead of a paid API. These
tests lock the contract the founder decision depends on: the quota-saving
flags are always sent, the child process never sees API-key credentials
(the whole point is that a session run can never silently bill the API),
and every documented failure mode (bad exit, error envelope, non-subscription
auth, missing binary) fails loud with a RuntimeError instead of degrading
silently.

No real ``claude`` binary is ever invoked — ``tests._fake_claude_cli``
installs a small Python script on PATH that plays the same JSON envelope
contract.
"""

from __future__ import annotations

import json

import pytest
from pydantic import BaseModel

from quiz_shared.llm.session_cli import (
    ChatClaudeSession,
    build_command,
    ensure_subscription_login,
)

from tests._fake_claude_cli import default_response, read_record, setup_fake_claude

# --- build_command: the quota-saving argv contract -------------------------


def test_build_command_always_has_quota_saving_flags():
    """Measured 2026-09-02: these flags are the difference between ~6.5k and
    ~39k input tokens per call — omitting any of them burns weekly quota."""
    cmd = build_command("opus", max_turns=1)
    assert cmd[:4] == ["claude", "-p", "--model", "opus"]
    assert cmd[cmd.index("--output-format") + 1] == "json"
    assert cmd[cmd.index("--setting-sources") + 1] == ""
    assert "--strict-mcp-config" in cmd
    assert cmd[cmd.index("--mcp-config") + 1] == '{"mcpServers":{}}'
    assert "--no-session-persistence" in cmd


def test_build_command_default_tools_empty_and_no_allowed_tools():
    """Default transport must not grant any tool — a session run is a plain
    completion, not an agentic loop with filesystem/web access."""
    cmd = build_command("opus", max_turns=1)
    assert cmd[cmd.index("--tools") + 1] == ""
    assert "--allowedTools" not in cmd


def test_build_command_web_true_adds_search_and_allowed_tools():
    """The FactVerifier session branch needs WebSearch/WebFetch — both the
    ``--tools`` grant and the ``--allowedTools`` gate must carry the same list."""
    cmd = build_command("opus", max_turns=8, tools="WebSearch,WebFetch")
    assert cmd[cmd.index("--tools") + 1] == "WebSearch,WebFetch"
    assert cmd[cmd.index("--allowedTools") + 1] == "WebSearch,WebFetch"


def test_build_command_json_schema_only_when_tool_bound():
    """Structured output is delivered via ``--json-schema`` — must be absent
    for a plain completion and present, with the exact schema, when bound."""
    cmd_no_tool = build_command("opus", max_turns=1)
    assert "--json-schema" not in cmd_no_tool

    schema = {"type": "object", "properties": {"ok": {"type": "boolean"}}}
    cmd = build_command("opus", max_turns=2, json_schema=schema)
    assert json.loads(cmd[cmd.index("--json-schema") + 1]) == schema


def test_build_command_system_prompt_only_when_present():
    """An empty/omitted system prompt must not add a stray flag (and
    shouldn't cost tokens on nothing)."""
    cmd_no_system = build_command("opus", max_turns=1)
    assert "--system-prompt" not in cmd_no_system

    cmd = build_command("opus", max_turns=1, system_prompt="be terse")
    assert cmd[cmd.index("--system-prompt") + 1] == "be terse"


# --- ainvoke: response shape ------------------------------------------------


async def test_ainvoke_returns_aimessage_with_summed_usage_and_model_name(
    tmp_path, monkeypatch
):
    """Cache tokens are real subscription spend too — undercounting them
    would make session usage tracking (#153) understate consumption."""
    setup_fake_claude(
        monkeypatch,
        tmp_path,
        control={
            "auth": {"loggedIn": True, "authMethod": "claude.ai"},
            "response": default_response(
                result="42",
                usage={
                    "input_tokens": 100,
                    "output_tokens": 20,
                    "cache_creation_input_tokens": 5,
                    "cache_read_input_tokens": 7,
                },
            ),
        },
    )
    llm = ChatClaudeSession(alias="opus")
    msg = await llm.ainvoke("what is the answer")

    assert msg.content == "42"
    assert msg.usage_metadata["input_tokens"] == 112  # 100 + 5 + 7
    assert msg.usage_metadata["output_tokens"] == 20
    assert msg.usage_metadata["total_tokens"] == 132
    assert msg.response_metadata["model_name"] == "session:opus"


# --- child env scrubbing ----------------------------------------------------


def test_child_env_scrubbed_of_api_key_and_claudecode_markers(tmp_path, monkeypatch):
    """The entire point of the session gateway is that these runs never bill
    the API — a leaked ANTHROPIC_API_KEY in the child env would defeat that
    silently (the CLI would just use it). CLAUDECODE must also be gone so a
    nested invocation from inside a Claude Code session isn't misread."""
    _, record_path = setup_fake_claude(monkeypatch, tmp_path)
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-ant-should-not-reach-child")
    monkeypatch.setenv("CLAUDECODE", "1")

    ChatClaudeSession(alias="opus").invoke("hello")

    record = read_record(record_path)
    assert "ANTHROPIC_API_KEY" not in record["env"]
    assert "CLAUDECODE" not in record["env"]


# --- structured output -------------------------------------------------


class _Verdict(BaseModel):
    is_correct: bool
    reason: str


def test_structured_output_parses_into_model_with_one_tool_call(tmp_path, monkeypatch):
    """The whole point of ``with_structured_output`` is a typed object back —
    if ``structured_output`` didn't round-trip into the pydantic instance,
    every FactVerifier/generation call site parsing session responses would
    silently get garbage instead of a validated verdict."""
    _, record_path = setup_fake_claude(
        monkeypatch,
        tmp_path,
        control={
            "response": default_response(
                structured_output={"is_correct": True, "reason": "matches source"}
            )
        },
    )
    structured_llm = ChatClaudeSession(alias="opus").with_structured_output(
        _Verdict, method="function_calling", include_raw=True
    )
    result = structured_llm.invoke("check this claim")

    assert result["parsed"] == _Verdict(is_correct=True, reason="matches source")
    assert len(result["raw"].tool_calls) == 1

    # A tool-bound call needs >= 2 turns (the schema answer is a tool turn).
    record = read_record(record_path)
    assert record["argv"][record["argv"].index("--max-turns") + 1] == "2"


def test_structured_output_missing_envelope_field_parses_to_none(tmp_path, monkeypatch):
    """A session run that returns no ``structured_output`` (e.g. the model
    answered in prose instead of calling the tool) must degrade to
    ``parsed=None`` — not raise and take down the whole pipeline call."""
    setup_fake_claude(
        monkeypatch, tmp_path, control={"response": default_response(result="I refuse")}
    )
    structured_llm = ChatClaudeSession(alias="opus").with_structured_output(
        _Verdict, method="function_calling", include_raw=True
    )
    result = structured_llm.invoke("check this claim")

    assert result["parsed"] is None
    assert result["raw"].tool_calls == []


# --- failure contract --------------------------------------------------


def test_nonzero_exit_raises_runtime_error_with_stderr(tmp_path, monkeypatch):
    """A crashed CLI must fail the call loudly with the diagnostic text, not
    return an empty/garbage AIMessage the caller mistakes for a real answer."""
    setup_fake_claude(
        monkeypatch, tmp_path, control={"exit_code": 2, "stderr": "boom: rate limited"}
    )
    with pytest.raises(RuntimeError, match="boom: rate limited"):
        ChatClaudeSession(alias="opus").invoke("hi")


def test_is_error_envelope_raises_runtime_error(tmp_path, monkeypatch):
    """``--output-format json`` can report success at the process level
    (exit 0) while the run itself failed — ``is_error`` must be checked too."""
    setup_fake_claude(
        monkeypatch,
        tmp_path,
        control={
            "response": default_response(
                is_error=True, subtype="error_max_turns", result="gave up"
            )
        },
    )
    with pytest.raises(RuntimeError, match="claude -p failed"):
        ChatClaudeSession(alias="opus").invoke("hi")


def test_auth_api_key_login_is_refused(tmp_path, monkeypatch):
    """API-key auth is the exact thing the session gateway exists to avoid —
    refusing it is the safety property, not an incidental check."""
    setup_fake_claude(
        monkeypatch,
        tmp_path,
        control={"auth": {"loggedIn": True, "authMethod": "api-key"}},
    )
    with pytest.raises(RuntimeError, match="subscription"):
        ChatClaudeSession(alias="opus").invoke("hi")


def test_auth_not_logged_in_is_refused(tmp_path, monkeypatch):
    setup_fake_claude(
        monkeypatch, tmp_path, control={"auth": {"loggedIn": False, "authMethod": None}}
    )
    with pytest.raises(RuntimeError, match="subscription"):
        ChatClaudeSession(alias="opus").invoke("hi")


def test_missing_claude_binary_raises_runtime_error_naming_the_cli(
    tmp_path, monkeypatch
):
    """If the CLI isn't installed, the error must say so specifically
    (``claude`` CLI) rather than surface a bare ``FileNotFoundError``."""
    from quiz_shared.llm import session_cli

    empty_bin = tmp_path / "empty-bin"
    empty_bin.mkdir()
    monkeypatch.setenv("PATH", str(empty_bin))
    monkeypatch.setattr(session_cli, "_login_checked", False)

    with pytest.raises(RuntimeError, match="claude"):
        ensure_subscription_login()
